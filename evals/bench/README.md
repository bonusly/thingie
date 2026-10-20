# Bench

Seeded pull requests against a fixture todo app, run through the review pipeline on your machine or in CI,
and scored against labels written in advance. It exercises the LLM calls only: review, critic, post-process.
Nothing is posted and no pull request is opened.

## Run it

```sh
bundle exec evals/bench/run                           # every case, once, against baseline.json
bundle exec evals/bench/run --fast                    # the small cases only (tier: fast)
bundle exec evals/bench/run draft-tasks-model         # one case
bundle exec evals/bench/run --repeat 3 --label pr-intent
bundle exec evals/bench/run --report evals/bench/results/<label>.json
bundle exec evals/bench/run --rescore evals/bench/results/<label>.json   # after labels change
```

It needs the LLM key in `~/.thingie/.env` (or `LLM_API_KEY`). The models come from `config.toml` or a variant;
the bench applies them as overrides, so `LLM_MODEL` and `LLM_PROVIDER` in the environment do not change them. Each case is built as a fresh git repo under `tmp/<case>/`: the fixture app
tagged `pr-base`, the case's `first-push/` overlay (when it has one) as `pr-first-push`, and its `final-push/`
overlay as `pr-final-push`. The run file goes to `results/<label>.json` (`--out` to put it elsewhere) and one line to
`history.jsonl` (`--no-record` to skip that). `--no-first-push` reviews only each case's final push.

`--rescore` matches a run file's findings against the labels as they are now, with the run's own matcher
config, and rewrites the file in place (or to `--out`). No review runs and nothing is recorded.

The model samples a different set of findings each run, so compare variants over `--repeat 3`: totals are
then the mean over repeats, and the report shows the spread beside each headline number.

## Pieces

- `app/` the fixture: a Rails-shaped todo app with ~340 files. It never boots. Keep it correct; the cases
  carry the defects.
- `cases/<name>/` one seeded PR each: `case.yml` (title, body, labels, `delete:` for files the PR removes),
  `final-push/` (the files at the PR's last push, overlaid on the app), optional `first-push/` (the same PR
  at its first push, before the author fixed what a reviewer caught). Case names are letters, digits, `-` and `_`.
- `config.toml` the fixture's Thingie config, pinned to special_sauce's production settings. `variants/`
  TOML laid over it, section by section, so a variant names only what it changes.
- `baseline.json` the full run file for main (every case, both pushes), which reports compare against. In
  CI only `eval-full` runs compare with it, and they read it from main, not from the pull request's branch;
  `eval-fast` runs are reported on their own (`--no-baseline`). Refresh it from a full run on main when main
  changes something that should move the numbers: `evals/bench/run --label main --out evals/bench/baseline.json`.
- `history.jsonl` one line per baseline, so the dimensions can be read over time. Add a line when the
  baseline is refreshed.

## Labels

Each label is one defect, `real`, `nit` or `wrong`, with the file it is in and a note the matcher can use.
`push` says where the defect exists: `first` (only at the first push; the author fixed it by the final one),
`both` (the default), or `final` (introduced in the final push). A review of the final push is scored against
`both` and `final`; the first push against `first` and `both`. The review model matches each posted finding to the
label for the same defect; a finding with no match is `unlabelled`. Label it against the code, add it to the
case, and `--rescore` the runs that have it.

## Dimensions

| Dimension | Metrics |
|---|---|
| Quality | real recall (planted bugs found at the final push), caught at the first push, reals held back into the summary |
| Noise | threads, nits, wrong, unlabelled, nit rate, wrong rate, threads per 100 changed lines, duplicates |
| Calibration | Highs that are real, Mediums that are nits, confidence-3 findings posted |
| Latency | seconds, unchecked findings, critic timeouts |
| Cost | dollars, input and output tokens |

The headline row is real recall, nit rate, wrong rate, minutes and dollars. A candidate that moves recall
down or wrong up outside the spread is a no, whatever it does to nits.

## CI

`.github/workflows/bench.yml` runs when a label is added to a pull request: `eval-fast` runs the cases
marked `tier: fast` in their `case.yml` (the small ones), final push only, for a quick read; `eval-full`
runs every case, first and final push. Add the
label again to re-run, or run it on demand. Then: one job per case in parallel (both pushes), then a report job that merges their run
files (`--merge`), writes the table to the job summary, keeps the merged `run.json` as an artifact, and
posts an "Eval results" comment on the pull request (headline, the full report and the run details folded
under it), updated on each run. It is informational and never
blocks a merge. It needs the `LLM_API_KEY` secret and
the `LLM_MODEL` and `LLM_PROVIDER` variables the review workflow already uses. Wall time is the slowest case,
about 15 minutes; the model spend is about ten dollars per run at the pinned model.
