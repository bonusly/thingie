# Bench

Seeded pull requests against a fixture todo app, run through the review pipeline on your machine or in CI,
and scored against labels written in advance. It exercises the LLM calls only: review, critic, post-process.
Nothing is posted and no pull request is opened.

## Run it

```sh
bundle exec evals/bench/run                           # every case, once, against baseline.json
bundle exec evals/bench/run draft-tasks-model         # one case
bundle exec evals/bench/run --repeat 3 --label pr-intent
bundle exec evals/bench/run --report evals/bench/results/<label>.json
bundle exec evals/bench/run --rescore evals/bench/results/<label>.json   # after labels change
```

It needs the LLM key in `~/.thingie/.env` (or `LLM_API_KEY`); `LLM_PROVIDER` and `LLM_MODEL` override the
pinned ones in `config.toml`. Each case is built as a fresh git repo under `tmp/<case>/`: the fixture app
tagged `pr-base`, the case's `early/` overlay (when it has one) as `pr-early`, and its `head/` overlay as
`pr-head`. The run file goes to `results/<label>.json` (`--out` to put it elsewhere) and one line to
`history.jsonl` (`--no-record` to skip that). `--no-early` skips the early-push reviews.

`--rescore` matches a run file's findings against the labels as they are now, with the run's own matcher
config, and rewrites the file in place (or to `--out`). No review runs and nothing is recorded.

The model samples a different set of findings each run, so compare variants over `--repeat 3`: totals are
then the mean over repeats, and the report shows the spread beside each headline number.

## Pieces

- `app/` the fixture: a Rails-shaped todo app with ~340 files. It never boots. Keep it correct; the cases
  carry the defects.
- `cases/<name>/` one seeded PR each: `case.yml` (title, body, labels, `delete:` for files the PR removes),
  `head/` (the files at the final push, overlaid on the app), optional `early/` (an earlier push, before the
  author fixed what a reviewer caught). Case names are letters, digits, `-` and `_`.
- `config.toml` the fixture's Thingie config, pinned to special_sauce's production settings. `variants/`
  TOML laid over it, section by section, so a variant names only what it changes.
- `baseline.json` the run file for main, which every report compares against. Make it with
  `evals/bench/run --label main --out evals/bench/baseline.json` on main; until it exists, reports show the
  run alone. Refresh it when main changes something that should move the numbers.
- `history.jsonl` one line per recorded run, so the dimensions can be read over time.

## Labels

Each label is one defect, `real`, `nit` or `wrong`, with the file it is in and a note the matcher can use.
`push` says where the defect exists: `early` (only at the early push; the author fixed it by head), `both`
(the default), or `head` (introduced in the last push). A review of head is scored against `both` and
`head`; the early push against `early` and `both`. The review model matches each posted finding to the
label for the same defect; a finding with no match is `unlabelled`. Label it against the code, add it to the
case, and `--rescore` the runs that have it.

## Dimensions

| Dimension | Metrics |
|---|---|
| Quality | real recall (planted bugs found at head), caught at the early push, reals held back into the summary |
| Noise | threads, nits, wrong, unlabelled, nit rate, wrong rate, threads per 100 changed lines, duplicates |
| Calibration | Highs that are real, Mediums that are nits, confidence-3 findings posted |
| Latency | seconds, unchecked findings, critic timeouts |
| Cost | dollars, input and output tokens |

The headline row is real recall, nit rate, wrong rate, minutes and dollars. A candidate that moves recall
down or wrong up outside the spread is a no, whatever it does to nits.

## CI

`.github/workflows/bench.yml` runs on every push except docs-only ones, writes the report to the job
summary and keeps the run file as an artifact. It is informational and never blocks a merge. It needs the
`LLM_API_KEY` secret and the `LLM_MODEL` and `LLM_PROVIDER` variables the review workflow already uses. A
full run is five cases, head and early, about an hour and a few dollars at the pinned model.
