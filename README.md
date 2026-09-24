# Allegro

Allegro 是一个多精度 dot-product RTL 实验仓库，当前重点是 `dot_cluster_top` 以及面向 NVIDIA-style Tensor Core 数据格式的 bit-accurate 验证。RTL 使用 SystemVerilog，参考模型使用本仓库 vendor 的 `MMA-Sim`。

本分支同时包含独立的 Blackwell-style TMA、Tensor Core、mbarrier 和 TMEM
子系统，复用同仓库的 TCGen05 算术 RTL，并提供接口规范和独立功能回归。

## Repository Layout

- `rtl/`: 按 common、dot、tensor_core、tmem、tma、mbarrier、smem 和 top 分组的可综合 SystemVerilog。
- `verification/`: SV testbench、Cocotb、CUDA golden 生成器、结构检查和性能实验。
- `scripts/blackwell/`、`filelists/`: Blackwell 验证/综合入口与显式编译清单。
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
| Tensor Core | 旧产品路径仍为 8 路固定 FP16；新增独立 4×64 FP16/BF16 实算术阵列，未接入 collector/TMEM | [算术阵列合同](doc/f16_array_contract.md) |
| TMEM | 旧 Tensor 顶层仍用 8-bank 双 tile；新增独立 256 KiB bank、16 KiB RF SRAM 暂存、按 bank word 分组的 warp LD/ST 与单 CTA SHIFT 路径 | [RF 执行合同](doc/tmem_rf_execution_contract.md) |
| TMA | 单 CTA 1–5D tiled、3–5D im2col/wide、32/64/128B swizzle、每线程 bulk-group | [TMA spec](doc/tma_spec.md) |
| mbarrier | 8B 对象、arrival/transaction 计数、opaque state/parity 有限等待、失效恢复 | [mbarrier spec](doc/mbarrier_spec.md) |

[单 CTA 异步子系统实施记录](doc/async_tensor_implementation.md) 描述新增的完成控制器、
多请求 dot 流水和 SRAM 基础模块；[共享 SMEM 后端](doc/async_smem_contract.md) 进一步实现
字节接口、共享仲裁、片上原子、排序跟踪和真实线程集合。完整 SM100a 计划尚未完成。

[TMEM 扩展设计目标](doc/tmem_spec.md) 的完整指令前端仍处于尚未实现状态。
新的 `blackwell_tmem_bank` 已实现物理列分配/释放与所有权检查，
`blackwell_tmem_rf_subsystem` 已把五种 RF shape 地址映射接成可执行的单 warp
LD/ST、pack/unpack 与 RF 接收确认；同一 bank word 的访问合并成一个物理 beat。
单 CTA `shift.down` 已接入同一物理 bank，先预检完整访问范围再逐列写入；
SHIFT 已提供向共享 TC commit 追踪器的登记/完成事件，并在组合测试中经过
真实 mbarrier backing 写确认与 cache 驱逐后 SRAM 读回；CP 和该新路径向产品
顶层的迁移尚未完成。
新 RF/TMEM 路径已接入独立的 `wait::ld/st` 快照完成域。
TMA/mbarrier 仅维护表中两份权威规范，
以 PTX 9.4 / SM100a 公开语义为目标，逐项区分当前实现、未实现能力和集成责任。
cluster、multicast、跨 CTA 同步和 `cta_group::2` 尚未实现。
本工程依据公开语义设计，不是 NVIDIA 私有 RTL 或周期精确模型。

```text
blackwell_tma_mbarrier_top
├── blackwell_tensor_subsystem
│   ├── tcgen05_tensor_wrapper → tcgen05_dot_adapter
│   └── tmem_array
└── tma_mbarrier_subsystem
    ├── tma_engine → tma_copy_engine
    │   ├── tma_data_engine → tma_tensor_map
    │   └── tma_map_control
    └── mbarrier_frontend → mbarrier_unit
```

连接顶层提供统一的 `tma_cmd_t/tma_rsp_t` 与 `bar_cmd_t/bar_rsp_t`。
Tensor COMMIT/WAIT 只跟踪 Tensor 操作；调用方显式等待 TMA 数据后再提交相关计算。
Tensor 的 SMEM A/B/写回端口与 TMA 的 SMEM 端口分别对外暴露。

