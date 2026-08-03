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
The bundled todo Extension makes the agent decompose complex implementation work
into a branch-aware plan, keep it current during execution, and render its
compact live plan inside the conversation transcript.

Pi 0.83 RPC does not expose in-place `navigate_tree` or a session-list command.
The tree UI therefore supports inspection and forking from user messages;
`/resume` accepts a session path instead of pretending to provide Pi's full
interactive resume picker.

## Requirements

- Neovim 0.10 or newer
- `pi` available on `PATH`
- A model configured in Pi (`pi`, then `/login` when needed)
- Optional Tree-sitter parsers for syntax highlighting in fenced-code languages
- Clipboard image capture uses `wl-paste` on Wayland or `xclip` on X11.
- Optional `snacks.nvim` with `image.enabled = true` enables true terminal
  images in Kitty, Ghostty, and compatible terminals. With ImageMagick,
  unsupported terminals such as Konsole receive an asynchronous true-color
  half-block preview; otherwise they use a compact text placeholder.

Run `:checkhealth pi` after installation.

## Installation

With lazy.nvim:

```lua
{
  "Hex4C59/pi.nvim",
  dependencies = {
    {
      "folke/snacks.nvim",
      opts = { image = { enabled = true } },
    },
  },
  config = function()
    require("pi").setup()
  end,
}
```

The `snacks.nvim` dependency is optional. Remove it when using
`images.backend = "text"` or when terminal image rendering is not needed.

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
| `:PiPermissions [mode]` | Select the session permission mode |
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
Earlier stages can therefore collapse while Pi is still working. The current
reasoning stage replaces the generic activity label on the prompt border instead
of accumulating private summaries in the transcript, while tool calls remain
visible in the execution timeline. Summaries retain elapsed time plus read,
search, command, edit, and failure counts. `Ctrl-O` or a click on any disclosure
row toggles the complete process; wide layouts also show the shortcut inline.

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

Below the prompt, a single quiet row keeps the selected model and thinking level
on the left, and shows the selected permission mode beside context usage. On narrow
layouts the permission mode takes priority over model details. Queue counts temporarily
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
| `Alt-P` | Cycle permission mode |
| `Shift-Tab` | Cycle thinking level |
| `Ctrl-O` | Toggle the tool under the cursor, or the complete process from the prompt |
| Left click | Toggle the clicked process summary or tool output |
| `Ctrl-T` | Toggle complete process details (compatibility alias) |
| `Ctrl-X` | Copy the last assistant response |
| `Ctrl-V` / `Ctrl-Shift-V` | Paste an image from the system clipboard (text paste is preserved as a fallback) |
| `/` | Open slash-command completion |
| `Tab` / `Shift-Tab`, `Up` / `Down` | Select the next or previous command |

While a permission prompt is open, Pi renders it inline at the end of the
conversation and captures its navigation keys while the chat stays read-only,
so completion, search, cursor-line, and other editor plugins cannot alter it.
Use `j`/`k` or arrows to select, `Enter` to confirm, `Esc` to block, and `Ctrl-Q`
to cancel safely and return to the Pi canvas in Neovim Normal mode.

