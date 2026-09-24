SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help check-layout lint-blackwell test-blackwell test-arithmetic synth-blackwell-sram synth-blackwell-tmem-bank synth-blackwell-tmem-rf synth-blackwell-f16-array dot-efficiency

help:
	@echo "Blackwell subsystem targets (run checks on the configured RTX 5080 host):"
	@echo "  lint-blackwell  - lint the Tensor, TMA/mbarrier, and connected tops"
	@echo "  check-layout    - validate filelists and repository paths locally"
	@echo "  test-blackwell  - lint and run subsystem configurations"
	@echo "  test-arithmetic - run arithmetic Cocotb from the repository root"
	@echo "  synth-blackwell-sram - check TMEM/SMEM memory structure using remote Yosys"
	@echo "  synth-blackwell-tmem-bank - check full-size TMEM owner/storage hierarchy"
	@echo "  synth-blackwell-tmem-rf - check RF executor and full-size TMEM hierarchy"
	@echo "  synth-blackwell-f16-array - check 256 real FP16/BF16 dot instances"
	@echo "  dot-efficiency - synthesize and measure one f16tf32 dot core (remote CPU)"
	@echo "RTL sources are read from rtl/; outputs go to build/blackwell/."

check-layout:
	@python3 scripts/check_repo_layout.py

lint-blackwell:
	@bash scripts/blackwell/lint_blackwell.sh

test-blackwell:
	@bash scripts/blackwell/run_blackwell_tests.sh

test-arithmetic:
	@mkdir -p build/blackwell/arithmetic/bin build/blackwell/arithmetic/$(or $(TOPLEVEL),fp4_dot_prod)
	@printf '%s\n' '#!/usr/bin/env bash' 'exec "$${PYTHON_BIN:-python3}" -m cocotb.config "$$@"' > build/blackwell/arithmetic/bin/cocotb-config
	@chmod +x build/blackwell/arithmetic/bin/cocotb-config
	@PATH="$(CURDIR)/build/blackwell/arithmetic/bin:$$PATH" $(MAKE) -C verification/cocotb MODULE=$(or $(MODULE),$(COCOTB_TEST_MODULES),test_nvfp4_dot) SIM_BUILD=$(CURDIR)/build/blackwell/arithmetic/$(or $(TOPLEVEL),fp4_dot_prod)/sim COCOTB_RESULTS_FILE=$(CURDIR)/build/blackwell/arithmetic/$(or $(TOPLEVEL),fp4_dot_prod)/results.xml
	@$(or $(PYTHON_BIN),python3) -c 'import sys, xml.etree.ElementTree as ET; root = ET.parse(sys.argv[1]).getroot(); assert root.findall(".//testcase") and not root.findall(".//failure") and not root.findall(".//error"), "empty or failing arithmetic test results"' build/blackwell/arithmetic/$(or $(TOPLEVEL),fp4_dot_prod)/results.xml

synth-blackwell-sram:
	@bash scripts/blackwell/synth_blackwell_sram.sh

synth-blackwell-tmem-bank:
	@bash scripts/blackwell/synth_blackwell_tmem_bank.sh

synth-blackwell-tmem-rf:
	@bash scripts/blackwell/synth_blackwell_tmem_rf.sh

synth-blackwell-f16-array:
	@bash scripts/blackwell/synth_blackwell_f16_array.sh

dot-efficiency:
	@python3 verification/benchmarks/dot_efficiency/run.py all