TMA 使用 128B、64B 对齐的项目内部 **v3 descriptor**，拒绝旧版本，不解码 CUDA opaque 格式。
编码器位于 [`tma_mbarrier_ref.py`](verification/cocotb/tma_mbarrier_ref.py)。
覆盖 tiled、gather/scatter、interleave、swizzle、im2col、packed/TF32 格式、copy/reduce、
prefetch、map 更新与发布；mbarrier 覆盖 v0/v1、report、普通 cp.async 和有限等待。
原子执行、multimem 路由和内存可见性由带属性与排序确认的外部后端兑现。
同 CTA shared copy 是项目扩展：PTX 对应 shared→shared copy 要求目的地属于不同 CTA。
详细边界与验证证据见[实现验收矩阵](doc/sm100a_implementation_matrix.md)、
[验证记录](doc/sm100a_validation.md)和
[TMA 排序契约](doc/tma_spec.md#5-完成域线程与内存顺序)。

子系统复用当前 checkout 的 `rtl/dot/` 算术源码，版本由 Allegro 的 Git 提交
确定，无需外部 `deps/Allegro`。FP4、INT8 等源码仍是 adapter 内部实例化所需，
不能因子系统只开放 FP16 就移除这些编译引用。

Blackwell lint 和仿真仅在配置的 RTX 5080 主机执行，使用其 CPU；本地用于编辑
和静态文件检查。验证环境为 Bash、GNU Make、C++ 编译器、Verilator 5.020、
Python 3、Cocotb 1.9.2 和 NumPy。在远端工程根目录运行：

```bash
make lint-blackwell
make test-blackwell
```

`make test-blackwell` 先 lint，再启用运行时协议断言并执行旧回归及新增配置：

- 异步完成：默认及非 2 次幂小容量，覆盖快照、乱序完成、跨 issuer 前进、epoch 和错误。
- SRAM 基础模块：完整 256 KiB TMEM / 228 KiB SMEM 容量、byte enable、1R1W、背压和带宽。
- TMEM 物理后端：CTA/epoch 所有权、分配/部分释放、全容量、byte mask、
  同 word 仲裁、4096 周期物理端口吞吐、五种 RF shape 地址映射，
  以及全源捕获、bank-word 分组、16 KiB RF SRAM、预检、RF 背压、完成时序
  和单 warp 4096 周期稳态搬运基准。
- 共享 SMEM：字节拆分/重组、多客户端仲裁、真实原子竞争、同址依赖、独立响应 credit 和 4096 周期吞吐。
- 排序与线程集合：延迟可见性确认、issuer 隔离、故障传播、32 线程逐个到达和显式执行释放。
- TMA/真实 SMEM：mbarrier backing、load/store、bulk `.read` 与完整等待、swizzle 和片上 reduction。
- Dot pipeline：混合算术路径与 tag、错误请求、输出背压及 4096 周期吞吐。
- FP16/BF16 阵列：4 与 256 核配置，分别连续 4096 周期实算术吞吐、逐 lane 数值、tag 与背压。
- TMA/mbarrier：默认及两个资源配置；TC arrival/commit、两种 barrier layout、异步登记/完成、排序、全部 reduction 类型组合、格式 golden、bulk-group、多目标确认及错误恢复。
- TMEM：默认、1RW、2R1W，覆盖双 slot、bank 冲突和停顿 payload。
- Tensor wrapper：0/1/2 级输出寄存，覆盖 8 路 FP16 和输出背压。
- Tensor subsystem：默认和两个参数组合，覆盖完整 tile、覆盖/累加、同步和 SMEM 背压。
- 统一接口顶层：保留真实256B搬运，验证TMA填充操作数、显式等待后进行Tensor计算及独立COMMIT/WAIT。

可用 `JOBS=4 make test-blackwell` 设置编译并行度，默认 4；
`BLACKWELL_TEST_TOP` 可用逗号分隔选取多个顶层。远端保留的 Yosys 镜像可执行
`make synth-blackwell-sram` 检查两种 SRAM 的综合容量和 1R1W 结构。
`make synth-blackwell-tmem-bank` 使用隔离安装的 sv2v 和既有 ORFS/Yosys 镜像，
对 TMEM 所有权后端连同存储层次执行综合结构检查。
`make synth-blackwell-tmem-rf` 进一步检查独立 RF 执行层与物理 TMEM 的层次结构。
`make synth-blackwell-f16-array` 检查四分区 256 个非 black-box 实算术核的层次结构。
`COCOTB_RANDOM_SEED` 默认 `20260813`。日志、编译文件和每个配置的 `results.xml`
统一位于被忽略的 `build/blackwell/`，不使用原有算术测试的构建目录。
驱动脚本位于 `scripts/blackwell/blackwell_common.sh`、`scripts/blackwell/lint_blackwell.sh` 和
`scripts/blackwell/run_blackwell_tests.sh`；算术 Cocotb 从仓库根目录运行 `make test-arithmetic`。

布局与格式回归对照 [布局 golden](verification/cocotb/golden/nvidia_tma_sm120a.json) 和
[格式 golden](verification/cocotb/golden/nvidia_tma_formats_sm120a.json)，
数据由可选的[布局生成器](verification/oracles/blackwell_nv_oracle.cu)和
[格式生成器](verification/oracles/blackwell_nv_formats_oracle.cu)在 RTX 5080 / SM120a 生成，只验证两架构共同支持的操作。常规 RTL 回归无需 CUDA 或 GPU；SM100a 特有语义
仍依据官方条款与独立 golden 验证，不能把这组实测结果视为 SM100a 全功能硬件认证。

编译 filelist 均以仓库根目录为工作目录：

- [Tensor/TMEM](filelists/blackwell_tensor_filelist.f)
- [独立 TMA/mbarrier](filelists/tma_mbarrier_filelist.f)
- [四模块连接顶层](filelists/blackwell_subsystem_filelist.f)
- [新增异步控制与 SRAM](filelists/blackwell_async_filelist.f)

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
PYTHONPATH := $(CURDIR):$(CURDIR)/../../MMA-Sim:$(PYTHONPATH)
```

因此 `verification/cocotb/mma_sim_*_ref.py` 可以直接 import `MMA-Sim/mmasim`，并调用 MMA-Sim 的 `nv_fused_dot_add()`、`fused_sum()`、`nv_fused_dot_add_with_block_scale()` 等 reference helper。

如果使用 `.venv`，运行 cocotb 时可指定虚拟环境的 Python：

```bash
export PYTHON_BIN="$PWD/.venv/bin/python"
```

## RTL Quick Checks

Verilator lint：

```bash
verilator --lint-only --timing -Wno-fatal --top-module dot_cluster_top \
  rtl/dot/dot_prod_pkg.sv \
  rtl/dot/dot_fp32_rz_norm_pack.sv \
  rtl/dot/dot_signed_reduce_tree.sv \
  rtl/dot/dot_emax_tree.sv \
  rtl/dot/dot_align_fixed_rz.sv \
  rtl/dot/pipeline_reg.sv \
  rtl/dot/f16tf32_s0_s2_frontend.sv \
  rtl/dot/f4f6f8_s0_s2_frontend.sv \
  rtl/dot/f16tf32_f4f6f8_shared_dot_prod.sv \
  rtl/dot/int8_dot_prod.sv \
  rtl/dot/fp4_dot_prod.sv \
  rtl/dot/dot_cluster_top.sv
```

Icarus directed test：

```bash
iverilog -g2012 -o /tmp/dot_cluster_top_tb.vvp \
  rtl/dot/dot_prod_pkg.sv \
  rtl/dot/dot_fp32_rz_norm_pack.sv \
  rtl/dot/dot_signed_reduce_tree.sv \
  rtl/dot/dot_emax_tree.sv \
  rtl/dot/dot_align_fixed_rz.sv \
  rtl/dot/pipeline_reg.sv \
  rtl/dot/f16tf32_s0_s2_frontend.sv \
  rtl/dot/f4f6f8_s0_s2_frontend.sv \
  rtl/dot/f16tf32_f4f6f8_shared_dot_prod.sv \
  rtl/dot/int8_dot_prod.sv \
  rtl/dot/fp4_dot_prod.sv \
  rtl/dot/dot_cluster_top.sv \
  verification/tb/dot_cluster_top_tb.sv
vvp /tmp/dot_cluster_top_tb.vvp
```

Icarus 可能打印 `constant selects in always_* processes are not fully supported`，这是 Icarus 的敏感列表限制；只要编译退出码为 0 且 testbench PASS 即可。

## cocotb + MMA-Sim Joint Verification

从仓库根目录运行：

```bash
make test-arithmetic NUM_CASES=1000
```

常用联合验证命令：

```bash
make test-arithmetic TOPLEVEL=f16tf32_dot_prod COCOTB_TEST_MODULES=test_f16tf32_dot NUM_CASES=1000
make test-arithmetic TOPLEVEL=f4f6f8_dot_prod COCOTB_TEST_MODULES=test_f4f6f8_dot NUM_CASES=1000
make test-arithmetic TOPLEVEL=fp4_dot_prod COCOTB_TEST_MODULES=test_nvfp4_dot NUM_CASES=1000
make test-arithmetic TOPLEVEL=dot_cluster_top COCOTB_TEST_MODULES=test_dot_cluster_top NUM_CASES=1000
```

如果使用 `.venv`：

```bash
PYTHON_BIN="$PWD/.venv/bin/python" \
NUM_CASES=1000 \
make test-arithmetic TOPLEVEL=f16tf32_dot_prod COCOTB_TEST_MODULES=test_f16tf32_dot
```

主要 test/golden 对应关系：

- `test_f16tf32_dot.py`: TF32/BF16/FP16，调用 `mma_sim_tf32_ref.py` 和 `mma_sim_fp16_ref.py`。
- `test_f4f6f8_dot.py`: F4/F6/F8/MXFP8，调用 `mma_sim_f4f6f8_ref.py`。
- `test_nvfp4_dot.py`: NVFP4/MXFP4/FP4，调用 `mma_sim_nvfp4_ref.py`。
- `test_dot_cluster_top.py`: top-level dense/sparse、tag/status、backpressure、share-group admission。
- `test_tcgen05_mma.py`: adapter inventory 与 TCGen05-style MMA cases。

随机规模和种子：

```bash
NUM_CASES=200 RANDOM_SEED=1234 make test-arithmetic TOPLEVEL=fp4_dot_prod COCOTB_TEST_MODULES=test_nvfp4_dot
```

## MMA-Sim License

`MMA-Sim` 以源码形式 vendor 在本仓库中，仅用于 bit-accurate reference。其 license 保留在 `MMA-Sim/LICENSE.txt`，当前为 MIT License。
