# Allegro

Allegro 是一个多精度 dot-product RTL 实验仓库，当前重点是 `dot_cluster_top` 以及面向 NVIDIA-style Tensor Core 数据格式的 bit-accurate 验证。RTL 使用 SystemVerilog，参考模型使用本仓库 vendor 的 `MMA-Sim`。

本分支同时包含独立的 Blackwell-style TMA、Tensor Core、mbarrier 和 TMEM
子系统，复用同仓库的 TCGen05 算术 RTL，并提供接口规范和独立功能回归。

## Repository Layout

- `src/main/`: synthesizable SystemVerilog RTL。
- `src/main/utils/`: dot-product 共享组合逻辑和通用流水寄存器，例如 FP32 pack、reduction tree、emax tree、align helper。
- `src/test/`: 轻量 SystemVerilog directed testbench。
- `src/test/cocotb/`: cocotb + MMA-Sim 联合验证。
- `MMA-Sim/`: vendored MMA-Sim reference model，保留原始 MIT license。
- `doc/`: datapath、格式和验证说明。

后端综合实验文件不再作为仓库内容维护；本仓库当前只保留 RTL、验证、文档和 reference model。

## Current RTL Structure

`dot_cluster_top` 当前有两级请求侧流水：

```text
top request
  -> ingress_payload_q
  -> B-side sparse compaction + dtype dispatch
  -> issue_payload_q
  -> share-group admission
  -> selected dot core
  -> output arbiter
```

主要 datapath：

- `f16tf32_f4f6f8_shared_dot_prod`: 物理合并 F16/BF16/TF32 与 F4/F6/F8 路径，共享 33-bit accumulation tail 和 FP32 RZ pack。
- `int8_dot_prod`: INT8 dot-product 独立路径。
- `fp4_dot_prod`: NVFP4/MXFP4/FP4 block-scale dot-product 独立路径。

`dot_cluster_top` 对 B operand 支持结构化 sparse compaction。A operand 不做 sparse selection。`outstanding_q` 和 `active_share_group_q` 用于 share-group admission，避免同一物理流水里跨模式乱序。

## Blackwell Subsystem

