.PHONY: test smoke format-check

test:
	nvim --headless -u tests/minimal_init.lua -l tests/protocol_spec.lua
	nvim --headless -u tests/minimal_init.lua -l tests/config_spec.lua
	nvim --headless -u tests/minimal_init.lua -l tests/context_spec.lua
	nvim --headless -u tests/minimal_init.lua -l tests/dialog_spec.lua
	nvim --headless -u tests/minimal_init.lua -l tests/init_spec.lua
	nvim --headless -u tests/minimal_init.lua -l tests/ui_spec.lua
	nvim --headless -u tests/minimal_init.lua -l tests/commands_spec.lua
	nvim --headless -u tests/minimal_init.lua -l tests/render_spec.lua
	nvim --headless -u tests/minimal_init.lua -l tests/layout_spec.lua
	nvim --headless -u tests/minimal_init.lua -l tests/rpc_ui_spec.lua

smoke:
	nvim --headless -u tests/minimal_init.lua -l tests/client_smoke.lua

format-check:
	stylua --check lua plugin tests
