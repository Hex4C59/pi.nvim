# pi.nvim

A native Neovim client for [Pi Coding Agent](https://pi.dev). The plugin runs
`pi --mode rpc` per project and presents the streamed conversation inside a
Neovim buffer. Pi continues to own model authentication, tools, sessions,
extensions, skills, and compaction.

## Status

The plugin provides a Pi-inspired Neovim frontend over RPC. It implements the
streamed transcript, user message blocks, collapsible thinking and tool output,
persistent prompt editor, command completion, model/thinking controls, queue
state, live footer, settings, session tree inspection, fork/clone, compaction,
and extension confirmation dialogs.

Pi 0.83 RPC does not expose in-place `navigate_tree` or a session-list command.
The tree UI therefore supports inspection and forking from user messages;
`/resume` accepts a session path instead of pretending to provide Pi's full
interactive resume picker.

## Requirements

- Neovim 0.10 or newer
- `pi` available on `PATH`
- A model configured in Pi (`pi`, then `/login` when needed)
- Optional Tree-sitter parsers for syntax highlighting in fenced-code languages

Run `:checkhealth pi` after installation.

## Installation

With lazy.nvim:

```lua
{
  "Hex4C59/pi.nvim",
  config = function()
    require("pi").setup()
  end,
}
```

## Commands

| Command | Purpose |
| --- | --- |
| `:PiChat` | Open the project chat buffer |
| `:PiAsk [prompt]` | Send a prompt |
| `:[range]PiVisual [prompt]` | Include a line range in the prompt |
| `:PiBuffer [prompt]` | Include the current in-memory buffer |
| `:PiAbort` | Abort the current operation |
| `:PiModel` | Select a configured model |
| `:PiThinking` | Select a supported thinking level |
| `:PiSettings` | Open the Pi settings selector |
| `:PiLayout [layout]` | Switch between tab, float, right, and bottom workspaces |
| `:PiTree` | Inspect the current session tree |
| `:PiFork` | Fork from a previous user message |
| `:PiClone` | Clone the active session branch |
| `:PiCommands` | Browse extension, prompt, and skill commands |
| `:PiNew` | Start a new session |
| `:PiCompact [instructions]` | Compact the current session |
| `:PiStatus` | Show session usage and cost |
| `:PiStop` | Stop the current project's Pi process |

The chat uses one normal Neovim window as a canvas. The editable prompt and
footer are window-relative overlays, so they stay anchored without creating
nested splits or extra statuslines. Transcript rendering is component-based:
user messages, assistant Markdown, thinking, and tool executions own their
padding, semantic highlights, and responsive layout. Every transcript begins
with a full-width Pi welcome card showing the model, thinking level, project,
and security mode. Its segmented Pi mark rotates through colors derived from
the active colorscheme, while each field keeps a stable semantic color. It
remains in scrollback as the conversation grows. Assistant answers stay on the
plain canvas. Each completed work stage renders its public update first,
followed by a quiet disclosure row such as `Thought for 4s, read 6 files`.
Earlier stages can therefore collapse while Pi is still working, while only the
current stage keeps its thinking and tool calls visible in the execution
timeline. Summaries retain elapsed time plus read, search, command, edit, and
failure counts. `Ctrl-O` or a click on any disclosure row toggles the complete
process; wide layouts also show the shortcut inline.

Assistant Markdown is reduced to terminal-native presentation: headings,
emphasis, inline code, links, lists, quotes, and fenced code keep their semantic
styling without leaking Markdown delimiters or absolute link targets. Fenced
code uses Neovim's installed Tree-sitter parser for its declared language and
falls back to the normal code style when that parser is unavailable. In the
detailed process view, consecutive tool calls form a single `Actions` timeline.
Each output remains visually attached to its command, while edits and writes
show responsive change counts plus collapsed `+`/`-` code previews. A tool under
the cursor can still be expanded independently with `Ctrl-O` or a mouse click.
Expanded file reads use the installed Tree-sitter parser selected from the file
path, with the same graceful fallback as fenced code.

The default layout is a focused right sidebar. `:PiLayout` changes the active
project workspace at runtime without restarting Pi or discarding its
transcript; bottom, dedicated-tab, and centered-float layouts remain available.
The sidebar uses a darker semantic canvas with distinct colors for users,
assistant output, thought timelines, tools, diffs, usage, model, and thinking
level. During active work, mirrored cyan highlights travel along the prompt
frame while the elapsed activity label stays centered in its bottom border.
The frame returns to a uniform cyan outline as soon as Pi becomes idle.

Below the prompt, a single quiet row keeps only the selected model and thinking
level on the left and context usage on the right. Queue counts temporarily
replace context usage when steering or follow-up prompts are waiting. Detailed
token, cache, cost, and compaction information remains available through
`:PiStatus`, `/session`, and `/settings` instead of competing for permanent
screen space. The prompt reserves one row of vertical padding above and below
its text and grows with multiline input up to `chat.max_input_height`.

The prompt editor focuses automatically and mirrors Pi's primary controls:

| Key | Action |
| --- | --- |
| `Enter` | Accept a selected slash command, otherwise submit or steer |
| `Ctrl-J` | Insert a newline |
| `Alt-Enter` | Queue a follow-up |
| `Esc` / `Ctrl-C` | Interrupt active work |
| `Ctrl-L` | Select a model |
| `Ctrl-P` | Cycle models |
| `Shift-Tab` | Cycle thinking level |
| `Ctrl-O` | Toggle the tool under the cursor, or the complete process from the prompt |
| Left click | Toggle the clicked process summary or tool output |
| `Ctrl-T` | Toggle complete process details (compatibility alias) |
| `Ctrl-X` | Copy the last assistant response |
| `/` | Open slash-command completion |
| `Tab` / `Shift-Tab`, `Up` / `Down` | Select the next or previous command |

Typing `/` opens Pi's borderless command menu containing built-ins plus commands
loaded from extensions, prompt templates, and skills. Command names are fuzzy
matched and ranked while matched characters, the active row, parameter hints,
and descriptions retain distinct semantic highlighting. Commands implemented by the RPC
frontend include `/settings`, `/model`, `/copy`, `/name`, `/session`, `/hotkeys`,
`/fork`, `/clone`, `/tree`, `/new`, `/compact`, `/resume`, `/export`, and `/quit`.
pi.nvim also provides `/thinking`, `/layout`, `/commands`, `/abort`, and `/clear`.
Both `/new` and `/clear` start a fresh Pi session, so `/clear` resets the model
conversation and context usage instead of only hiding the rendered transcript.
Pi TUI commands that RPC 0.83 does not expose remain searchable and report the
limitation instead of being sent to the model. Input beginning
with `!` runs through Pi's RPC bash command. Unknown slash commands pass through
to Pi so extension, prompt-template, and skill commands continue to work.

Example visual-mode mapping:

```lua
vim.keymap.set("v", "<leader>pa", ":PiVisual ", { desc = "Ask Pi about selection" })
vim.keymap.set("n", "<leader>pp", "<cmd>PiChat<cr>", { desc = "Open Pi" })
```

## Configuration

```lua
require("pi").setup({
  command = "pi",
  root_markers = { ".git", ".pi" },
  persist_session = true,
  project_trust = "never", -- "never", "always", or nil for Pi's default
  load_context_files = true,
  security = {
    mode = "confirm", -- "read-only", "confirm", or "full"
  },
  context = {
    max_bytes = 100000, -- UTF-8-safe byte limit; max_chars remains a compatibility alias
    include_diagnostics = true,
  },
  chat = {
    position = "right", -- "right", "bottom", "tab", or "float"
    width = 0.42,
    height = 0.38,
    max_input_height = 8,
    float = {
      width = 0.84,
      height = 0.86,
      border = "rounded",
    },
  },
  extra_args = {},
})
```

`confirm` loads the bundled Pi extension and asks before common destructive
shell commands. It is a guardrail, not a sandbox. Pi still runs with the same
filesystem and process permissions as Neovim. Use `read-only` or an external
container/VM for untrusted repositories.

Project trust controls loading `.pi` resources, not tool permissions.
`AGENTS.md` and `CLAUDE.md` are still loaded unless `load_context_files` is
false.

## Development

The test suite does not call a model or require authentication. It includes a
deterministic fake RPC process that exercises history, streaming messages,
thinking, tool execution, queue updates, and agent settlement end to end:

```bash
make test
```

The RPC parser deliberately buffers arbitrary stdout chunks and splits only on
LF. It does not use generic line readers because U+2028 and U+2029 are valid
inside JSON strings.
