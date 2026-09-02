---
name: thingie-e2e-consumer-testing
description: Test unmerged thingie changes end to end against a real consumer repo (e.g. special_sauce) before merging or tagging a release, by pinning the consumer's Gemfile to a thingie branch and exercising it with real PRs.
---

## When to use

A thingie PR changes review, posting, or approval behavior in a way unit specs can't fully exercise — rate-limit handling, GitHub API failure paths, load/volume behavior, or anything that only shows up against a real PR with the real GitHub API. Before merging (or after merging but before tagging a release consumers will pick up), prove it end to end in a consumer repo rather than trusting specs alone.

## Why not just merge and tag

Consumers (special_sauce, etc.) pin thingie by tag in their `Gemfile.lock`. A merge to thingie's `main` changes nothing for them until someone bumps the tag. That gap is exactly the window to test the new code against real PRs without any risk of the untested code reaching production traffic — nothing merges or tags until the test proves out.

## Pin to the PR's own branch. Do not build a synthetic integration branch.

The tempting shortcut is a dedicated branch that merges several unmerged thingie PRs together, so one pin can exercise "the next release" as a whole. Don't. It creates a branch with no PR of its own, so nothing on GitHub explains what it contains — a raw commit SHA on a PR diff page has no link back to the branches or commits behind it, and `bonusly/thingie/pull/N/changes` will show a SHA that isn't `N`'s own history at all. It also invites exactly the git mistake this skill exists to prevent: once that synthetic branch needs to change (a PR it carries gets merged elsewhere, one under test needs to be dropped), the only ways to fix it are rewriting its history — `reset --hard`, force-push — on a branch that's already been pushed and may already be reviewed. That is a destructive operation on shared state for no reason a test needed.

**Test one PR's own branch, pinned by its own name.** If a PR needs `main` merged in to stay current, merge forward with `git merge --no-edit origin/main` — never `reset --hard`, never force-push a thingie branch that's an open PR meant to land. Fixes are always new commits (`git revert -m 1 <sha>` to undo an unwanted merge), never rewritten history. If two genuinely unrelated PRs both got tangled onto one branch by mistake, `revert -m 1` the merge that brought the wrong one in — it's forward-only and safe on a pushed branch.

If the release genuinely depends on multiple PRs shipping together, test them as separate pin PRs in the consumer repo (one per thingie branch) rather than merging them into a shared thingie branch first. Losing the "does the combination interact badly" signal costs less than the class of mistake a synthetic branch invites.

## Workflow

