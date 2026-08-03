# Current Security Risks

This document tracks unresolved security risks in pi.nvim. Historical issues
PI-001 through PI-007 were resolved and have been removed from this file so that
it represents the current risk register rather than a remediation archive.

## Review Scope

Review environment:

- Neovim 0.12.4
- Pi Coding Agent 0.83.0
- Static review of the Lua client, RPC protocol, UI, configuration, and bundled
  permission extension
- Behavioral comparison with the installed Pi RPC, extension, security, and
  session documentation
- `make test`: passing (10 test files)

Pi and its extensions run with the permissions of the user that started
Neovim. The security modes in pi.nvim are guardrails, not an operating-system
sandbox. The findings below evaluate whether those guardrails match their
names, documentation, and likely user expectations.

## Risk Summary

| ID | Severity | Area | Status | Summary |
| --- | --- | --- | --- | --- |
| SEC-001 | High | Command permissions | Open | The default confirmation gate is bypassable and does not confirm file mutations |
| SEC-002 | High | Read-only mode | Open | Read-only tools can access files outside the project root |
| SEC-003 | Medium | Session resume | Open | Cross-project resume leaves the UI bound to the old project root |
| SEC-004 | Medium | Resource limits | Open | Direct Bash streaming can consume unbounded Neovim memory |
| SEC-005 | Low | CI supply chain | Open | GitHub Actions are referenced by mutable version tags |

## SEC-001: Default Confirmation Gate Is Bypassable

**Severity:** High

**Status:** Open

**Implementation:** `extensions/permission-gate.ts`, `lua/pi/config.lua`,
`lua/pi/ui/render.lua`

### Problem

The default `security.mode = "confirm"` loads a permission extension that uses
regular-expression deny-list matching. A Bash tool call is allowed without a
prompt whenever none of the patterns match.

This cannot provide a reliable command security boundary. Equivalent commands
can be expressed by reordering options, using alternate tools, invoking an
interpreter, or composing shell operations. The gate also handles only the
`bash` tool; built-in `edit` and `write` calls are not confirmed.

The welcome UI labels this mode `confirm changes`, which overstates the actual
behavior. The implementation only asks about a small set of recognizable shell
command strings.

### Reproduction

The current matcher produces the following results:

```text
BLOCK rm -rf /tmp/demo
ALLOW rm -f -r /tmp/demo
ALLOW git -C . reset --hard
ALLOW chmod --recursive 000 .
ALLOW find . -delete
ALLOW python3 -c "import shutil; shutil.rmtree('src')"
```

No model, authentication, or command execution is required to reproduce the
matcher bypass.

### Impact

A prompt injection in repository content, context files, command output, or
model output can produce a destructive command variant that runs without the
confirmation implied by the selected mode. The command runs with the same
filesystem, process, environment, credential, and network access as the Pi
process.

The default configuration increases the relevance of this path because
`load_context_files = true` loads `AGENTS.md` and `CLAUDE.md` even when
`project_trust = "never"` prevents protected project resources from loading.

### Required Remediation

- Make `confirm` fail closed for every model-initiated built-in `bash`, `edit`,
  and `write` call.
- Block calls when confirmation UI is unavailable.
- Do not treat an expanded regular-expression deny list as a complete fix;
  arbitrary shell interpreters cannot be classified safely this way.
- Rename the current behavior if it is retained, for example to
  `warn-common-shell`, and replace `confirm changes` with an exact description.
- Recommend an OS-level sandbox for untrusted or unattended work.

### Required Verification

Add automated extension tests that cover:

- reordered short and long options;
- Git global options such as `git -C`;
- alternate destructive tools and interpreters;
- `edit` and `write` confirmation;
- cancellation, timeout, and unavailable-UI behavior.

## SEC-002: Read-Only Mode Is Not Workspace-Confined

**Severity:** High

**Status:** Open

**Implementation:** `lua/pi/config.lua`, `README.md`

### Problem

Read-only mode is implemented by passing:

```text
--tools read,grep,find,ls
```

This removes built-in mutation and Bash tools, but it does not constrain paths
to the project root. In Pi 0.83 these tools resolve absolute paths, `..`
segments, and home-directory paths without a project-boundary check.

Consequently, read-only mode means "no built-in writes or shell execution"; it
does not mean "only read this workspace." The README currently recommends
read-only mode as one option for untrusted repositories without making this
confidentiality limitation prominent.

### Impact

Malicious repository instructions can induce the model to read files such as:

```text
~/.ssh/id_ed25519
~/.aws/credentials
~/.config/*
../other-project/.env
```

Any successfully read content becomes model context and can be sent to the
configured provider. This creates a confidentiality risk outside the workspace
even though project writes and Bash are disabled.

### Required Remediation

