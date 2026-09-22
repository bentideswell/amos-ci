#!/usr/bin/env bash
# Pure PR-content validation for Amos CI.
#
# Given a PR's type (as classified by evaluate-policy.sh) and its title, plus
# the PR body on stdin, decides whether the PR satisfies the content
# requirements the Amos release-note pipelines depend on, and whether the
# "client-facing" label belongs on it:
#
#   - a Conventional Commits title (drives the version bump in amos-pipeline)
#   - a non-empty "## Release Notes" section — read verbatim by the
#     deployment-manager build pipeline (amos-pipeline/buildspecs/build-amos.yaml)
#   - a non-empty "Client impact:" line — read by the client-facing
#     release-notes plugin
#
# It does NOT apply or remove any label itself — like evaluate-policy.sh's
# merge-method `label` output, it only decides what the label SHOULD be
# (`client_facing_required`); the workflow applies it, the same way it
# already applies merge:squash/merge:merge-commit. This keeps the label a
# mechanical consequence of the Client impact line, in sync on every push,
# rather than something a developer can forget to click or leave stale.
#
# This script has NO side effects and makes NO GitHub API calls — it only
# reads its inputs and writes `key=value` lines to stdout, the same pattern
# as evaluate-policy.sh, so it can be unit tested directly (see
# tests/run-content-tests.sh) without a real GitHub Actions run.
#
# Only Feature, Bugfix, Chore and Hotfix PRs carry new content. Promotion,
# Backport and Cascade/backport PRs (dev->uat, uat->main, uat->dev, main->uat,
# main->dev) move existing, already-described commits between branches and
# are exempt.
#
# Usage:
#   check-pr-content.sh <pr_type> <title>
#   (PR body is read from stdin)
#
# Output (one `key=value` per line):
#   applicable=true|false
#   valid=true|false
#   client_facing_required=true|false
#   reasons=...   (semicolon-separated; empty when valid=true)

set -euo pipefail

pr_type="${1:?usage: check-pr-content.sh <pr_type> <title>}"
title="${2:?usage: check-pr-content.sh <pr_type> <title>}"

body="$(cat)"

case "$pr_type" in
  Feature|Bugfix|Chore|Hotfix) applicable="true" ;;
  *) applicable="false" ;;
esac

if [[ "$applicable" != "true" ]]; then
  echo "applicable=false"
  echo "valid=true"
  echo "client_facing_required=false"
  echo "reasons="
  exit 0
fi

valid="true"
reasons=()

fail() {
  valid="false"
  reasons+=("$1")
}

# Strip HTML comments (the PR template's instructional text) before checking
# for real content, so an untouched template placeholder can't read as
# "filled in". Sequential and non-greedy across multiple separate comment
# blocks — a naive single greedy regex would swallow everything between the
# FIRST "<!--" and the LAST "-->" in the whole body, which would delete real
# content sitting between two separate template comments.
strip_comments() {
  awk '
    {
      line = $0
      out = ""
      while (length(line) > 0) {
        if (incmt) {
          p = index(line, "-->")
          if (p == 0) { line = "" } else { line = substr(line, p + 3); incmt = 0 }
        } else {
          p = index(line, "<!--")
          if (p == 0) { out = out line; line = "" }
          else { out = out substr(line, 1, p - 1); line = substr(line, p + 4); incmt = 1 }
        }
      }
      print out
    }
  '
}

body_clean="$(printf '%s\n' "$body" | strip_comments)"

# --- Title: Conventional Commits ---
title_regex='^(feat|fix|chore|docs|test|refactor|perf|hotfix|patch)(\([a-z0-9._-]+\))?!?: .+'
if [[ ! "$title" =~ $title_regex ]]; then
  fail "PR title '$title' is not in Conventional Commits format (e.g. 'fix: short description')."
fi

# --- Release Notes section (deployment manager) ---
# Same extraction the build pipeline itself uses: everything between the
# "## Release Notes" heading and the next "## " heading (or EOF).
release_notes="$(
  printf '%s\n' "$body_clean" \
    | awk '/^## Release Notes/{f=1;next} /^## /{if(f){exit}} f'
)"
release_notes_trimmed="$(
  printf '%s\n' "$release_notes" \
    | sed -E '/^[[:space:]]*$/d' \
    | sed -E '/^[[:space:]]*[-*][[:space:]]*$/d' \
    | sed -E '/^#{1,6}[[:space:]]*(Added|Changed|Fixed|Removed|Deprecated|Security)[[:space:]]*$/Id'
)"
if [[ -z "$release_notes_trimmed" ]]; then
  fail "Missing or empty '## Release Notes' section. Required for every ${pr_type} PR — see pull_request_template.md."
fi

# --- Client impact line (client release-notes plugin + client-facing label) ---
client_line="$(printf '%s\n' "$body_clean" | grep -im1 '^client impact:' || true)"
client_value="$(sed -E 's/^[Cc]lient [Ii]mpact:[[:space:]]*//' <<<"$client_line" | sed -E 's/[[:space:]]+$//')"
if [[ -z "$client_value" ]]; then
  fail "Missing or empty 'Client impact:' line. Write 'Client impact: none' if there is genuinely no client-visible effect."
fi

# Lowercase via tr, not ${var,,} (bash 4+ only) - macOS ships bash 3.2 as
# /bin/bash, and this script needs to run identically there and in CI.
client_value_lower="$(printf '%s' "$client_value" | tr '[:upper:]' '[:lower:]')"

client_facing_required="false"
if [[ -n "$client_value" ]] && [[ "$client_value_lower" != "none" ]]; then
  client_facing_required="true"
fi

reasons_joined="$(IFS='; '; echo "${reasons[*]}")"

echo "applicable=true"
echo "valid=$valid"
echo "client_facing_required=$client_facing_required"
echo "reasons=$reasons_joined"
