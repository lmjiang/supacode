---
description: Sync the newest upstream Supacode release into this fork, apply self-use patches, verify, and ship an ad-hoc package.
---

You maintain the `lmjiang/supacode` fork for self-use builds. Fork `main` should track the newest upstream
Supacode release plus small local patches such as ad-hoc release packaging and disabled automatic line-change
polling. Run independently, and stop only when a step needs judgment you cannot safely make.

## Steps

1. **Detect (idempotent).**
   - Ensure remote: `git remote get-url upstream` or `git remote add upstream https://github.com/supabitapp/supacode.git`; then `git fetch upstream --tags --force --quiet` (`--force` so upstream's rolling `tip` tag updates instead of failing the fetch).
   - Newest upstream stable release: `TAG=$(gh release view --repo supabitapp/supacode --json tagName -q .tagName)`.
   - If fork `main` already contains it — `git merge-base --is-ancestor "$(git rev-list -n1 "$TAG")" HEAD` succeeds — there is nothing to do. Report "already on $TAG" and STOP.

2. **Merge.** On a clean `main`: `git merge "$TAG" --no-edit`.
   - On conflicts, prefer upstream behavior unless the conflict is in an intentional self-use patch
     (`release-fork.yml`, ad-hoc telemetry stripping, or line-change polling control).
   - If a conflict is genuinely *logically incompatible* (not just adjacent edits) and you'd be guessing, run `git merge --abort` and STOP with a precise report: which file/hunk, what each side wanted, why it's ambiguous.

3. **Verify (a clean text-merge can still be semantically wrong).** Upstream usually adds source files, so regenerate first:
   - `rm -f .build/.tuist-generated-stamps/development && make build-app`
   - `make test`
   - If build OR tests fail: do **not** push. Report the failing target/test and the upstream change you suspect, then STOP for me.

4. **Ship (only when build + tests are green).**
   - `git push origin main`
   - `gh workflow run release-fork.yml --repo lmjiang/supacode --ref main` — the macOS Action builds + uploads the ad-hoc package (a fork can't build a mac app in a Linux sandbox, so packaging is delegated to Actions).
   - Report: which `$TAG` was merged, that `main` is pushed, and the release run URL (`gh run list --repo lmjiang/supacode --workflow=release-fork.yml --limit 1`).

## Hard rules
- Single repo, your machine, interactive subscription billing — fine. **Never** force-push, rewrite `main` history, or touch any upstream repo.
- A wrong auto-resolve that silently breaks upstream behavior is worse than waiting for me: when unsure about a
  conflict's correctness, STOP and report rather than guess.
- Don't disable tests or skip the verify step to make a run "succeed".
