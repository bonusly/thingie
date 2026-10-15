# Input-token cost on special_sauce (October 2026)

Why some Thingie runs on special_sauce used 0.9–2.2 million input tokens, and what this PR changes.

## Where the input tokens went

Per-call `tokens:` debug lines summed from each run's job log, checked against `thingie-stats.jsonl`; they account for 95–99% of each run's input (the rest is dedupe and open-finding calls, which don't log per-call tokens). Reviewer `z-ai/glm-5.3`, critic `z-ai/glm-5.3-flash`, OpenRouter.

| Run (special_sauce test PR) | Run input | Review calls | Critic calls | `models.json` reads | Their cost / run cost |
|---|---|---|---|---|---|
| 38656252871 (#27924, 10 files) | 875,777 | 826,171 (13 calls) | 43,234 (17) | 762,405 (review of `.thingie/config.toml`) | $1.66 / $2.77 |
| 38656259961 (#27927, 37 files) | 2,201,937 | 1,064,259 (47) | 1,040,689 (76) | 767,080 (workflow review) + 771,937 (critic, config finding) | $1.81 / $7.17 |
| 38648220706 (#27921, 6 files) | 855,529 | 779,478 (6) | 57,711 (6) | 759,120 (review of `.thingie/config.toml`) | $1.09 / $1.46 |
| 38656255044 (#27925, 13 files) | 145,265 | 99,851 (16) | 38,560 (10) | read too, but its 768,444 tokens were billed as cache read | $0.32 / $1.18 |

Leaving out the `models.json` reads, every review and critic call in these runs used 0.4k–22k input tokens; the prompt, project rules and skills are not the problem.

## Root cause

`FileTool#execute` returned the whole file with no size cap. special_sauce's `config/ruby_llm/models.json` is 2.7 MB (115,790 lines, about 760k tokens). When a PR changes `.thingie/config.toml` or the Thingie workflow, the model reads that file to check a model name, in the review and sometimes in the critic. Every one of these test PRs changed `.thingie/config.toml` to pin a test build, so the spike is mostly a test-setup artifact; real PRs rarely touch that file. The search tool already capped its output (60 matches of 240 characters).

## Change in this PR

The file tool stops at 2,000 lines or 100 KB, whichever comes first, and says so: "Truncated: showing lines 1-N of M. Use the search tool with this path to find the lines you need further down." A single line over 100 KB shows its first 100 KB. Through the capped tool, `models.json` is 42,808 bytes (about 12k tokens) instead of about 760k.

## Not verified / still open

- Savings are inferred from the logs, not measured on a re-run.
- The cap also truncates real source files over 100 KB (e.g. `app/controllers/mcp/fin_controller.rb`); the model then has to search for the rest. 100 KB is a judgement call.
- On large PRs, output (mostly reasoning) is the bigger remaining cost: #27927 used 838k output tokens, 12–22k thinking tokens per file review. Not addressed here.
