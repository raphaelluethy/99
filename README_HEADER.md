# 99

The AI client that Neovim deserves, built by those that still enjoy to code.

A personal fork of [99](https://github.com/ThePrimeagen/99) by [ThePrimeagen](https://github.com/ThePrimeagen), developed to fit my own taste and workflow needs — with extra providers, SDK support, and other tweaks on top of the original.

## Project Direction

This repo is meant to be my exploration grounds for using AI mixed with tradcoding.

I believe that hand coding is still very important and the best products i know
of today still do that (see opencode vs claude code)

## Note

1. Prompts are temporary right now. they could be massively improved

_**DOCS**_

## Completions

When prompting, you can reference rules and files to add context to your request.

- `#` references rules — type `#` in the prompt to autocomplete rule files from your configured rule directories
- `@` references files — type `@` to fuzzy-search project files

Referenced content is automatically resolved and injected into the AI context. Requires cmp (`source = "cmp"` in your completion config).

## Providers

99 supports multiple AI CLI backends. Set `provider` in your setup to switch. If you don't set `model`, the provider's default is used.

| Provider                     | CLI tool        | Default model                |
| ---------------------------- | --------------- | ---------------------------- |
| `OpenCodeProvider` (default) | `opencode`      | `opencode/claude-sonnet-4-5` |
| `ClaudeCodeProvider`         | `claude`        | `claude-sonnet-4-5`          |
| `CursorAgentProvider`        | `agent`         | `sonnet-4.5`                 |
| `GeminiCLIProvider`          | `gemini`        | `auto`                       |
| `ClaudeSdkProvider`          | node sdk-runner | `opus`                       |
| `CursorSdkProvider`          | node sdk-runner | `composer-2.5`               |
| `OpenCodeSdkProvider`        | node sdk-runner | `opencode/claude-sonnet-4-5` |

```lua
_99.setup({
    provider = _99.Providers.ClaudeCodeProvider,
    -- model is optional, overrides the provider's default
    model = "claude-sonnet-4-5",
})
```

### SDK providers

SDK-backed providers (`ClaudeSdkProvider`, `CursorSdkProvider`, `OpenCodeSdkProvider`) talk to a bundled Node sidecar (`sdk-runner/`) instead of shelling out to a CLI. They stream normalized agent trace events (text, thinking, tool calls) with lower latency than one-shot CLI invocations.

Use them like any other provider:

```lua
_99.setup({
    provider = _99.Providers.CursorSdkProvider,
    -- model is optional; defaults to the provider's default
})
```

CLI providers return output when the subprocess finishes. SDK providers emit trace events as the agent works, which the [status window](#status-window) can display live when `agent_trace.enable` is set.

Requirements: Node.js >= 18 and npm on your PATH. On first use, 99 runs `npm install` inside `sdk-runner/` automatically. Opt out with:

```lua
_99.setup({
    sdk = { auto_install = false },
})
```

Provider API keys (set as environment variables, never logged by 99):

- `CursorSdkProvider` — `CURSOR_API_KEY`
- `ClaudeSdkProvider` — typically uses the Claude Code auth stack; `ANTHROPIC_API_KEY` may be required depending on your setup
- `OpenCodeSdkProvider` — uses OpenCode's own provider auth configuration

Run `:checkhealth 99` to diagnose node, sdk-runner install state, API keys, and CLI provider binaries.

## Status window

While requests are in flight, 99 shows a small floating window in the top-right corner. The header line pulses with the active request count; each running request adds a line with its operation name (`visual`, `search`, etc.).

With `agent_trace.enable`, the window widens and streams live trace lines per request — streamed text, tool calls, and completion status. SDK providers populate these traces; enable `agent_trace` to see them during a run.

Window width is fixed and lines are truncated to fit:

- plain status (no agent trace): one fifth of the editor width
- agent trace enabled: one third of the editor width

```lua
_99.setup({
    provider = _99.Providers.CursorSdkProvider,
    in_flight_options = {
        enable = true, -- default; set false to hide the window entirely
        agent_trace = {
            enable = true,  -- default false; set true for live SDK trace lines
            max_lines = 8,  -- trace lines kept per active request
        },
    },
})
```

Set `in_flight_options.enable = false` to disable the window. Throbber timing and poll interval are also configurable via `throbber_opts` and `in_flight_interval` (see `_99.StatusWindow.Opts` in the API reference).

## Tutorial

`_99.tutorial()` asks the provider to generate a markdown tutorial from your prompt. On success, the result opens in a split window — your buffer is not modified.

### Visual selection (optional context)

Tutorial can include your current or most recent visual selection as extra context. This is optional: if there is no selection, the tutorial runs on the prompt alone.

1. Visually select code (`v`, `V`, or `Ctrl-v`).
2. Call `_99.tutorial()` — from visual mode or after leaving it with `Esc`.

When tutorial starts:

- If you are still in visual mode, 99 sends `Esc` first so the `'<` and `'>` marks are preserved.
- If those marks are valid, 99 adds the selection's file location, contents, and surrounding context to the request (the same context block used by `visual`).
- Stale or invalid marks are ignored silently.

```lua
-- select code, then:
vim.keymap.set("n", "<leader>9t", function()
    _99.tutorial()
end)

-- or trigger from visual mode directly:
vim.keymap.set("v", "<leader>9t", function()
    _99.tutorial()
end)
```

Unlike `visual`, tutorial never replaces the selection — it only uses it as input for what to explain.

## Extensions

### Telescope Model Selector

If you have [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) installed, you can switch models on the fly via the Telescope picker:

```lua
vim.keymap.set("n", "<leader>9m", function()
  require("99.extensions.telescope").select_model()
end)
```

The selected model is used for all subsequent requests in the current session.

### Telescope Provider Selector

Switch between providers (OpenCode, Claude, Cursor, Kiro) without restarting Neovim. Switching provider also resets the model to that provider's default.

```lua
vim.keymap.set("n", "<leader>9p", function()
  require("99.extensions.telescope").select_provider()
end)
```

### fzf-lua

If you use [fzf-lua](https://github.com/ibhagwan/fzf-lua) instead of telescope, the same pickers are available:

```lua
vim.keymap.set("n", "<leader>9m", function()
  require("99.extensions.fzf_lua").select_model()
end)

vim.keymap.set("n", "<leader>9p", function()
  require("99.extensions.fzf_lua").select_provider()
end)
```

## Reporting a bug

To report a bug, please provide the full running debug logs. This may require
a bit of back and forth.

Please do not request features. We will hold a public discussion on Twitch about
features, which will be a much better jumping point then a bunch of requests that i have to close down. If you do make a feature request ill just shut it down instantly.

### The logs

To get the _last_ run's logs execute `:lua require("99").view_logs()`.

### Dont forget

If there are secrets or other information in the logs you want to be removed make
sure that you delete the `query` printing. This will likely contain information you may not want to share.
