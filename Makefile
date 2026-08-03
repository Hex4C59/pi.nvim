.PHONY: test test-lua test-extensions test-ci-policy smoke format-check ci-policy-check

test: test-lua test-extensions test-ci-policy

test-lua:
	@set -eu; \
	find tests/lua -type f -name '*_spec.lua' -print | LC_ALL=C sort | \
	while IFS= read -r test_file; do \
		printf '%s\n' "nvim: $$test_file"; \
		nvim --headless -u tests/minimal_init.lua -l "$$test_file"; \
	done

test-extensions:
	node --test tests/extensions/*.test.mjs

test-ci-policy:
	@set -eu; \
	find tests/policy -type f -name '*_test.sh' -print | LC_ALL=C sort | \
	while IFS= read -r test_file; do \
		printf '%s\n' "sh: $$test_file"; \
		sh "$$test_file"; \
	done

smoke:
	nvim --headless -u tests/minimal_init.lua -l tests/smoke/client_smoke.lua
	node tests/smoke/extensions_smoke.mjs

format-check:
	stylua --check lua plugin tests

ci-policy-check:
	sh scripts/check-actions-pinned.sh
