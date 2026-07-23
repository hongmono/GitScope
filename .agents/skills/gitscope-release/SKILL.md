---
name: gitscope-release
description: Commit, publish, and deploy the GitScope macOS app through its main and release branches. Use when the user asks to release, deploy, ship, 배포, 릴리스, push all GitScope changes, split the work into sensible commits, update release notes, or update README before publishing GitScope.
---

# GitScope Release

## Overview

Prepare intentional commits, update user-facing documentation and Sparkle release notes, push `main`, trigger the `release` branch workflow, and monitor it to completion. Use standard Git and GitHub CLI commands so the same instructions work in Codex and Claude Code.

## 1. Confirm scope and repository

- Confirm the checkout is GitScope and `origin` resolves to `hongmono/GitScope`.
- Run `git status --short --branch`, inspect recent commits, and review the complete diff before staging.
- Treat the whole worktree as in scope only when the user explicitly says to commit everything.
- Otherwise preserve unrelated changes and ask if scope cannot be inferred safely.
- Read `.github/workflows/release.yml`, `README.md`, `RELEASE_NOTES.md`, and `docs/releasing.md`.
- Require authenticated `gh` access with `gh auth status`.

Stop instead of guessing if the repository, remote, target branch, or intended change scope does not match.

## 2. Update release notes and documentation

- Rewrite `RELEASE_NOTES.md` for every release with concise, user-facing changes in Korean.
- Describe benefits and visible behavior, not internal filenames or implementation details.
- Include only changes shipped by the outgoing commits.
- Use sections when useful, such as new features, improvements, and fixes.
- Do not include a hard-coded version; the workflow assigns `v0.1.<run number>`.
- Update README when user-visible behavior, installation, supported environment, or release artifacts changed.
- Keep README wording aligned with implemented behavior; do not claim unsupported Git operations.
- Update `docs/releasing.md` only when the release process itself changed.
- Keep release notes or README changes in a dedicated documentation commit when practical.

The workflow uses `RELEASE_NOTES.md` both as the GitHub Release body and as embedded Sparkle update notes. Do not deploy with an empty or stale file.

## 3. Validate before committing

Run checks proportional to the diff:

```bash
git diff --check
xcodebuild \
  -project GitScope.xcodeproj \
  -scheme GitScope \
  -configuration Debug \
  -derivedDataPath /tmp/GitScopeDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
xcodebuild \
  -project GitScope.xcodeproj \
  -scheme GitScope \
  -configuration Release \
  -derivedDataPath /tmp/GitScopeReleaseDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

If the release workflow changed, also run:

```bash
actionlint .github/workflows/release.yml
```

If `actionlint` is unavailable, at minimum parse the YAML:

```bash
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/release.yml")'
```

Do not publish while a required check is failing.

## 4. Create sensible commits

- Prefer two to four cohesive commits instead of one broad commit.
- A useful default split is:
  1. release workflow and release documentation;
  2. application feature or fix;
  3. `RELEASE_NOTES.md`, README, and user-facing documentation.
- Do not create empty commits or split tightly coupled code only to increase commit count.
- Stage explicit paths. Use partial staging when one file contains unrelated concerns.
- Inspect `git diff --cached --check`, `git diff --cached --stat`, and staged file names before each commit.
- Use concise conventional messages such as `feat:`, `fix:`, `ci(release):`, and `docs:`.

After committing, require a clean worktree and review `origin/main..main`.

## 5. Push main safely

Fetch immediately before publishing:

```bash
git fetch origin
git rev-list --left-right --count origin/main...main
git log --oneline origin/main..main
```

- Never force-push `main`.
- If `origin/main` is ahead or has diverged, reconcile from a clean worktree before continuing.
- Push only after confirming the outgoing commits:

```bash
git push origin main
```

## 6. Trigger deployment

GitScope deploys from the `release` branch. Do not create the release tag manually.

- Fetch and verify that advancing `release` to `main` is a fast-forward.
- If `origin/release` differs and is an ancestor of `main`, trigger deployment with:

```bash
git push origin main:release
```

- If `release` already points at the requested commit and the user explicitly wants a redeploy, use workflow dispatch:

```bash
gh workflow run Release --repo hongmono/GitScope --ref release
```

- Never force-push `release`.
- Do not modify GitHub Environment protection, reviewers, variables, or secrets as part of a normal release.

## 7. Monitor to completion

- Find the Release workflow run matching the deployed commit.
- Watch it until terminal success or failure:

```bash
gh run list \
  --repo hongmono/GitScope \
  --workflow Release \
  --branch release \
  --limit 5
gh run watch <run-id> --repo hongmono/GitScope --exit-status
```

- If it fails, inspect `gh run view <run-id> --log-failed`, diagnose the failing step, and make a new fix commit rather than rewriting published history.
- If it waits for approval, report the exact waiting condition. Do not approve or alter environment rules unless the user explicitly asks.
- On success, report the commit hashes, `main` and `release` state, workflow URL, and published version.
- Trust the workflow's built-in artifact and embedded release-note assertions. Do not separately inspect every release asset unless requested.
