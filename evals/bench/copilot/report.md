## Eval results

`copilot` against `main` on copilot

| Headline | main | copilot | Change |
| --- | --- | --- | --- |
| Real recall | 7/13 | 9/13 | +0.15 better |
| Nit rate | 16% | 5% | -11 better |
| Wrong rate | 0% | 0% | same |
| Minutes | 29.6 | 43.1 | +13.5 worse |
| Dollars | 9.76 | - | - |

### Quality

|  | main | copilot |
| --- | --- | --- |
| Real recall | 7/13 | 9/13 |
| Caught at the first push | 8/21 | 17/21 |
| Reals held back | 0 | 0 |

### Noise

|  | main | copilot |
| --- | --- | --- |
| Threads | 64 | 57 |
| Nits | 10 | 3 |
| Wrong | 0 | 0 |
| Unlabelled | 46 | 42 |
| Threads per 100 changed lines | 1.6 | 1.5 |
| Duplicate threads on one bug | 1 | 3 |

### Calibration

|  | main | copilot |
| --- | --- | --- |
| Highs that are real | 6/19 | 11/35 |
| Mediums that are nits | 7/40 | 3/20 |
| Confidence 3 posted | 0 | 0 |

### Latency

|  | main | copilot |
| --- | --- | --- |
| Seconds | 1778 | 2587 |
| Unchecked (critic timed out) | 3 | 0 |
| Critic timeouts | 3 | 0 |

### Cost

|  | main | copilot |
| --- | --- | --- |
| Dollars | 9.76 | - |
| Input tokens | 1603560 | - |
| Output tokens | 1297086 | - |

### Cases

| Case | Ref | Real | Nit | Wrong | Threads | Seconds | Dollars |
| --- | --- | --- | --- | --- | --- | --- | --- |
| attach-drafts-to-lists | first-push | 3/5 | 0 | 0 | 8 | 583 | - |
| attach-drafts-to-lists | final-push | 1/3 | 0 | 0 | 9 | 538 | - |
| readme-typo | final-push | 0/0 | 0 | 0 | 0 | 64 | - |
| draft-tasks-api | first-push | 5/5 | 1 | 0 | 16 | 715 | - |
| draft-tasks-api | final-push | 3/3 | 1 | 0 | 15 | 617 | - |
| draft-tasks-model | first-push | 3/4 | 0 | 0 | 11 | 491 | - |
| draft-tasks-model | final-push | 2/3 | 0 | 0 | 16 | 514 | - |
| paged-connectors | first-push | 3/4 | 2 | 0 | 8 | 431 | - |
| paged-connectors | final-push | 1/2 | 2 | 0 | 10 | 408 | - |
| route-discovery | first-push | 3/3 | 0 | 0 | 7 | 442 | - |
| route-discovery | final-push | 2/2 | 0 | 0 | 7 | 446 | - |
