---
name: bench-experiment
description: How to test a change to Thingie's review quality, noise, latency or cost on the bench without tying up a machine - one draft DO NOT MERGE pull request per experiment, run twice to screen and four or five times to confirm a small gain, judged on recall and wrong findings before nits and dollars. Use when trying a model, a prompt, a config value, a skill or a pipeline change, or when asked how many runs a result needs.
---

## When to use

Any change meant to move what Thingie finds or posts: a review or critic model, a prompt or skill, a
`[post_process]` or `[verify]` value, a pipeline step added or skipped. Also when a result is in and the
question is whether it is real. `evals/bench/README.md` says what the bench is and how to run it by hand;
this skill is the protocol around it.

## One experiment, one pull request

1. Branch from `main`, or from the fix or feature the experiment depends on. Never edit someone else's
   open PR to run it; branch from its head instead.
2. Change exactly one thing. A model goes in `evals/bench/config.toml` (`model`, or `[verify] model`);
   a prompt or config change goes where production would get it. Two changes in one branch cannot be
   told apart afterwards.
3. Open a draft PR titled `DO NOT MERGE: bench <what changed>`, with the hypothesis in one sentence and
   the comparison it should be read against.
4. Add the `eval-full` label. GitHub Actions runs every case in parallel and posts an **Eval results**
   comment against `main`'s `baseline.json`. About $10 and 15 to 30 minutes on `glm-5.3`.
5. To run again, dispatch it: `gh workflow run bench.yml --ref <branch> -f pr_number=<n> -f tier=full`.
   Removing and re-adding the label also works, but GitHub sometimes raises no event for the toggle and
   nothing runs; check that a run appeared. Wait until the current run has finished first: the workflow
   cancels an in-progress run on the same PR when a new one starts.
6. Close the PR without merging when its runs are done. A change worth shipping gets its own real PR.

## How many runs

Recall on identical config moves by about one bug between runs on `glm-5.3` and Sonnet, and by up to four
on DeepSeek. The bench has 13 planted bugs at the final push, so one run cannot tell a gain of one or two
bugs from luck.

- **Two runs to screen.** Drop the candidate if either run loses recall or posts a wrong finding that
  `main` does not. Most candidates fail here, and nothing more is spent on them.
- **Four or five runs to confirm** a gain of one or two bugs before shipping it. With a spread of about
  1.5 bugs, that many runs per side puts a two-bug difference clearly outside the noise. Compare the
  mean, and look at the spread the report shows beside it.
- **A bigger bench beats more repeats.** Doubling the seeded cases halves the noise the way doubling runs
  does, and widens what the bench can catch. Once a winner is chosen, add cases before adding runs.

Run `main` again now and then too. Its baseline is one run; a second sample says how much of a candidate's
difference is the bench moving on its own.

## Reading a result

Order: real recall, then wrong, then nits, then minutes, then dollars. A candidate that moves recall down
or wrong up outside the spread is a no, whatever it does to nits. Then:

- **Unlabelled threads are a floor on nits, not a count.** Label them against the fixture, add them to
  the case, and `--rescore` every run that has them before comparing nit rates.
- **A case that crashed is lost recall, not a finding.** Check each case job's conclusion. A run with
  `x/10` where the bench has 13 bugs lost a case; fix the crash (it is a Thingie bug) and rerun.
- **Minutes depend on the hour.** CI and provider load swing them by 2x on identical config. Compare
  tokens and dollars first.
- **One run looking great is the moment to run it again**, not to write it up.

## Pitfalls that cost runs

- `LLM_MODEL` and `LLM_PROVIDER` in the workflow do not change the model: the bench applies
  `config.toml` as overrides, which win over the environment. Pin the model in the config.
- A model slug must be in `.thingie/models.json` or the run dies with `Unknown model`. For a new slug,
  run `bundle exec thingie models --path .thingie/models.json` on the branch and commit the registry.
- After a push, wait for GitHub to see the new head before toggling the label, or the run starts on the
  old commit. Check the run's `headSha` against the branch.
- The critic stays `glm-5.3-flash` unless the experiment is about the critic; say so in the PR.
- Experiments on top of an unmerged fix branch from that fix, so a known crash cannot lose a case.

## Writing it up

The PR's Eval results comment is the record. When a round ends, note in the winning PR which candidates
were screened out and on which run, so the next round does not repeat them.
