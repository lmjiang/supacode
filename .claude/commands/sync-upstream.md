---
description: Sync the newest upstream supacode release into this fork, resolve conflicts, verify, and ship an ad-hoc package — autonomously.
---

You maintain the `lmjiang/supacode` fork (FSL, self-use, built for fun). Fork `main` = upstream + this fork's **remote-SSH-host feature**. Your job each run: pull in the newest UPSTREAM RELEASE, keep the remote-SSH work intact, verify it still builds and passes tests, and ship a package — running on your own, stopping for me only when a step needs judgment you can't safely make.

## Steps

1. **Detect (idempotent).**
   - Ensure remote: `git remote get-url upstream` or `git remote add upstream https://github.com/supabitapp/supacode.git`; then `git fetch upstream --tags --force --quiet` (`--force` so upstream's rolling `tip` tag updates instead of failing the fetch).
   - Newest upstream stable release: `TAG=$(gh release view --repo supabitapp/supacode --json tagName -q .tagName)`.
   - If fork `main` already contains it — `git merge-base --is-ancestor "$(git rev-list -n1 "$TAG")" HEAD` succeeds — there is nothing to do. Report "already on $TAG" and STOP.

2. **Merge.** On a clean `main`: `git merge "$TAG" --no-edit`.
   - On conflicts, resolve by **keeping BOTH intents** — upstream's new behavior AND the fork's remote work. Hotspots (files both sides change): `WorktreeTerminalManager`, `ZmxClient`, `WorktreeTerminalState`, `SidebarStructure`, `AppFeature`, `TerminalLayoutSnapshot`, `GitClient`/`GitClientDependency`.
   - The fork's remote code is recognizable by: `host` / `RemoteHost`, `ssh` / `SSHCommand`, `remote:` host-keyed ids, the Local/Remote sidebar partition, and in-band OSC (`AgentPresenceOSC`, presence/notify). **Never delete a `host != nil` branch or an OSC/presence path** while resolving.
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
- A wrong auto-resolve that silently breaks remote-SSH is worse than waiting for me: when unsure about a conflict's correctness, STOP and report rather than guess.
- Don't disable tests or skip the verify step to make a run "succeed".
