.PHONY: test test-lua test-file test-extensions test-ci-policy coverage coverage-clean smoke format-check ci-policy-check

# Preserve the command-line value as data. $(value ...) prevents Make from
# expanding function syntax embedded in TEST before the fixed recipe validates it.
unexport TEST
override TEST_FILE_SELECTION := $(value TEST)
export TEST_FILE_SELECTION

test: test-lua test-extensions test-ci-policy

test-lua:
	@set -eu; \
	find tests/lua -type f -name '*_spec.lua' -print | LC_ALL=C sort | \
	while IFS= read -r test_file; do \
		printf '%s\n' "nvim: $$test_file"; \
		nvim --headless -u tests/minimal_init.lua -l "$$test_file"; \
	done

test-file:
	@set -eu; \
	test_file=$${TEST_FILE_SELECTION-}; \
	usage='Usage: make test-file TEST=<path>'; \
	fail() { printf '%s\n%s\n' "test-file: $$1" "$$usage" >&2; exit 2; }; \
	case "$$test_file" in \
		'') fail 'TEST is required' ;; \
		*[[:space:]]*) fail 'exactly one test file is accepted' ;; \
		*[!A-Za-z0-9_./-]*) fail 'invalid characters in test path' ;; \
	esac; \
	case "$$test_file" in \
		/*|..|../*|*/..|*/../*) fail 'a repository-relative test path is required' ;; \
	esac; \
	[ -f "$$test_file" ] || fail 'test file does not exist or is not regular'; \
	case "$$test_file" in \
		tests/lua/*_spec.lua) \
			printf '%s\n' "nvim: $$test_file"; \
			exec nvim --headless -u tests/minimal_init.lua -l "$$test_file" \
			;; \
		tests/extensions/*.test.mjs) \
			printf '%s\n' "node: $$test_file"; \
			exec node --test "$$test_file" \
			;; \
		*) fail 'unsupported test path' ;; \
	esac

test-extensions:
	@set -eu; \
	find tests/extensions -type f -name '*.test.mjs' -print | LC_ALL=C sort | \
	while IFS= read -r test_file; do \
		printf '%s\n' "node: $$test_file"; \
		node --test "$$test_file"; \
	done

test-ci-policy:
	@set -eu; \
	find tests/policy -type f -name '*_test.sh' -print | LC_ALL=C sort | \
	while IFS= read -r test_file; do \
		printf '%s\n' "sh: $$test_file"; \
		sh "$$test_file"; \
	done

coverage:
	@sh scripts/coverage.sh validate
	@$(MAKE) test
	@sh scripts/coverage.sh collect

coverage-clean:
	@sh scripts/coverage.sh clean

smoke:
	nvim --headless -u tests/minimal_init.lua -l tests/smoke/client_smoke.lua
	node tests/smoke/extensions_smoke.mjs

format-check:
	stylua --check lua plugin tests scripts/coverage

ci-policy-check:
	sh scripts/check-actions-pinned.sh
