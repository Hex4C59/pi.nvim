.PHONY: test

test:
	nvim --headless -u tests/minimal_init.lua -l tests/protocol_spec.lua
	nvim --headless -u tests/minimal_init.lua -l tests/config_spec.lua
	nvim --headless -u tests/minimal_init.lua -l tests/ui_spec.lua
	nvim --headless -u tests/minimal_init.lua -l tests/commands_spec.lua
	nvim --headless -u tests/minimal_init.lua -l tests/render_spec.lua
	nvim --headless -u tests/minimal_init.lua -l tests/layout_spec.lua
	nvim --headless -u tests/minimal_init.lua -l tests/rpc_ui_spec.lua
