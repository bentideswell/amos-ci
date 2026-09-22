# Amos CI

Central home for the shared CI/policy system used across `amos-*` repositories. Every `amos-*` repo runs the same set of checks on its pull requests by calling into this repo, instead of each repo maintaining its own copy.

## What Amos CI checks

Amos CI composes three concerns, each its own reusable GitHub Actions workflow:

| Workflow | File | What it does |
|---|---|---|
| **Workflow** | `.github/workflows/amos-ci-workflow.yml` | Enforces the Amos branching policy: validates branch naming (`feature/*`, `bugfix/*`, `hotfix/*`, `chore/*`) and PR direction (e.g. `feature/*` → `dev`, `dev` → `uat`, `uat` → `main`), checks branch freshness/promotion safety, labels PRs with the required merge method, posts a policy summary comment, and deletes merged topic/hotfix branches. It also validates PR content for topic-branch PRs (Feature/Bugfix/Chore/Hotfix) — a Conventional Commits title, a non-empty `## Release Notes` section for the deployment manager, and a non-empty `Client impact:` line for the client release-notes plugin — and keeps the `client-facing` label in sync with that line automatically. |
| **Quality** | `.github/workflows/amos-ci-quality.yml` | Lint and test checks. Currently a no-op stub for consuming repos — language detection and real per-repo checks are not yet implemented. |
| **Security** | `.github/workflows/amos-ci-security.yml` | Security scanning. Currently a no-op stub. |

`.github/workflows/amos-ci.yml` composes all three into a single reusable workflow. It's the one file consuming repos actually call. It has no trigger of its own beyond `workflow_call` -- it never runs on this repo's own PRs, only when another repo calls into it (see "Why amos-ci doesn't run its own branch policy on itself" below).

A separate file, `.github/workflows/amos-ci-self-test.yml`, exists purely to test *this* repo's own PRs: it runs `.github/scripts/tests/*.sh` against whatever version of the scripts that PR is proposing, so a change to the policy logic is validated before it merges. It's independent of everything above -- it doesn't call, and isn't called by, `amos-ci.yml`.

## How it fits together

```
amos-<repo>/.github/workflows/amos-ci.yml   (per-repo caller, copied from the sample below)
  → amos-ci/.github/workflows/amos-ci.yml   (this repo, composes the three below; workflow_call only)
      → amos-ci-workflow.yml   (branch policy + PR content)
      → amos-ci-quality.yml    (lint/tests)
      → amos-ci-security.yml   (security scanning)

amos-ci/.github/workflows/amos-ci-self-test.yml   (separate, runs directly on amos-ci's own PRs only)
```

### Why amos-ci doesn't run its own branch policy on itself

`amos-ci-workflow.yml`'s branch-naming rules, PR-direction rules and Release Notes/Client impact requirements assume a repo following the Amos `dev`/`uat`/`main` model -- amos-ci itself doesn't follow that model, it's just a repo with plain PRs against `main`, protected by ordinary branch protection configured in the GitHub UI rather than `.github/ruleset.json` (which only ever targets consuming repos, via `conditions.repository_name.include`). Running those checks against amos-ci's own PRs would mean fighting branch-naming rules and Release Notes requirements that don't mean anything here, so `amos-ci.yml` simply never triggers on this repo's own PRs -- see `amos-ci-self-test.yml` above for what does run instead.

Permissions in `amos-ci.yml` and the workflows it composes are scoped per job — the Workflow workflow's jobs get write access for labels/comments, Quality and Security are read-only — regardless of how much a consuming repo grants at its own call site, since permissions can only narrow as they pass down a call chain, never widen.

### Reading amos-ci's own scripts from a private repo

The `policy` and `pr-content` jobs in `amos-ci-workflow.yml` don't check out `.github/scripts` from this repo -- they call two composite actions that live here instead: `.github/actions/evaluate-policy` and `.github/actions/check-pr-content`, each a thin wrapper around the matching script. Referencing an action via `uses: owner/repo/path@ref` makes the runner download that repo's content automatically, using a scoped, auto-expiring token GitHub issues specifically for `uses:` references -- unlike a plain `actions/checkout` of a different repo (which used to be how this worked), that doesn't need a PAT or any other manually-managed credential, private or not.

It does need one thing set once this repo goes private: **Settings → Actions → General → Access**, set to "Accessible from repositories in the organization" (or `gh api --method PUT repos/{owner}/amos-ci/actions/permissions/access -f access_level=organization`). Without it, every consuming repo's calls into `amos-ci.yml`, `amos-ci-workflow.yml` and the two composite actions above fail once amos-ci is private -- this is what makes them resolvable at all, separate from (and in addition to) the branch-protection ruleset in `.github/ruleset.json`. `scripts/apply.sh` sets this automatically on `amos-ci` itself (see below); consuming repos don't need any equivalent setting of their own to call in, just their default Actions permissions left switched on.

