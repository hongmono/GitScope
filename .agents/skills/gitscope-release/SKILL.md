---
name: gitscope-release
description: Commit, publish, and deploy the GitScope macOS app and keep its GitHub Pages homepage aligned with the release. Use when the user asks to release, deploy, ship, 배포, 릴리스, push all GitScope changes, split the work into sensible commits, update release notes, update README, or refresh the homepage before publishing GitScope.
---

# GitScope Release

## Overview

Prepare intentional commits, update user-facing documentation, the homepage when affected, and Sparkle release notes, push `main`, trigger the `release` branch workflow, and monitor every triggered deployment to completion. Use standard Git and GitHub CLI commands so the same instructions work in Codex and Claude Code.

## 1. Confirm scope and repository

- Confirm the checkout is GitScope and `origin` resolves to `hongmono/GitScope`.
- Run `git status --short --branch`, inspect recent commits, and review the complete diff before staging.
- Treat the whole worktree as in scope only when the user explicitly says to commit everything.
- Otherwise preserve unrelated changes and ask if scope cannot be inferred safely.
- Read `.github/workflows/release.yml`, `.github/workflows/pages.yml`, `README.md`, `RELEASE_NOTES.md`, `docs/releasing.md`, and the relevant files under `website/`.
- Require authenticated `gh` access with `gh auth status`.

Stop instead of guessing if the repository, remote, target branch, or intended change scope does not match.

## 2. Update release notes, documentation, and homepage

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

Review homepage impact for every release before committing:

- Compare the outgoing app changes with `website/index.html`, its screenshots, supported environment, feature copy, shortcuts, and download links.
- Update `website/` when the release changes user-visible behavior, navigation, supported environment, installation, branding, or a screen shown on the homepage.
- Replace screenshots when the pictured UI is materially stale. Capture the actual app with a representative repository and crop it to the composition used by the existing page.
- Preserve the homepage's established visual language and responsive behavior. Do not redesign unrelated sections during a routine release.
- Leave the homepage unchanged when the release has no user-facing website impact. Do not create churn only to make the release appear newer.
- Keep homepage changes in a cohesive website commit when practical.

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

If `website/` changed:

- Serve `website/` locally and render at least one desktop and one mobile viewport.
- Verify there is no horizontal overflow, broken image, console error, awkward headline wrapping, or inaccessible keyboard focus.
- Verify dark mode and `prefers-reduced-motion` behavior.
- Run Lighthouse when available and fix regressions in accessibility, best practices, or SEO before publishing.
- If the Pages workflow changed, run `actionlint .github/workflows/pages.yml` or parse it as YAML.

Do not publish while a required check is failing.

## 4. Create sensible commits

- Prefer two to four cohesive commits instead of one broad commit.
- A useful default split is:
  1. release workflow and release documentation;
  2. application feature or fix;
  3. homepage changes;
  4. `RELEASE_NOTES.md`, README, and user-facing documentation.
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
- If `website/` changed, also find and watch the Pages run for the pushed `main` commit:

```bash
gh run list \
  --repo hongmono/GitScope \
  --workflow Pages \
  --branch main \
  --limit 5
gh run watch <pages-run-id> --repo hongmono/GitScope --exit-status
```

- After Pages succeeds, verify `https://hongmono.github.io/GitScope/` contains the updated copy and that changed image assets return HTTP 200.
- Treat a failed Pages run as an incomplete release when the homepage was part of the outgoing changes.
- On success, report the commit hashes, `main` and `release` state, Release and Pages workflow URLs when applicable, the homepage URL when changed, and the published version.
- Trust the workflow's built-in artifact and embedded release-note assertions. Do not separately inspect every release asset unless requested.
