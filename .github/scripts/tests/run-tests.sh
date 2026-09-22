#!/usr/bin/env bash
# Test runner for evaluate-policy.sh.
#
# Deliberately has NO external dependencies (no bats, no test framework) so
# it runs anywhere bash does — locally, in CI, in a bare checkout. It calls
# the real script, exactly as the workflow does, so a passing run here is a
# direct guarantee about production behaviour, not a parallel reimplementation.
#
# Usage:
#   .github/scripts/tests/run-tests.sh
#
# Exit code is non-zero if any case fails.

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
policy_script="$script_dir/../evaluate-policy.sh"

pass=0
fail=0

if [[ -z "${NO_COLOR:-}" ]] && { [[ -t 1 ]] || [[ -n "${CI:-}" ]]; }; then
  green=$'\033[32m'
  red=$'\033[31m'
  reset=$'\033[0m'
else
  green=''
  red=''
  reset=''
fi

# Each row: head|base|expected_valid|expected_pr_type|expected_merge_method|expected_label|expected_freshness_mode
# The last four fields are only checked when expected_valid=true.
cases=(
  "dev|uat|true|Promotion|merge|merge:merge-commit|target-contained-in-source"
  "dev|main|false||||"
  "dev|dev|false||||"
  "uat|main|true|Promotion|merge|merge:merge-commit|target-contained-in-source"
  "uat|dev|true|Backport|merge|merge:merge-commit|none"
  "uat|uat|false||||"
  "main|uat|true|Cascade/backport|merge|merge:merge-commit|none"
  "main|dev|true|Cascade/backport|merge|merge:merge-commit|none"
  "main|main|false||||"
  "feature/foo|dev|true|Feature|squash|merge:squash|source-must-contain-target"
  "feature/foo-bar|dev|true|Feature|squash|merge:squash|source-must-contain-target"
  "feature/foo|uat|false||||"
  "bugfix/fix-1|dev|true|Bugfix|squash|merge:squash|source-must-contain-target"
  "chore/cleanup|dev|true|Chore|squash|merge:squash|source-must-contain-target"
  "feature/Foo|dev|false||||"
  "hotfix/urgent-fix|main|true|Hotfix|squash|merge:squash|source-must-contain-target"
  "hotfix/urgent-fix|uat|true|Hotfix|squash|merge:squash|source-must-contain-target"
  "hotfix/urgent-fix|dev|false||||"
  "random-branch|dev|false||||"
  "release/1.0|dev|false||||"
  "feature/foo/bar|dev|false||||"
)

for case_row in "${cases[@]}"; do
  IFS='|' read -r head base expected_valid expected_pr_type expected_merge_method expected_label expected_freshness <<< "$case_row"

  output="$("$policy_script" "$head" "$base")"

  actual_valid="$(grep -m1 '^valid=' <<<"$output" | cut -d= -f2-)"
  actual_pr_type="$(grep -m1 '^pr_type=' <<<"$output" | cut -d= -f2-)"
  actual_merge_method="$(grep -m1 '^merge_method=' <<<"$output" | cut -d= -f2-)"
  actual_label="$(grep -m1 '^label=' <<<"$output" | cut -d= -f2-)"
  actual_freshness="$(grep -m1 '^freshness_mode=' <<<"$output" | cut -d= -f2-)"

  ok=true
  problems=()

  if [[ "$actual_valid" != "$expected_valid" ]]; then
    ok=false
    problems+=("valid: expected '$expected_valid', got '$actual_valid'")
  fi

  if [[ "$expected_valid" == "true" ]]; then
    [[ "$actual_pr_type" == "$expected_pr_type" ]] || { ok=false; problems+=("pr_type: expected '$expected_pr_type', got '$actual_pr_type'"); }
    [[ "$actual_merge_method" == "$expected_merge_method" ]] || { ok=false; problems+=("merge_method: expected '$expected_merge_method', got '$actual_merge_method'"); }
    [[ "$actual_label" == "$expected_label" ]] || { ok=false; problems+=("label: expected '$expected_label', got '$actual_label'"); }
    [[ "$actual_freshness" == "$expected_freshness" ]] || { ok=false; problems+=("freshness_mode: expected '$expected_freshness', got '$actual_freshness'"); }
  fi

  if [[ "$expected_valid" == "true" ]]; then
    expected_desc="allowed as $expected_pr_type"
  else
    expected_desc="rejected"
  fi

  if [[ "$actual_valid" == "true" ]]; then
    actual_desc="allowed as $actual_pr_type"
  else
    actual_desc="rejected"
  fi

  if $ok; then
    echo "${green}PASS${reset}  $head -> $base  (expected: $expected_desc)"
    pass=$((pass + 1))
  else
    echo "${red}FAIL${reset}  $head -> $base  (expected: $expected_desc, got: $actual_desc)"
    for p in "${problems[@]}"; do
      echo "        $p"
    done
    fail=$((fail + 1))
  fi
done

echo
echo "$pass passed, $fail failed"

[[ "$fail" -eq 0 ]]