1. **Pin the consumer's Gemfile to the thingie PR's own branch, not a raw SHA.**
   ```ruby
   gem "thingie", bonusly_github: "thingie", branch: "pw/decouple-approval-from-posting", require: false
   ```
   A `ref:` pin to a raw commit SHA is just as correct — Bundler resolves either fine — but it is opaque everywhere GitHub renders a diff. A PR page, `/pull/N/changes`, and `/compare` views all show a SHA with no link to the branch or commits it came from, so a reviewer (human or thingie's own LLM reviewer) has to go dig for what it actually points to. `branch:` costs nothing, stays legible, and names a real PR someone can click through to. Re-lock **conservatively** after switching the pin so the diff stays limited to the `thingie` GIT block:
   ```
   bundle lock --update=thingie --conservative
   ```
   Without `--conservative`, Bundler will happily bump unrelated transitive gems (`async`, `httpx`, `io-event`, etc.) as a side effect, and that noise makes the pin PR's diff harder to review and easier to misjudge.

2. **Bump `lib/thingie/version.rb` to a `.pre` version** (e.g. `0.7.0.pre`) as a commit on the PR's own branch. Every approval comment and stats event stamps the gem version, and the auto-approval control document (`.thingie/config.toml` + the SOC2 control doc in the consumer repo) leans on that stamp to trace a decision to an exact rule engine. Running unreleased code while still reporting the last tagged version breaks that trail and will read as a lie in review. Drop this commit (or let it get superseded) once the real release actually tags — the PR branch shouldn't carry a stale `.pre` past that point.

3. **Open the pin as its own PR, titled `DO NOT MERGE: ...`, and never merge it.** Its only job is to prove the new gem loads and runs — expect whatever decision the repo's existing rules would produce on a `Gemfile`/`Gemfile.lock` change (typically a protected-path block). That's a pass, not a failure: the point isn't the decision, it's that the pipeline ran without crashing and the version stamp confirms it's running the code under test.

4. **For behavior that only shows up under a specific real-world shape (volume, a past incident, a specific file mix), reproduce that shape in a second PR stacked on the pin PR.** If reproducing a past incident by reverting its merge commit, expect `git revert -m 1 <merge-sha>` to conflict if the touched files have drifted since — fall back to restoring the same files to their pre-incident content directly:
   ```
   git diff --name-only <merge-sha>^1 <merge-sha> > /tmp/touched.txt
   # filter to files that existed pre-merge (diff against <merge-sha>^1's tree) —
   # a file the incident PR added won't exist to restore
   git checkout <merge-sha>^1 -- $(cat /tmp/touched.txt)
   ```
   Title this PR `DO NOT MERGE` too. Its base branch is the pin PR's branch, not `main` — it must inherit the pin.

5. **Read the decision, not just the CI conclusion.** A green `Thingie Review` check only means the job didn't crash. The actual signal is in the PR's `<!-- thingie-approval-status -->` comment (decision + reasons) and, for a posting/volume test, in the workflow log for the specific behavior under test (retry/backoff lines, a posting tally, whether an `approval.decided` stats event exists at all). Fetch both:
   ```
   gh api repos/<org>/<repo>/issues/<pr>/comments --jq '.[] | select(.body|test("thingie-approval-status")) | .body'
   ```

6. **Clean up after.** Close both DO-NOT-MERGE PRs and delete their branches once the behavior is confirmed. They exist to prove a point, not to persist. Ask before force-pushing or deleting anything in the consumer repo even when the PR is marked throw-away — "throw-away" describes the PR's destination (never merges), not blanket permission for every destructive action; confirm scope explicitly per repo/PR rather than assuming it carries over.

## Verification

- The pin PR's approval-status comment shows the `.pre` version, confirming the new gem actually loaded (not a cached/stale bundle).
- `bundle lock --update=thingie --conservative` produced a diff limited to the thingie GIT block (`revision:`/`branch:`/`tag:` and the gem's own version line) — anything wider means a non-conservative lock ran.
- For a load/incident-reproduction PR: the workflow log shows the specific mechanism under test (e.g. backoff waits, a posting tally line) — silence there means the code path wasn't actually exercised, whatever the CI conclusion says.
- `git log --oneline <thingie-branch>` shows only commits that belong: the PR's own work, an optional forward `merge` of `main`, and the `.pre` version bump. No unrelated PR's content should appear in the history unless that was the deliberate, stated point of the test.

## Failure signatures

| Symptom | Cause | Fix |
|---|---|---|
| A thingie test branch ends up carrying an unrelated PR's commits | A synthetic integration branch merged more than one PR together, or `main` was merged in without checking what it had picked up since the branch diverged | `git revert -m 1 <merge-sha>` to remove the unwanted content as a new commit — never `reset --hard` a branch that's already been pushed. Prefer pinning to the single PR's own branch from the start (see above) so this can't happen. |
| About to run `git reset --hard` or `push --force` on a thingie branch to fix it | Reaching for history rewrite instead of a forward commit | Stop. Check `git rev-list --left-right --count HEAD...origin/<branch>` — if local is only *behind*, fast-forward (`git merge --ff-only`) instead of resetting. If unwanted content is already pushed, revert it forward. Only a repo/PR explicitly confirmed as throw-away (ask if unsure) permits force-push, and even then, prefer the forward fix first. |
| Pin PR's approval comment stamps the old tagged version | Bundler resolved a cached gem instead of the pinned branch/ref | Delete `Gemfile.lock`'s thingie entry and re-run `bundle lock --update=thingie`; confirm the workflow's `bundler-cache: true` step actually re-resolved rather than restoring a stale cache keyed on the old lockfile hash. |
| `git revert -m 1 <merge-sha>` conflicts | Files touched by the incident have changed since | Don't resolve the conflict by hand — abort (`git revert --abort`) and restore the pre-merge file content directly instead (step 4); it reproduces the same review *shape* without fighting unrelated drift. |
| Pin PR's `Gemfile.lock` diff touches dozens of unrelated gems | `bundle lock --update=thingie` ran without `--conservative` | Re-run with `--conservative`, or `git checkout -- Gemfile.lock` and redo the update conservatively from a clean state. |
