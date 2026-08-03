# Task 02: Implement the Focused Test Entry

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`
>
> Depends on: Task 01
>
> Blocks: Tasks 03 and 04

## 1. Goal

Add the public command below so a developer can run exactly one supported test
file without remembering the underlying Neovim or Node invocation:

```bash
make test-file TEST=tests/lua/ui/render_spec.lua
```

The same target must route Extension tests to Node. Existing full-suite targets
must retain their current behavior and must never read `TEST`.

## 2. Scope

This task changes only `Makefile`.

It must not:

- modify test files;
- modify README or CI;
- infer tests from Git changes;
- accept multiple files, directories, or globs;
- add caching, parallel execution, or watch mode;
- call a model or start the installed Pi process; or
- change `test`, `test-lua`, `test-extensions`, `smoke`, or `format-check`.

Automated contract coverage is added in Task 03. This task still performs the
manual sanity checks listed below before handoff.

## 3. Public Contract

The command form is:

```text
make test-file TEST=<repository-relative-test-file>
```

Supported selections are:

| Selection | Runner command |
| --- | --- |
| `tests/lua/**/*_spec.lua` | `nvim --headless -u tests/minimal_init.lua -l "$TEST"` |
| `tests/extensions/*.test.mjs` | `node --test "$TEST"` |

The target accepts exactly one existing regular file. It rejects:

- missing or empty `TEST`;
- absolute paths;
- paths containing `..` components;
- paths outside the two supported roots;
- directories;
- nonexistent paths;
- Lua files without the `_spec.lua` suffix;
- Extension files without the `.test.mjs` suffix;
- whitespace-separated lists;
- shell glob syntax; and
- characters outside the repository's normal test-path character set.

Restricting accepted paths to ASCII letters, digits, slash, dot, underscore,
and hyphen is sufficient for the current repository and makes the one-file
contract unambiguous.

## 4. Ownership and Safety Constraints

This command is developer tooling, not a security sandbox. It must still treat
the selected path as data rather than executable shell syntax.

Required constraints:

- Do not evaluate a path through `eval`, `sh -c`, command substitution, or an
  unquoted shell expansion.
- Do not construct the runner command as one string and execute the string.
- Pass the validated path as one quoted argument to `-l` or `node --test`.
- Validate before invoking either runner.
- Print a concise error and usage form to stderr on invalid input.
- Return non-zero on validation or runner failure.
- Return the runner's exit status without falling back to the other runner.

Because Make expands its own variables before the shell runs, avoid inserting
an untrusted `$(TEST)` value directly into executable shell syntax. Keep the
recipe fixed, export the selected value to the recipe environment, and read it
through a quoted shell variable. Task 03 must verify the final transport method
with metacharacter cases.

## 5. Step-by-Step Edit

### 5.1 Extend the phony target list

File: `Makefile`, current line 1.

Add `test-file` to `.PHONY`. Do not rename or reorder existing public targets in
a way that creates unrelated diff churn.

Behavioral effect: invoking `make test-file` always executes validation and the
selected runner; it can never be skipped because a filesystem entry happens to
be named `test-file`.

### 5.2 Add the focused target

File: `Makefile`, insert after the complete `test-lua` recipe and before
`test-extensions`.

The recipe must perform validation in this order:

1. Verify `TEST` is present and non-empty.
2. Verify the value contains only the allowed path characters.
3. Reject an absolute path.
4. Reject `..` as a complete path component.
5. Verify the path exists and is a regular file.
6. Match the Lua root and `_spec.lua` suffix; if matched, select Neovim.
7. Otherwise match the Extension root and `.test.mjs` suffix; if matched,
   select Node.
8. Reject every other path with the accepted command form.
9. Print `nvim: <path>` or `node: <path>`.
10. Replace the recipe shell with the selected runner, or otherwise preserve its
    exact exit status.

Use POSIX shell constructs already compatible with the current Makefile. Do not
add Bash-only arrays or regular-expression syntax.

### 5.3 Preserve full-suite semantics

File: `Makefile`, existing `test`, `test-lua`, and `test-extensions` targets.

Confirm these targets do not reference `TEST` and do not depend on `test-file`.
Task 03 will add a separate contract-test target to `make test`; it will not make
the full suite execute a developer-selected file.

Behavioral effect: even when the caller has exported a `TEST` environment
variable, `make test` still discovers and runs every test.

## 6. Required Error Behavior

Errors should be short and actionable. Each invalid selection must include:

- the rejected reason;
- the accepted form `make test-file TEST=<path>`; and
- a non-zero status.

Do not dump the environment, Make database, or unrelated filesystem paths.

Expected error categories:

| Case | Required reason |
| --- | --- |
| Missing value | `TEST is required` |
| Absolute or parent traversal | repository-relative path required |
| Missing/non-file path | test file does not exist or is not regular |
| Unsupported root or suffix | unsupported test path |
| More than one selection | exactly one test file is accepted |
| Disallowed characters | invalid characters in test path |

Exact punctuation is not important, but Task 03 should assert stable reason
fragments so future refactors remain free to improve wording.

## 7. Manual Sanity Checks

Run one real test from each supported runner:

```bash
make test-file TEST=tests/lua/protocol_spec.lua
make test-file TEST=tests/extensions/todo-list.test.mjs
```

Run a nested Lua spec:

```bash
make test-file TEST=tests/lua/integration/image_rpc_spec.lua
```

Confirm invalid input fails before runner startup:

```bash
make test-file
make test-file TEST=lua/pi/client.lua
make test-file TEST=tests/lua
make test-file TEST=/tmp/example_spec.lua
make test-file TEST=tests/lua/missing_spec.lua
```

Finally run:

```bash
make test
```

Successful behavior:

- each valid command prints one runner prefix and executes only the requested
  file;
- every invalid command returns non-zero with a concise reason;
- the complete deterministic suite still discovers all test files.

## 8. Risks

- Make-variable expansion and shell expansion are separate layers. Quoting only
  at one layer may be insufficient; Task 03 must cover the public command.
- Prefix-only validation can accidentally accept parent traversal or a symlink
  with surprising ownership. The path contract deliberately rejects `..` and
  accepts only existing files under known roots.
- A broad `tests/lua/*.lua` pattern would accidentally accept
  `tests/minimal_init.lua`; require the `_spec.lua` suffix.
- A broad Extension pattern could accept the smoke runner; require the
  `tests/extensions/*.test.mjs` form.
- Do not make `test-lua` conditional on `TEST`; that would permit accidental CI
  narrowing.

## 9. Completion Checklist

- [ ] `test-file` is phony.
- [ ] Exactly one supported test file is required.
- [ ] Lua tests use the existing minimal-init Neovim command.
- [ ] Extension tests use Node's existing test runner.
- [ ] Paths are validated before runner startup.
- [ ] The path is passed as one quoted runner argument.
- [ ] Runner exit status is preserved.
- [ ] Existing full-suite targets ignore `TEST`.
- [ ] Manual valid and invalid checks pass.
- [ ] `make test` still passes or matches the Task 01 baseline.
- [ ] No README, CI, runtime, or test file was changed.

## 10. Handoff to Task 03

Record the chosen validation method and any platform assumptions. Task 03 must
turn every public contract branch into a deterministic automated regression and
must specifically test the boundary between Make expansion and shell execution.

