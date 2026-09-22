#!/usr/bin/env bash
# Pure branch-policy decision logic for Amos CI.
#
# Given a PR's head and base branch names, decides whether the PR is valid,
# what "type" of PR it is, which merge method/label it requires, and which
# branch-freshness check (if any) applies.
#
# This script has NO side effects and makes NO GitHub API calls — it only
# reads its two inputs and writes `key=value` lines to stdout. That is what
# makes it possible to unit test directly (see tests/run-tests.sh) without
# needing a real GitHub Actions run, and it's the same script the real
# workflow (amos-ci-workflow.yml) calls, so the tests exercise the exact
# logic that runs in production.
#
# Usage:
#   evaluate-policy.sh <head_ref> <base_ref>
#
# Output (one `key=value` per line):
#   valid=true|false
#   pr_type=...                (empty when valid=false)
#   merge_method=squash|merge  (empty when valid=false)
#   label=merge:squash|merge:merge-commit  (empty when valid=false)
#   freshness_mode=none|source-must-contain-target|target-contained-in-source
#   reason=...                 (only set when valid=false)

set -euo pipefail

head="${1:?usage: evaluate-policy.sh <head_ref> <base_ref>}"
base="${2:?usage: evaluate-policy.sh <head_ref> <base_ref>}"

valid="true"
pr_type=""
merge_method=""
label=""
freshness_mode="none"
reason=""

topic_regex='^(feature|bugfix|chore)/[a-z0-9]+(-[a-z0-9]+)*$'
hotfix_regex='^hotfix/[a-z0-9]+(-[a-z0-9]+)*$'

invalid() {
  valid="false"
  reason="$1"
}

case "$head" in
  dev)
    if [[ "$base" == "uat" ]]; then
      pr_type="Promotion"
      merge_method="merge"
      label="merge:merge-commit"
      freshness_mode="target-contained-in-source"
    else
      invalid "dev may only target uat."
    fi
    ;;

  uat)
    if [[ "$base" == "main" ]]; then
      pr_type="Promotion"
      merge_method="merge"
      label="merge:merge-commit"
      freshness_mode="target-contained-in-source"
    elif [[ "$base" == "dev" ]]; then
      pr_type="Backport"
      merge_method="merge"
      label="merge:merge-commit"
      freshness_mode="none"
    else
      invalid "uat may only target main (promotion) or dev (backport)."
    fi
    ;;

  main)
    if [[ "$base" == "uat" || "$base" == "dev" ]]; then
      pr_type="Cascade/backport"
      merge_method="merge"
      label="merge:merge-commit"
      freshness_mode="none"
    else
      invalid "main may only target uat or dev as part of a hotfix cascade/backport."
    fi
    ;;

  *)
    if [[ "$head" =~ $topic_regex ]]; then
      if [[ "$base" == "dev" ]]; then
        case "$head" in
          feature/*) pr_type="Feature" ;;
          bugfix/*)  pr_type="Bugfix" ;;
          chore/*)   pr_type="Chore" ;;
        esac

        merge_method="squash"
        label="merge:squash"
        freshness_mode="source-must-contain-target"
      else
        invalid "feature/*, bugfix/* and chore/* branches may only target dev."
      fi

    elif [[ "$head" =~ $hotfix_regex ]]; then
      if [[ "$base" == "uat" || "$base" == "main" ]]; then
        pr_type="Hotfix"
        merge_method="squash"
        label="merge:squash"
        freshness_mode="source-must-contain-target"
      else
        invalid "hotfix/* branches may only target uat or main."
      fi

    else
      invalid "Invalid branch name. Use feature/<kebab-case>, bugfix/<kebab-case>, hotfix/<kebab-case>, chore/<kebab-case>, or dev/uat/main."
    fi
    ;;
esac

echo "valid=$valid"
echo "pr_type=$pr_type"
echo "merge_method=$merge_method"
echo "label=$label"
echo "freshness_mode=$freshness_mode"
echo "reason=$reason"