| 模块 | 当前实现 | 实现规范 |
| --- | --- | --- |
| Tensor Core | 8 路 FP16 dot，固定 `M64N8K16`，FP16×FP16→FP32，覆盖/累加 | [Tensor Core 与现有 TMEM](doc/tensor_core_spec.md) |
| TMEM | 默认 8 banks×128×32 bit，双 tile slot，1R1W/1RW/2R1W 仲裁 | [当前实现](doc/tensor_core_spec.md#tmem-contract) |
| TMA | 1–5D tensor 与 linear 双向搬运、descriptor cache、乱序响应及越界处理 | [TMA spec](doc/tma_spec.md) |
| mbarrier | arrival/transaction 联合计数、phase、wait CAM、memory-backed 状态及错误恢复 | [mbarrier spec](doc/mbarrier_spec.md) |

[TMEM 扩展设计目标](doc/tmem_spec.md) 仍处于尚未实现状态，其中 allocation、
tcgen05.ld/st/cp 等能力不属于当前 `tmem_array`。原有 `doc/tma.md` 和
`doc/mbarrier.md` 保留为背景说明；本子系统的实现接口以表中的 spec 为准。
本工程依据公开语义设计，不是 NVIDIA 私有 RTL 或周期精确模型。

```text
blackwell_tma_mbarrier_top
├── blackwell_tensor_subsystem
│   ├── tcgen05_tensor_wrapper → tcgen05_dot_adapter
│   └── tmem_array
└── tma_mbarrier_subsystem
    ├── tma_engine
    └── mbarrier_unit
```

连接顶层把旧 `TMA_REQ` 转为实际的 256-byte GMEM→SMEM 搬运，并提供完整的
TMA 与 mbarrier 命令接口。Tensor 的 SMEM A/B/写回端口与 TMA 的 SMEM 端口
分别对外暴露，由使用方连接内存后端。参见
[TMA/mbarrier 语义映射与集成边界](doc/tma_mbarrier_patent_mapping.md)。

子系统复用当前 checkout 的 `src/main` 算术源码，版本由 Allegro 的 Git 提交
确定，无需外部 `deps/Allegro`。FP4、INT8 等源码仍是 adapter 内部实例化所需，
不能因子系统只开放 FP16 就移除这些编译引用。

Blackwell lint 和仿真仅在配置的 RTX 5080 主机执行，使用其 CPU；本地用于编辑
和静态文件检查。验证环境为 Bash、GNU Make、C++ 编译器、Verilator 5.020、
Python 3、Cocotb 1.9.2 和 NumPy。在远端工程根目录运行：

```bash
make lint-blackwell
make test-blackwell
```

`make test-blackwell` 先 lint 三个顶层，再运行五组测试的 11 个配置：

- TMA/mbarrier：1–5D、所有元素宽度、双向搬运、乱序与背压、barrier 顺序与错误恢复。
- TMEM：默认、1RW、2R1W，覆盖双 slot、bank 冲突和停顿 payload。
- Tensor wrapper：0/1/2 级输出寄存，覆盖 8 路 FP16 和输出背压。
- Tensor subsystem：默认和两个参数组合，覆盖完整 tile、覆盖/累加、同步和 SMEM 背压。
- 兼容顶层：旧 `TMA_REQ` 的真实 256-byte 搬运和完成顺序。

可用 `JOBS=4 make test-blackwell` 设置编译并行度，默认 4；
`COCOTB_RANDOM_SEED` 默认 `20260813`。日志、编译文件和每个配置的 `results.xml`
统一位于被忽略的 `build/blackwell/`，不使用原有算术测试的构建目录。
驱动脚本位于 `src/test/blackwell_common.sh`、`src/test/lint_blackwell.sh` 和
`src/test/run_blackwell_tests.sh`；既有 Cocotb Makefile 与命令继续可用。

编译 filelist 均以仓库根目录为工作目录：

- [Tensor/TMEM](src/main/blackwell_tensor_filelist.f)
- [独立 TMA/mbarrier](src/main/tma_mbarrier_filelist.f)
- [四模块连接顶层](src/main/blackwell_subsystem_filelist.f)

## Environment Setup

建议使用本地 Python virtual environment：

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install cocotb torch pytest
```

RTL smoke test 还需要至少安装一个 Verilog simulator：

- Icarus Verilog: `iverilog` / `vvp`
- Verilator: `verilator`

cocotb Makefile 默认会把仓库内的 MMA-Sim 放到 `PYTHONPATH`：

```make
PYTHONPATH := $(PWD):$(PWD)/../../../MMA-Sim:$(PYTHONPATH)
```

因此 `src/test/cocotb/mma_sim_*_ref.py` 可以直接 import `MMA-Sim/mmasim`，并调用 MMA-Sim 的 `nv_fused_dot_add()`、`fused_sum()`、`nv_fused_dot_add_with_block_scale()` 等 reference helper。

如果使用 `.venv`，运行 cocotb 时建议显式覆盖 Makefile 中的 Python/cocotb 路径：

```bash
export ALLEGRO_ROOT="$(pwd)"
export COCOTB_BIN="$ALLEGRO_ROOT/.venv/bin"
export PYTHON_BIN="$ALLEGRO_ROOT/.venv/bin/python"
```

## RTL Quick Checks

Verilator lint：

```bash
verilator --lint-only --timing -Wno-fatal --top-module dot_cluster_top \
  src/main/utils/dot_prod_pkg.sv \
  src/main/utils/dot_fp32_rz_norm_pack.sv \
  src/main/utils/dot_signed_reduce_tree.sv \
  src/main/utils/dot_emax_tree.sv \
  src/main/utils/dot_align_fixed_rz.sv \
  src/main/utils/pipeline_reg.sv \
  src/main/f16tf32_s0_s2_frontend.sv \
  src/main/f4f6f8_s0_s2_frontend.sv \
  src/main/f16tf32_f4f6f8_shared_dot_prod.sv \
  src/main/int8_dot_prod.sv \
  src/main/fp4_dot_prod.sv \
  src/main/dot_cluster_top.sv
```

Icarus directed test：

```bash
iverilog -g2012 -o /tmp/dot_cluster_top_tb.vvp \
  src/main/utils/dot_prod_pkg.sv \
  src/main/utils/dot_fp32_rz_norm_pack.sv \
  src/main/utils/dot_signed_reduce_tree.sv \
  src/main/utils/dot_emax_tree.sv \
  src/main/utils/dot_align_fixed_rz.sv \
  src/main/utils/pipeline_reg.sv \
  src/main/f16tf32_s0_s2_frontend.sv \
  src/main/f4f6f8_s0_s2_frontend.sv \
  src/main/f16tf32_f4f6f8_shared_dot_prod.sv \
  src/main/int8_dot_prod.sv \
  src/main/fp4_dot_prod.sv \
  src/main/dot_cluster_top.sv \
  src/test/dot_cluster_top_tb.sv
vvp /tmp/dot_cluster_top_tb.vvp
```

Icarus 可能打印 `constant selects in always_* processes are not fully supported`，这是 Icarus 的敏感列表限制；只要编译退出码为 0 且 testbench PASS 即可。

## cocotb + MMA-Sim Joint Verification

先进入 cocotb 目录：

```bash
cd src/test/cocotb
```

常用联合验证命令：

```bash
make TOPLEVEL=f16tf32_dot_prod COCOTB_TEST_MODULES=test_f16tf32_dot NUM_CASES=1000
make TOPLEVEL=f4f6f8_dot_prod COCOTB_TEST_MODULES=test_f4f6f8_dot NUM_CASES=1000
make TOPLEVEL=fp4_dot_prod COCOTB_TEST_MODULES=test_nvfp4_dot NUM_CASES=1000
make TOPLEVEL=dot_cluster_top COCOTB_TEST_MODULES=test_dot_cluster_top NUM_CASES=1000
```

如果使用 `.venv`：

```bash
COCOTB_BIN="$PWD/../../../.venv/bin" \
PYTHON_BIN="$PWD/../../../.venv/bin/python" \
NUM_CASES=1000 \
make TOPLEVEL=f16tf32_dot_prod COCOTB_TEST_MODULES=test_f16tf32_dot
```

主要 test/golden 对应关系：

- `test_f16tf32_dot.py`: TF32/BF16/FP16，调用 `mma_sim_tf32_ref.py` 和 `mma_sim_fp16_ref.py`。
- `test_f4f6f8_dot.py`: F4/F6/F8/MXFP8，调用 `mma_sim_f4f6f8_ref.py`。
- `test_nvfp4_dot.py`: NVFP4/MXFP4/FP4，调用 `mma_sim_nvfp4_ref.py`。
- `test_dot_cluster_top.py`: top-level dense/sparse、tag/status、backpressure、share-group admission。
- `test_tcgen05_mma.py`: adapter inventory 与 TCGen05-style MMA cases。

随机规模和种子：

```bash
NUM_CASES=200 RANDOM_SEED=1234 make TOPLEVEL=fp4_dot_prod COCOTB_TEST_MODULES=test_nvfp4_dot
```

## MMA-Sim License

`MMA-Sim` 以源码形式 vendor 在本仓库中，仅用于 bit-accurate reference。其 license 保留在 `MMA-Sim/LICENSE.txt`，当前为 MIT License。
