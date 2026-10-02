# Thingie Architecture

This document maps the design of [Gito](https://github.com/Nayjest/Gito) to Ruby and records the decisions made for `thingie`.

## Goals

- Review only files changed in a PR, but use the whole application for context.
- Provide strong Ruby and Rails opinions out of the box.
- Allow teams to layer their own rules and standards via skills and config files.
- Support any OpenAI-compatible LLM through [ruby_llm](https://github.com/crmne/ruby_llm).
- Consume MCP servers to extend review tools.
- Post precise comments on changed lines in GitHub PRs and collapse stale comments.

## Command surface

| Gito command | Thingie command | Purpose |
|---|---|---|
| `gito review` | `thingie review` | Run code review on a changeset |
| `gito report` / `gito render` | `thingie report` | Render a saved JSON review report |
| `gito files` | `thingie files` | Preview files that would be reviewed |
| `gito github-comment` | `thingie github-comment` | Post review to a GitHub PR |
| `gito setup` | `thingie setup` | Interactive local configuration |
| `gito ask` / `gito answer` | (future) | Chat with the codebase |

## High-level flow

```
review command
      |
      v
 discover target .............. git refs / GitHub PR / CLI args
      |
      v
 load configuration .......... bundled defaults + .thingie/config.toml + env
      |
      v
 discover skill fragments ...... .agents / .claude / .cursor directories
      |
      v
 build changeset .............. rugged diff between refs, merge-base, filters
      |
      v
 first pass, one of:
   [review] source = "llm" (default), for each changed file:
      assemble context ........... diff + whole file snapshot
      prompt LLM ................. ruby_llm with system prompt + JSON schema
                                   (model may call LSP tools for extra context)
      parse JSON issues .......... validate against Issue schema
   [review] source = "claude_code", once for the whole changeset:
      run `claude -p <skill>` .... ClaudeCodeSource; headless, read-only tools,
                                   --json-schema (Issue schema + file), budget cap
      parse structured output .... same IssueParser, grouped per file
      |
      v
 post-process .................. default filter: confidence == 1, severity <= 3
      |
      v
 build Report object ........... summary + issues + target metadata
      |
      v
 render to JSON / Markdown
      |
      v
 (CI only) github-comment ....... post line-level comments + summary
```

## Core data model

### `ReviewTarget`

Metadata about what is being reviewed.

```ruby
ReviewTarget = Data.define(
  :platform,
  :repo_url,
  :pr_number,
  :commit_sha,
  :branch,
  :base_ref,
  :head_ref,
  :merge_base
)
```

### `RawIssue`

What the LLM returns for one finding.

```ruby
RawIssue = Data.define(
  :title,
  :details,
  :severity,
  :confidence,
  :tags,
  :affected_lines
)
```

`affected_lines` is an array of:

```ruby
AffectedRange = Data.define(
  :start_line,
  :end_line,
  :proposal
)
```

### `Issue`

Internal normalized issue with enriched line info.

```ruby
Issue = Data.define(
  :id,
  :file,
  :title,
  :details,
  :severity,
  :confidence,
  :tags,
  :affected_lines
)
```

`affected_lines` becomes enriched with `affected_code` and `syntax_hint`.

### `Report`

```ruby
Report = Data.define(
  :target,
  :summary,
  :issues,
  :number_of_processed_files,
  :total_issues,
  :processing_warnings,
  :created_at,
  :model
)
```

## Configuration layers

1. **Bundled defaults** in `lib/thingie/config/default.toml`
2. **Project overrides** in `<repo>/.thingie/config.toml`
3. **Environment variables** for secrets and machine-specific settings
4. **Skill fragments** from `.agents`, `.claude`, `.cursor`

Project config merges on top of bundled defaults. `prompt_vars` sections are deep-merged; other keys replace.

## LLM integration

Use `ruby_llm` with a custom OpenAI-compatible base URL when needed:

```ruby
RubyLLM.configure do |config|
  config.openai_api_key = ENV.fetch('LLM_API_KEY')
  config.openai_api_base = ENV.fetch('LLM_API_BASE', 'https://api.openai.com/v1')
end

chat = RubyLLM.chat(model: ENV.fetch('LLM_MODEL'))
response = chat.ask(prompt)
```

The review prompt instructs the model to respond only with JSON matching the `RawIssue` schema.

## Tool integration

### Language servers (LSP)

`Lsp::Client` is a generic JSON-RPC-over-stdio client configured with a launch command + workspace root, so it works with any language server. `Lsp::SymbolTool` wraps it as a `ruby_llm` tool: during review the model can look up a class/module/method by name (via `workspace/symbol`) and get its definition source for extra context. Configure servers under the `[lsp]` table (opt-in, empty by default); ruby-lsp is the first supported. Thingie does **not** run static analyzers like RuboCop itself — run those as a separate step if you want them.

### MCP servers

Thingie consumes MCP servers using the `mcp` gem. Each configured server is connected, its tools listed, and those tools are registered with the LLM through `ruby_llm` tool calling. This lets teams plug in custom code-search, test, or documentation tools.

## GitHub integration

- `octokit.rb` reads PR metadata and posts review comments.
- Each issue becomes a comment on the relevant file and line range.
- A summary comment is posted to the PR conversation.
- Previous bot comments are collapsed automatically using the GitHub issue comment update API.

## Testing strategy

- Unit tests for config merging, prompt assembly, and issue schema parsing.
- Fake-LSP-server tests for the `Lsp::Client` transport and `Lsp::SymbolTool` output.
- Integration tests for the CLI commands using Thor's test helpers.
- Mock LLM responses so CI runs without real API keys.
- Environment variables are read through `Thingie::Env`, never `ENV` directly, so specs stub a clean env via `spec_helper` instead of mutating/restoring the real process environment.
