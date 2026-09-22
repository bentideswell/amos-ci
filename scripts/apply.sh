#!/usr/bin/env bash
#
# Applies .github/ruleset.json to GitHub, and enables repo auto-merge, for
# every repo listed in ruleset.json.
#
# - Branch protection: on an org account, creates/updates one org-level
#   ruleset (scoped to the repos listed in ruleset.json's
#   conditions.repository_name.include). On a personal/individual account,
#   org-level rulesets don't exist there, so the same policy is
#   created/updated as a repo-level ruleset on each repo in that same list.
# - Repo settings: auto-merge, auto-delete-on-merge, and using the PR's own
#   title/description for the squash commit are all per-repo settings with
#   no org-wide equivalent, so they're applied per repo either way.
#
# Requires: gh (authenticated), jq.

set -euo pipefail

# ---- Config ----
ACCOUNT="bentideswell"   # GitHub username or org login to apply the ruleset to
RULESET_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.github" && pwd)/ruleset.json"
DRY_RUN="${DRY_RUN:-false}"   # DRY_RUN=true ./apply.sh, or pass --dry-run, to preview without writing

# ---- Args ----
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *)
      echo "::error::Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

# ---- Preflight ----
command -v gh >/dev/null || { echo "::error::gh CLI not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "::error::jq not found" >&2; exit 1; }
[[ -f "$RULESET_FILE" ]] || { echo "::error::ruleset file not found: $RULESET_FILE" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "::error::gh is not authenticated (run: gh auth login)" >&2; exit 1; }

RULESET_NAME="$(jq -r '.name' "$RULESET_FILE")"

REPOS=()
while IFS= read -r repo; do
  REPOS+=("$repo")
done < <(jq -r '.conditions.repository_name.include[]' "$RULESET_FILE")
if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "::error::No repositories found under .conditions.repository_name.include in $RULESET_FILE" >&2
  exit 1
fi

echo "Ruleset:  $RULESET_NAME"
echo "Account:  $ACCOUNT"
echo "Repos:    ${REPOS[*]}"
echo "Dry run:  $DRY_RUN"
echo

# ---- Detect account type ----
# GET /users/{account} reports .type as "Organization" or "User" for either
# kind of account -- one call is enough to pick the right code path.
account_type="$(gh api "users/${ACCOUNT}" --jq '.type')"
echo "Detected account type: $account_type"
echo

apply_ruleset() {
  local list_endpoint="$1" write_endpoint="$2" body_file="$3" label="$4"

  # Capture the list call's own success/failure separately from parsing its
  # output -- gh prints API errors (e.g. repo not found, no access) to
  # stdout as JSON, so a failed call must not fall through into jq and get
  # misread as a ruleset id.
  local list_output
  if ! list_output="$(gh api --paginate "$list_endpoint" 2>&1)"; then
    echo "  x could not list existing rulesets for $label:" >&2
    echo "$list_output" | sed 's/^/    /' >&2
    return 1
  fi

  local existing_id
  existing_id="$(jq -r ".[] | select(.name==\"$RULESET_NAME\") | .id" <<<"$list_output" | head -n 1)"

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ -n "$existing_id" ]]; then
      echo "[dry-run] would UPDATE existing ruleset (id=$existing_id) on $label"
    else
      echo "[dry-run] would CREATE new ruleset on $label"
    fi
    return 0
  fi

  local write_output
  if [[ -n "$existing_id" ]]; then
    echo "Updating existing ruleset (id=$existing_id) on $label"
    if ! write_output="$(gh api --method PUT "$write_endpoint/$existing_id" --input "$body_file" 2>&1)"; then
      echo "  x update failed for $label:" >&2
      echo "$write_output" | sed 's/^/    /' >&2
      return 1
    fi
  else
    echo "Creating ruleset on $label"
    if ! write_output="$(gh api --method POST "$write_endpoint" --input "$body_file" 2>&1)"; then
      echo "  x create failed for $label:" >&2
      echo "$write_output" | sed 's/^/    /' >&2
      return 1
    fi
  fi
}

