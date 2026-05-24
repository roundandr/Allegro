SIM ?= icarus
TOPLEVEL_LANG ?= verilog
TOPLEVEL ?= fp4_dot_prod
COCOTB_TEST_MODULES ?= test_nvfp4_dot
MODULE ?= $(COCOTB_TEST_MODULES)
PYTHON_BIN = python3
COCOTB_CONFIG ?= $(PYTHON_BIN) -m cocotb_tools.config

export PATH := $(PATH):/opt/homebrew/bin:/usr/local/bin
ifneq ($(wildcard /opt/homebrew/bin/iverilog),)
ICARUS_BIN_DIR ?= /opt/homebrew/bin
else ifneq ($(wildcard /usr/local/bin/iverilog),)
ICARUS_BIN_DIR ?= /usr/local/bin
endif

export PYTHONPATH := $(PWD):$(PWD)/../../../MMA-Sim:$(PYTHONPATH)
export NUM_CASES ?= 20000
export RANDOM_SEED ?= 20260422
export COCOTB_RANDOM_SEED ?= 20260422

ifeq ($(TOPLEVEL),tcgen05_dot_adapter)
VERILOG_SOURCES ?= $(PWD)/../../main/tcgen05_mma_pkg.sv \
                   $(PWD)/../../main/pipeline_reg.sv \
                   $(PWD)/../../main/mid_fp_dot_prod.sv \
                   $(PWD)/../../main/f4f6f8_dot_prod.sv \
                   $(PWD)/../../main/int8_dot_prod.sv \
                   $(PWD)/../../main/fp4_dot_prod.sv \
                   $(PWD)/../../main/tcgen05_dot_adapter.sv
ifeq ($(SIM),verilator)
COMPILE_ARGS += -Wno-fatal
COMPILE_ARGS += -CFLAGS -isystem/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/c++/v1
endif
else
VERILOG_SOURCES ?= $(PWD)/../../main/pipeline_reg.sv $(PWD)/../../main/fp4_dot_prod.sv
endif
ifeq ($(SIM),icarus)
COMPILE_ARGS += -g2012
endif

ifeq ($(SIM),verilator)
ifeq ($(RTL_COVERAGE),1)
COMPILE_ARGS += --coverage-line -Wno-fatal
COMPILE_ARGS += -CFLAGS -isystem/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk/usr/include/c++/v1
endif
endif

ifeq ($(strip $(VERILOG_SOURCES)),)
$(warning VERILOG_SOURCES is empty. Pass your RTL list on the make command line.)
endif

include $(shell $(COCOTB_CONFIG) --makefiles)/Makefile.sim