Branch cleanup after merge is currently manual. Each repo's native "Automatically delete head branches" setting (`delete_branch_on_merge`, applied by `scripts/apply.sh`) does not reliably handle it here: the PR merge is performed by GitHub's own auto-merge, invoked with the workflow's `GITHUB_TOKEN` (see the `policy` job's "Enable auto-merge" step), and native delete-on-merge doesn't consistently clean up after a merge attributed to a bot/app token rather than a human. A job-based cleanup step has the same problem from the other direction: GitHub suppresses new workflow runs triggered by `GITHUB_TOKEN`-attributed actions, so the `pull_request: closed` event never fires a run to react to. For now, deleting a merged topic/hotfix branch is a manual "Delete branch" click; the only reliable automated fix would be a scheduled job that sweeps merged PRs directly, which hasn't been judged worth the added complexity yet.

This same `GITHUB_TOKEN`-suppression behaviour has a knock-on effect worth calling out for repos that deploy on merge: any workflow that only triggers on `push` to `main`/`uat`/`dev`, or on `pull_request: closed`, will not fire for a PR merged by this workflow's auto-merge step, for the same reason the cleanup job above doesn't fire. A deployment pipeline that assumes "merging to main starts a deploy" will silently stop deploying once a repo adopts Amos CI's auto-merge, with no error anywhere — it just never runs. A repo whose deployment depends on a merge-triggered Actions workflow needs to either move that trigger off `push`/`pull_request: closed` (e.g. `schedule`, polling the target branch for new commits, or `workflow_dispatch`), have the merge performed with a real user's PAT or a GitHub App installation token instead of the default `GITHUB_TOKEN` so the resulting merge is attributed to an actor whose runs aren't suppressed, or have this workflow trigger the deploy directly (e.g. a `workflow_call`/`repository_dispatch` fired right after `gh pr merge` succeeds) instead of relying on GitHub to notice the merge on its own. This isn't something amos-ci needs to solve itself, but it's worth checking any consuming repo's deployment setup against before turning auto-merge on for it.

Both the `policy` and `pr-content` jobs set `concurrency: { group: amos-ci-<job>-<PR number>, cancel-in-progress: true }`. Without this, rapid pushes to the same PR (multiple `synchronize` events close together) can run the job concurrently — since the policy/content comment steps are read-then-write (check if a marker comment exists, then create one), overlapping runs can both decide no comment exists yet and both post one, and label add/remove can thrash if an older run finishes after a newer one. The concurrency group means a new push cancels any still-running check for the same PR, so only the latest commit's result is ever posted.

## Adding Amos CI to a repo

1. Copy [`.github/workflows/amos-ci-repo.yml.sample`](.github/workflows/amos-ci-repo.yml.sample) into the target repo as `.github/workflows/amos-ci.yml`.
2. Copy [`.github/pull_request_template.md.sample`](.github/pull_request_template.md.sample) into the target repo as `.github/pull_request_template.md`. This is what the PR-content check assumes contributors are filling in — without it, `## Release Notes` and `Client impact:` have nothing prompting authors to add them.
3. Add any repo-specific jobs underneath the shared `amos-ci` job — it's a normal caller workflow, so local jobs run alongside the shared one without needing changes here.
4. Add the repo's name to `conditions.repository_name.include` in [`.github/ruleset.json`](.github/ruleset.json) — this is what scopes the shared branch-protection ruleset to that repo.
5. Apply that change in GitHub: go to the org's **Settings → Rules → Rulesets**, open the **Amos Policy** ruleset, and under **Target repositories** add the repo (matching the `repository_name.include` list). Also check the other fields — deletion protection, non-fast-forward, PR review settings, and required status checks — still match `.github/ruleset.json`, and update anything that's drifted.

Steps 1–3 alone get the repo running the shared workflow, but without steps 4-5 its `dev`/`uat`/`main` branches have no actual branch protection — the ruleset never applies to it.

### Branch ruleset

`.github/ruleset.json` is not a per-repo template — it defines a single **org-level** ruleset ("Amos Policy") that protects `dev`/`uat`/`main` (deletion protection, non-fast-forward, required PR review settings, and required status checks for the Workflow/Quality/Security jobs, now including `CI / Workflow / PR Content`). It only takes effect for repos listed in `conditions.repository_name.include`; `.github/ruleset.json` is the source of truth for what that ruleset *should* look like, but keeping the live org ruleset in sync with it is a manual step done through the GitHub UI (see "Adding Amos CI to a repo" above).
