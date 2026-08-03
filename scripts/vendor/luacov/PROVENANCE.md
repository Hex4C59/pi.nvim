# Vendored LuaCov Subset

- Upstream: <https://github.com/lunarmodules/luacov>
- Version: `0.17.0`
- Commit: `b1f9eae400da976b93edb7f94cf5d05f538a0655`
- License: MIT, preserved in `LICENSE`

The files below are copied byte-for-byte from the upstream `v0.17.0` tag. This
56,986-byte source subset is the collector, stats reader, line scanner, and
reporter base selected by the Task 19 evaluation. The HTML reporter, command
line wrapper, periodic tick module, CLuaCov, LuaFileSystem, and `datafile` are
not used by pi.nvim's text-only coverage workflow.

The coverage command validates these hashes before collecting data:

```text
70e16311956ccee45fa61973c5a00cd049d7a770ae07b16bbe49e17e6c99ee3d  LICENSE
11243da09d66230c236dab427f45871893086e56c5e83b5734d7a825055d4d00  luacov.lua
7bc137242f370141f827c74749e06c141747a91f5d1b8a790aaafae185836142  luacov/defaults.lua
b740112f32792a09a98b0c6a7f22db1ff401fc9abef3f76b8b0adcc658af2a5e  luacov/hook.lua
acb3ab4f4b073a810f58491259df5c38799a0e2c8fc4a0f121c6323ba2115959  luacov/linescanner.lua
08be9aa58cac1cfd624accbcdc35488b2423f513fafe06662a55eb9cde879400  luacov/reporter.lua
bc8bc4714cd774fb5c748a0697ba828b3a8a895227c012751be22c46c718442c  luacov/runner.lua
238536d46a20d42b0a1fabd1f347c1d6903cfc4ffa9d668fc33fcd97f87ea122  luacov/stats.lua
fbae18bc623c5275f6bf675183754c42a360fc190de5bf8d42892b1d266cfbef  luacov/util.lua
```