configure_repo_settings() {
  local repo="$1"
  local full="${ACCOUNT}/${repo}"

  # allow_auto_merge: PRs can arm native auto-merge.
  # delete_branch_on_merge: head branch is deleted server-side on merge,
  #   regardless of who/what performs the merge (see README -- this is what
  #   replaces the old branch-cleanup workflow job).
  # squash_merge_commit_title/message: default the squash commit to the PR's
  #   own title/description, rather than the last individual commit.
  if [[ "$DRY_RUN" == "true" ]]; then
    local current
    if ! current="$(gh api "repos/${full}" --jq '{allow_auto_merge, delete_branch_on_merge, squash_merge_commit_title, squash_merge_commit_message}' 2>&1)"; then
      echo "  x could not read repo settings for $full:" >&2
      echo "$current" | sed 's/^/    /' >&2
      return 1
    fi
    local desc
    desc="$(jq -r '
      [
        (if .allow_auto_merge then "auto-merge: already on" else "auto-merge: would enable" end),
        (if .delete_branch_on_merge then "delete-on-merge: already on" else "delete-on-merge: would enable" end),
        (if .squash_merge_commit_title == "PR_TITLE" then "squash title: already PR title" else "squash title: would set to PR title" end),
        (if .squash_merge_commit_message == "PR_BODY" then "squash message: already PR body" else "squash message: would set to PR body" end)
      ] | join(", ")
    ' <<<"$current")"
    echo "[dry-run] $full -- $desc"
    return 0
  fi

  local output
  if ! output="$(
    gh api --method PATCH "repos/${full}" \
      -F allow_auto_merge=true \
      -F delete_branch_on_merge=true \
      -f squash_merge_commit_title=PR_TITLE \
      -f squash_merge_commit_message=PR_BODY \
      2>&1
  )"; then
    echo "  x failed to update repo settings on $full:" >&2
    echo "$output" | sed 's/^/    /' >&2
    return 1
  fi
  echo "Updated repo settings on $full (auto-merge, delete-on-merge, squash title/message from PR)"
}

overall_failed=()

if [[ "$account_type" == "Organization" ]]; then
  # Org-level ruleset: ruleset.json already scopes itself to the right repos
  # via conditions.repository_name, so it can be applied as-is.
  if ! apply_ruleset \
    "orgs/${ACCOUNT}/rulesets" \
    "orgs/${ACCOUNT}/rulesets" \
    "$RULESET_FILE" \
    "org $ACCOUNT"
  then
    overall_failed+=("org ruleset: $ACCOUNT")
  fi
else
  # Personal account: no org-level rulesets exist, so apply the same policy
  # per repo. repository_name is meaningless (and unsupported) on a
  # repo-scoped ruleset, so it's stripped before sending.
  tmp_body="$(mktemp)"
  trap 'rm -f "$tmp_body"' EXIT
  jq 'del(.conditions.repository_name)' "$RULESET_FILE" > "$tmp_body"

  for repo in "${REPOS[@]}"; do
    if ! apply_ruleset \
      "repos/${ACCOUNT}/${repo}/rulesets" \
      "repos/${ACCOUNT}/${repo}/rulesets" \
      "$tmp_body" \
      "repo ${ACCOUNT}/${repo}"
    then
      overall_failed+=("ruleset: $repo")
    fi
  done
fi

echo
echo "---- Repo settings ----"
for repo in "${REPOS[@]}"; do
  if ! configure_repo_settings "$repo"; then
    overall_failed+=("repo settings: $repo")
  fi
done

echo
if [[ ${#overall_failed[@]} -gt 0 ]]; then
  echo "::error::Failed: ${overall_failed[*]}" >&2
  exit 1
fi

echo "Done."