Typing `/` opens Pi's borderless command menu containing built-ins plus commands
loaded from extensions, prompt templates, and skills. Command names are fuzzy
matched and ranked while matched characters, the active row, parameter hints,
and descriptions retain distinct semantic highlighting. Commands implemented by the RPC
frontend include `/settings`, `/model`, `/copy`, `/name`, `/session`, `/hotkeys`,
`/fork`, `/clone`, `/tree`, `/new`, `/compact`, `/resume`, `/export`, and `/quit`.
pi.nvim also provides `/thinking`, `/permissions`, `/mode`, `/layout`, `/commands`, `/abort`, and `/clear`.
The bundled `/todos [show|hide]` command controls the task plan rendered inline
at the end of the conversation. The agent's
`todo` tool creates an ordered plan atomically with `plan`, then supports `list`,
`add`, `update`, `remove`, and `clear`. For requests with at least three
meaningful steps, the Extension tells the agent to establish a 3-7 step plan
before substantive implementation, update each item immediately after
verification, and resolve the list before its final response. Pending,
in-progress, and completed state is restored from the active Pi session branch.
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
  output = {
    live_max_bytes = 64 * 1024,
    live_max_lines = 2000,
    max_chunks = 256,
    tool_max_bytes = 256 * 1024,
    transcript_max_bytes = 2 * 1024 * 1024,
    rpc_queue_max_messages = 1024,
    rpc_queue_max_bytes = 16 * 1024 * 1024,
    render_interval_ms = 50,
  },
  context = {
    max_bytes = 100000, -- complete UTF-8-safe serialized context limit
    include_diagnostics = true,
    diagnostics_max_count = 100,
    diagnostic_max_message_bytes = 1000,
    diagnostics_max_bytes = 20 * 1024,
  },
  images = {
    max_bytes = 8 * 1024 * 1024,
    max_width = 72,
    max_height = 32,
    max_pixels = 40 * 1000 * 1000,
    cache_max_age_days = 7,
    attachment_max_count = 4,
    attachment_max_bytes = 16 * 1024 * 1024,
    backend = "auto", -- "auto", "terminal", or "text"
    preview = {
      max_concurrent = 2,
      debounce_ms = 100,
      timeout_ms = 10000,
    },
    terminal = {
      provider = "snacks",
      auto_resize = true,
      timeout_ms = 10000,
    },
  },
  chat = {
    position = "right", -- "right", "bottom", "tab", or "float"
    width = 0.42,
    height = 0.38,
    max_input_height = 8,
    max_widget_height = 8,
    float = {
      width = 0.84,
      height = 0.86,
      border = "rounded",
    },
  },
  extra_args = {},
})
```

`auto` uses terminal images only after the optional provider confirms support;
`terminal` requests the same backend but reports a health warning when it must
fall back. When terminal graphics are unavailable, ImageMagick provides a
bounded colored-block preview without blocking Neovim. Preview conversion is
debounced, globally concurrency-limited, and terminated after `timeout_ms`.
`text` never loads the provider or creates colored previews. Terminal images
use one stable transcript anchor and provider-owned virtual rows, avoiding
duplicate blank space while
still pushing later messages below the image. Click an image, or place the
cursor on its anchor and press Enter, to open a larger preview. Explicit
Markdown images and ordinary Markdown links to supported
raster files in assistant responses are previewed when they resolve inside the
canonical project root. Ordinary links keep their text and place the preview
below it. URLs and paths that escape the workspace remain text and are never
fetched by the client. Repeated renders reuse stable placements, while resize, layout changes,
Buffer deletion, chat close, and Neovim exit clean up only pi.nvim-owned image
handles. Cached image bytes are content-addressed, stored with `0600`
permissions, bounded by compressed size and pixel count, and aged out according
to `cache_max_age_days`. Pending prompt images are additionally bounded by
`attachment_max_count` and their aggregate encoded `attachment_max_bytes`.

### Security modes

| Mode | Model reads | Model modifications | Model Bash | Cross-project resume |
| --- | --- | --- | --- | --- |
| `read-only` | Canonical workspace only | Disabled | Disabled | Rejected |
| `confirm` | Session permission mode | Session permission mode | Session permission mode | Rejected |
| `full` | Host-level | Host-level | Host-level | Rejected until the client can migrate safely |

### Session permission modes

With the default `security.mode = "confirm"`, the active session permission mode
can be changed without restarting Pi. Use `Alt-P`, `/permissions`, `/mode`, or
`:PiPermissions`:

| Mode | Behavior |
| --- | --- |
| `manual` | Allow canonical workspace reads; ask before Bash, file modifications, and outside-workspace reads or changes |
| `acceptEdits` | Automatically accept canonical workspace writes/edits; ask before Bash and all outside-workspace access |
| `auto` | Allow structurally valid built-in tool calls without confirmation, including Bash and outside-workspace access |
| `plan` | Expose only `read`, `grep`, `find`, `ls`, and `todo`; inject read-only planning instructions and block every other model tool |

The bundled `permission-gate.ts` Extension is the only authority for mode,
session approvals, and allow/block decisions. Neovim sends mode commands and
updates the footer only after the Extension publishes `pi.permission_mode`;
before that synchronization the footer shows `--`. Changing mode, switching
sessions, or restarting Pi clears previous session approvals and restores
`manual`. `Allow for session` uses canonical file targets, canonical outside
read targets, or the exact Bash command and workspace rather than a command
family.

`auto` suppresses permission prompts, but it does not bypass structural input
validation, canonical path resolution, or the cross-project session guard. It
grants model tools the same host access as the Neovim/Pi process for the current
session, so use it only in a trusted workspace.

Entering `plan` snapshots the exact active tool list and replaces it with the
read-only planning set. Leaving `plan` restores that snapshot. The Extension
also injects the current permission boundary into each agent turn, so the model
does not repeatedly attempt tools that the selected mode will reject. Tool-call
blocking remains in place as defense in depth.

Whenever the selected mode requires confirmation, the request fails closed if
its UI is unavailable, cancelled, throws an error, returns an unknown choice,
or the session closes. An open permission panel has no implicit timeout: the
current tool batch remains stopped until the user allows, blocks, or cancels
the request. The policy covers Pi's built-in `bash`, `edit`, `write`, `read`,
`grep`, `find`, and `ls` tools. Lua does not parse dialog text or shell strings
to make security decisions.
Outside Plan mode, additional tools supplied by other Extensions are trusted
code and need their own policy. Plan blocks them unless they are the bundled
`todo` tool. A `!command` typed directly by the user is not a model-initiated
tool call and does not prompt.

`read-only` canonicalizes the workspace and requested paths, follows symlinks,
and blocks `read`, `grep`, `find`, and `ls` when their resolved target is outside
the workspace. It exposes those tools plus `todo` and injects the same read-only
planning guidance. `full` deliberately opts out of tool permission guards. All
bundled guards run with the same user permissions as Neovim and Pi; they are not
an operating-system sandbox. Use a container, VM, or equivalent OS isolation for
untrusted or unattended work.

Project trust controls loading protected project `.pi` resources, not tool
permissions. Context files such as `AGENTS.md` and `CLAUDE.md` are controlled
separately by `load_context_files`. A conservative profile for an untrusted
repository is:

```lua
require("pi").setup({
  project_trust = "never",
  load_context_files = false,
  security = {
    mode = "read-only",
  },
})
```

`/resume` reads a bounded session header and accepts only sessions whose
canonical `cwd` equals the active client root. Cross-project resume is rejected
in every security mode because Pi RPC 0.83 does not return enough authoritative
state to migrate the Neovim client safely.

Live Bash output retains at most the configured tail, then shows the client-side
omitted byte/line counts and Pi's `fullOutputPath` when available. Tool arguments
and results share a per-tool limit. `transcript_max_bytes` covers user,
assistant, thinking, status, and tool bodies plus retained Lua render
projections. When that budget is exceeded, the oldest local bodies are released
while lightweight identity, status, and timing remain visible; Pi's
authoritative session is unchanged. The decoded RPC dispatch queue is also
bounded by message count and bytes; exceeding either limit stops the Pi process
instead of continuing with partial client state.
`context.max_bytes` bounds the complete serialized editor context, including
wrapper metadata, selection truncation markers, and diagnostics; `max_chars`
remains a compatibility alias. Diagnostics have additional count, per-message,
and section-byte limits. When limited, errors are preferred before warnings,
information, and hints, with deterministic range ordering and explicit omission
counts in the serialized diagnostic metadata.
`:PiStop` and shutdown release the Client, Chat transcript, render caches, and
owned scratch buffers for the stopped project.

## Development

The test suite does not call a model or require authentication. It includes a
deterministic fake RPC process that exercises history, streaming messages,
thinking, tool execution, queue updates, and agent settlement end to end:

```bash
make test
```

For fast feedback while working on one known test owner, run exactly one Lua or
bundled Extension test file:

```bash
make test-file TEST=tests/lua/ui/render_spec.lua
make test-file TEST=tests/extensions/permission-gate.test.mjs
```

`test-file` accepts one existing repository-relative test path. It does not infer
affected tests from Git changes, so `make test` remains the complete
deterministic gate before finishing a change.

The RPC parser deliberately buffers arbitrary stdout chunks and splits only on
LF. It does not use generic line readers because U+2028 and U+2029 are valid
inside JSON strings.
