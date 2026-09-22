# Amos CI

Central home for the shared CI/policy system used across `amos-*` repositories. Every `amos-*` repo runs the same set of checks on its pull requests by calling into this repo, instead of each repo maintaining its own copy.

## What Amos CI checks

Amos CI composes three concerns, each its own reusable GitHub Actions workflow:

| Workflow | File | What it does |
|---|---|---|
| **Workflow** | `.github/workflows/amos-ci-workflow.yml` | Enforces the Amos branching policy: validates branch naming (`feature/*`, `bugfix/*`, `hotfix/*`, `chore/*`) and PR direction (e.g. `feature/*` → `dev`, `dev` → `uat`, `uat` → `main`), checks branch freshness/promotion safety, labels PRs with the required merge method, posts a policy summary comment, and deletes merged topic/hotfix branches. It also validates PR content for topic-branch PRs (Feature/Bugfix/Chore/Hotfix) — a Conventional Commits title, a non-empty `## Release Notes` section for the deployment manager, and a non-empty `Client impact:` line for the client release-notes plugin — and keeps the `client-facing` label in sync with that line automatically. |
| **Quality** | `.github/workflows/amos-ci-quality.yml` | Lint and test checks. Currently a no-op stub — language detection and real checks are not yet implemented. |
| **Security** | `.github/workflows/amos-ci-security.yml` | Security scanning. Currently a no-op stub. |

`.github/workflows/amos-ci.yml` composes all three into a single reusable workflow. It's the one file consuming repos actually call.

## How it fits together

```
amos-<repo>/.github/workflows/amos-ci.yml   (per-repo caller, copied from the sample below)
  → amos-ci/.github/workflows/amos-ci.yml   (this repo, composes the three below)
      → amos-ci-workflow.yml   (branch policy + PR content)
      → amos-ci-quality.yml    (lint/tests)
      → amos-ci-security.yml   (security scanning)
```

`amos-ci.yml` in this repo triggers on `pull_request` directly (so this repo's own PRs are checked too) and on `workflow_call` (so other repos can call it as a reusable workflow). Permissions are scoped per job — the Workflow workflow's jobs get write access for labels/comments/branch cleanup, Quality and Security are read-only — regardless of how much a consuming repo grants at its own call site, since permissions can only narrow as they pass down a call chain, never widen.

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
