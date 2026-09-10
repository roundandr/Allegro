SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help lint-blackwell test-blackwell

help:
	@echo "Blackwell subsystem targets (run checks on the configured RTX 5080 host):"
	@echo "  lint-blackwell  - lint the Tensor, TMA/mbarrier, and connected tops"
	@echo "  test-blackwell  - lint and run all 11 subsystem configurations"
	@echo "Arithmetic sources are read from src/main; outputs go to build/blackwell/."
	@echo "Existing arithmetic test commands remain in src/test/cocotb/README.md."

lint-blackwell:
	@bash src/test/lint_blackwell.sh

test-blackwell:
	@bash src/test/run_blackwell_tests.sh
