## Why

<!-- What user or maintenance problem does this change solve? -->

## What Changed

<!-- Summarize the behavior and its authoritative owner. -->

## Ownership And Compatibility

- [ ] New state has exactly one authoritative owner.
- [ ] RPC capability/fallback behavior is unchanged or `docs/compatibility.md` is updated.
- [ ] Public commands, configuration, Lua API, and compatibility aliases remain compatible or the breaking change is explicit.
- [ ] Security and workflow decisions remain in Pi or a bundled Extension, not Lua presentation.

## Testing

<!-- List exact commands and relevant focused tests. Explain any omitted gate. -->

- [ ] `make test`
- [ ] `make format-check` when Lua changed
- [ ] `make smoke` when installed Pi or Extension compatibility changed
- [ ] `make ci-policy-check` when GitHub Actions changed

## Documentation And Cleanup

- [ ] README describes shipped behavior only.
- [ ] Durable architecture, compatibility, and test documentation is current.
- [ ] Completed one-time task documents and temporary artifacts were removed.
