---
name: thingie-yard-doc-conventions
description: Add YARD documentation comments to thingie's Ruby classes following this repo's conventions for Thor commands, RubyLLM::Tool subclasses, and Data.define/Struct models.
---
<!-- zeroshot-skill {"schema":1,"id":"019f8ed9-aed3-7327-9d58-f2f02960c5d4","createdBy":"zeroshot","managedBy":"zeroshot","revision":1} -->

## When to use

Asked to add YARD documentation / doc comments to files under `lib/thingie` in the thingie gem, or when `.yardopts`, `rake yard`, or YARD coverage comes up.

## Workflow

1. Read every target file fully before editing — do not guess method signatures or existing comments from a directory listing.
2. `.yardopts` sets `--markup markdown --markup-provider kramdown`: write YARD prose in Markdown (backticks for code, not RDoc `+...+`).
3. Add comment blocks directly above `def` lines for **public methods only**. Never touch anything under a `private` marker, and never change logic — this is comments-only work.
4. Skip methods that already have a doc comment above them (check first) rather than duplicating or overwriting existing prose.
5. Thor CLI classes (`class CLI < Thor`, e.g. `lib/thingie/cli.rb`): Thor already documents each command via `desc '...'` immediately above the method, so keep the YARD comment to a one-line summary plus only non-obvious `@param`/`@return` tags — do not restate what `desc` already says.
6. Methods defined inside a `no_commands do ... end` block in a Thor class are **not** Thor commands (they're plain public Ruby helper methods) even though they sit inside the CLI class — give them full, regular YARD docs, not the abbreviated Thor treatment.
7. `RubyLLM::Tool` subclasses (e.g. `FileTool`, `SymbolTool`) already carry a `description <<~DESC ... DESC` block that documents the tool's behavior for the LLM caller. YARD comments on `#initialize`/`#execute` should describe the Ruby-level method contract (params, return value, exceptions) — do not repeat the DESC text.
8. `Data.define`/`Struct.new` model classes (`lib/thingie/models.rb`): document derived predicate methods (e.g. `#github?`, `#local?`) with `@return [Boolean]`; a struct with no custom methods just needs a one-line class-level comment if it lacks one already — skip it if that comment already exists.

## Verification

- `git status --short` after editing should show only the intended files changed, plus no unexpected new files besides `.yardopts` if you were also asked to add it.
- Run rubocop against the edited files to confirm the added comments don't trip any style cops (see the thingie-ruby-bundle-env-fix skill first if `bundle exec rubocop` fails with gem-resolution errors — this repo's bundle env is commonly broken by an unrelated devbox).
- `bundle exec rspec spec/thingie/yard_coverage_spec.rb` (if present) should stay green — this repo has had a dedicated YARD-coverage spec that fails if a public method loses its doc comment.

## Failure signatures

| Symptom | Cause | Fix |
|---|---|---|
| `ls: .yardopts: No such file or directory` | `.yardopts` not yet created for this branch/task | Check `Rakefile` for a `yard` task and the gemspec for a yard dev dependency instead of assuming the file exists; create `.yardopts` with `--markup markdown --markup-provider kramdown` if the task calls for it. |
