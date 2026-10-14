.PHONY: check test integration-test e2e-test build

check build:
	nim check src/mcport.nim

test:
	@set -e; for test in $(sort $(wildcard tests/test_*.nim)); do nim r "$$test"; done

integration-test:
	nim r tests/test_push_transports.nim

e2e-test: integration-test