- Introduce a workspace-confined read-only profile using tool overrides.
- Canonicalize both the project root and requested path with `realpath`.
- Reject paths outside the canonical root, including symlinks that resolve
  outside it.
- Disable project context files in the untrusted-project profile.
- Consider filtering inherited environment variables and credentials.
- Document the existing read-only mode as host-wide read access until the path
  boundary is implemented.

### Required Verification

Add tests for:

- absolute paths outside the root;
- `../` traversal;
- symlinks from the workspace to outside files and directories;
- root-prefix siblings such as `/work/project-other`;
- valid files and symlinks that remain inside the root;
- context-file behavior in the untrusted-project profile.

## SEC-003: Cross-Project Resume Keeps a Stale Client Root

**Severity:** Medium

**Status:** Open

**Implementation:** `lua/pi/init.lua`, `lua/pi/client.lua`, `lua/pi/ui/chat.lua`

### Problem

`/resume` accepts an arbitrary session JSONL path and sends it to Pi through the
`switch_session` RPC command. Pi 0.83 reads the session header and rebuilds its
runtime using the session's stored working directory.

The pi.nvim client keeps the original `client.root`, and the chat instance is
still keyed by that old root. Session reload refreshes messages and state but
does not update the client root, chat root, welcome card, buffer tracking, or
automatic buffer refresh scope.

### Impact

After resuming a session from another project, the interface can show project A
while tools execute in project B. Editor context may then be wrapped relative
to project A while model tools operate relative to project B. This can cause
commands or file changes in a directory different from the one the user thinks
is active.

A manually supplied or untrusted session file can also choose any existing
working directory in its session header.

### Required Remediation

Choose and enforce one of these policies:

- reject sessions whose canonical working directory differs from the active
  client root;
- require an explicit cross-project confirmation and then stop/recreate the
  client under the resumed root; or
- fully re-key the existing client and chat while updating every root-dependent
  UI and buffer operation.

The active canonical runtime directory must be visible after a successful
resume.

### Required Verification

Add an RPC integration test with two temporary project roots and session files.
Verify that either cross-project resume is rejected or all client/UI/tool state
moves consistently to the second root.

## SEC-004: Bash Stream Output Is Unbounded

**Severity:** Medium

**Status:** Open

**Implementation:** `lua/pi/ui/chat.lua`, `lua/pi/protocol.lua`, `lua/pi/init.lua`

### Problem

Direct RPC Bash output is appended using repeated immutable string
concatenation:

```lua
item.bash_output = (item.bash_output or "") .. (delta or "")
```

There is no cumulative byte or line limit. The protocol's 10MB frame limit
constrains each JSON frame only; it does not constrain the total of many
`bash_execution_update` events.

Repeated concatenation also copies the accumulated string for each update,
which can approach quadratic time and allocation behavior for a long stream.

### Impact

A command with accidental or intentional high-volume output, such as `!yes`,
can freeze Neovim or cause it to be terminated for excessive memory use. The
final Pi response may be truncated, but pi.nvim has already retained the full
stream in memory.

### Required Remediation

- Keep a bounded tail buffer, using limits such as 2,000 lines or 50KB.
- Track omitted byte and line counts separately.
- Use Pi's final `fullOutputPath` metadata to reference complete output.
- Avoid rebuilding and re-rendering the complete transcript for every stream
  update.
- Apply an aggregate event/transcript budget in addition to the per-frame RPC
  limit.

### Required Verification

Add tests that stream output beyond both limits and verify bounded memory state,
a truncation notice, retained tail output, and preservation of
`fullOutputPath`.

## SEC-005: CI Actions Use Mutable Tags

**Severity:** Low

**Status:** Open

**Implementation:** `.github/workflows/ci.yml`

### Problem

The workflow references GitHub Actions by mutable major-version tags:

```yaml
actions/checkout@v7
thinca/action-setup-vim@v3
JohnnyMorganz/stylua-action@v5
```

A moved or compromised upstream tag changes the code executed in CI without a
change in this repository.

### Impact

The workflow currently grants only `contents: read`, which reduces impact, but
a compromised action can still access the checked-out source, job environment,
and read-scoped GitHub token. Future workflow permissions or secrets could
increase the impact without revisiting these references.

### Required Remediation

Pin every action to a reviewed full commit SHA and use an automated dependency
update process to propose SHA updates.

### Required Verification

Add a policy check that rejects `uses:` entries not pinned to a 40-character
commit SHA.

## Current Verification Status

The deterministic functional suite currently passes:

```sh
make test
```

The suite does not yet test the five risks above. Security remediation should
add focused tests before any item is marked resolved. Once fixed, move the
resolution details to release notes or commit history rather than leaving
resolved items in this current-risk document.
