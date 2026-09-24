SIM ?= icarus
TOPLEVEL_LANG ?= verilog
TOPLEVEL ?= fp4_dot_prod
COCOTB_TEST_MODULES ?= test_nvfp4_dot
PYTHON_BIN ?= python3
COCOTB_CONFIG ?= $(PYTHON_BIN) -m cocotb.config

export PYTHONPATH := $(CURDIR):$(CURDIR)/../../MMA-Sim:$(PYTHONPATH)
export NUM_CASES ?= 20000
export COCOTB_RANDOM_SEED ?= 20260422

DOT_PROD_COMMON_SOURCES = $(CURDIR)/../../rtl/dot/dot_prod_pkg.sv \
                          $(CURDIR)/../../rtl/dot/dot_fp32_rz_norm_pack.sv \
                          $(CURDIR)/../../rtl/dot/dot_signed_reduce_tree.sv \
                          $(CURDIR)/../../rtl/dot/dot_emax_tree.sv \
                          $(CURDIR)/../../rtl/dot/dot_align_fixed_rz.sv \
                          $(CURDIR)/../../rtl/dot/pipeline_reg.sv

ifeq ($(TOPLEVEL),tcgen05_dot_adapter)
VERILOG_SOURCES ?= $(CURDIR)/../../rtl/tensor_core/tcgen05_mma_pkg.sv \
                   $(DOT_PROD_COMMON_SOURCES) \
                   $(CURDIR)/../../rtl/dot/f16tf32_dot_prod.sv \
                   $(CURDIR)/../../rtl/dot/f4f6f8_dot_prod.sv \
                   $(CURDIR)/../../rtl/dot/int8_dot_prod.sv \
                   $(CURDIR)/../../rtl/dot/fp4_dot_prod.sv \
                   $(CURDIR)/../../rtl/tensor_core/tcgen05_dot_adapter.sv
ifeq ($(SIM),verilator)
COMPILE_ARGS += -Wno-fatal
ifeq ($(shell uname -s),Darwin)
COMPILE_ARGS += -CFLAGS -isystem/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/c++/v1
endif
endif
else ifeq ($(TOPLEVEL),dot_cluster_top)
VERILOG_SOURCES ?= $(DOT_PROD_COMMON_SOURCES) \
                   $(CURDIR)/../../rtl/dot/f16tf32_s0_s2_frontend.sv \
                   $(CURDIR)/../../rtl/dot/f4f6f8_s0_s2_frontend.sv \
                   $(CURDIR)/../../rtl/dot/f16tf32_f4f6f8_shared_dot_prod.sv \
                   $(CURDIR)/../../rtl/dot/int8_dot_prod.sv \
                   $(CURDIR)/../../rtl/dot/fp4_dot_prod.sv \
                   $(CURDIR)/../../rtl/dot/dot_cluster_top.sv
else ifeq ($(TOPLEVEL),f16tf32_dot_prod)
VERILOG_SOURCES ?= $(DOT_PROD_COMMON_SOURCES) \
                   $(CURDIR)/../../rtl/dot/f16tf32_dot_prod.sv
else ifeq ($(TOPLEVEL),f4f6f8_dot_prod)
VERILOG_SOURCES ?= $(DOT_PROD_COMMON_SOURCES) \
                   $(CURDIR)/../../rtl/dot/f4f6f8_dot_prod.sv
else ifeq ($(TOPLEVEL),int8_dot_prod)
VERILOG_SOURCES ?= $(DOT_PROD_COMMON_SOURCES) \
                   $(CURDIR)/../../rtl/dot/int8_dot_prod.sv
else ifeq ($(TOPLEVEL),fp4_dot_prod)
VERILOG_SOURCES ?= $(DOT_PROD_COMMON_SOURCES) \
                   $(CURDIR)/../../rtl/dot/fp4_dot_prod.sv
else
VERILOG_SOURCES ?= $(DOT_PROD_COMMON_SOURCES) \
                   $(CURDIR)/../../rtl/dot/fp4_dot_prod.sv
endif
ifeq ($(SIM),icarus)
COMPILE_ARGS += -g2012
endif

ifeq ($(SIM),verilator)
ifeq ($(RTL_COVERAGE),1)
COMPILE_ARGS += --coverage-line -Wno-fatal
ifeq ($(shell uname -s),Darwin)
COMPILE_ARGS += -CFLAGS -isystem/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk/usr/include/c++/v1
endif
endif
endif

ifeq ($(strip $(VERILOG_SOURCES)),)
$(warning VERILOG_SOURCES is empty. Pass your RTL list on the make command line.)
endif

include $(shell $(COCOTB_CONFIG) --makefiles)/Makefile.sim
