# 单 CTA 异步子系统验证记录

## 2026-09-23 SHIFT → TC commit → 真实 mbarrier backing

[组合夹具](../verification/tb/blackwell_tmem_shift_commit_tb.sv)新增 `REAL_BACKING=1`
配置，将真实 TMEM SHIFT、共享 TC 完成控制器、`mbarrier_frontend` 和
`blackwell_tma_smem_bridge` 接到同一片 228 KiB 共享 SRAM。
[端到端测试](../verification/cocotb/test_tmem_shift_mbarrier.py)在 SHIFT 完成后
阻塞 backing 写确认，检查 commit 事件不提前返回；解除阻塞后检查 phase 变为 1。
接着初始化四个其他 mbarrier 对象，驱逐原对象，并要求 `try_wait` 经真实
SRAM 读请求取回 phase，而不是只读命中的对象 cache。夹具遵循产品桥接器的
约定：barrier 读请求补齐 32 字节有效掩码。

`allegro-shift-realbar-readback-20260923-02` 在远端 CPU 通过 RTL lint 和
**2 个配置、2/2 项定向测试**；归档校验通过，位于
`build/blackwell/shift-realbar-readback-20260923-02/`。这证明该组合路径的
写确认与驱逐后读回，但不代表旧 Tensor 产品顶层已迁移，也不提供 SM100
实机数值或吞吐证据。

相同源码的 `allegro-shift-realbar-full-20260923-01` 在独立远端目录通过全量
lint 和 **37 个配置、131/131 项测试**，XML failure/error 均为零，归档哈希
校验通过；证据位于 `build/blackwell/shift-realbar-full-20260923-01/`，
相关源码哈希见 `build/blackwell/async_subsystem/shift-realbar-manifest.json`。

## 2026-09-23 SHIFT → TC commit 完成链路

[RF/TMEM 子系统](../rtl/tmem/blackwell_tmem_rf_subsystem.sv)新增一项 SHIFT 待发队列和
带 issuer/warp/tag/sequence/epoch 的 TC 登记、完成事件。命令接受当拍先登记，
随后才可能进入真实 TMEM bank；最后一次 bank 写确认后发送完成事件，事件被
共享 TC 追踪器接受后才对外报告 SHIFT DONE。这符合
[PTX 9.4](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html)
把同一执行线程先前的 SHIFT 纳入 `tcgen05.commit` 的公开完成机制。

`allegro-shift-commit-queued-20260923-01` 在远端 CPU 完成 lint 与 **2 个配置、
5/5 项定向测试**：真实 bank 上的两种 lane partition、所有权预检、独立
`wait::ld/st`、注册/完成背压、RF sink 被阻塞时提前登记 SHIFT，以及
[组合夹具](../verification/tb/blackwell_tmem_shift_commit_tb.sv)中的同 issuer commit
快照、空/重复 commit、mbarrier arrival count=1、失败 SHIFT 走 fault。
该次夹具的 mbarrier 确认端点由测试控制，不能当作真实 backing 写入证明。
归档位于 `build/blackwell/shift-commit-queued-20260923-01/`。

最终源码的 `allegro-shift-commit-final-full-20260923-01` 在独立远端目录通过
全量 lint 和 **36 个配置、130/130 项测试**，XML failure/error 均为零，
归档哈希校验通过，位于
`build/blackwell/shift-commit-final-full-20260923-01/`。
`allegro-shift-commit-synth-20260923-01` 通过 sv2v/Yosys
`check -assert` 和结构检查：TMEM 仍为 **128 个 bank、256 KiB**，RF stage
仍为 **32 个 bank、16 KiB**，均无存储初始化；执行器顶层寄存器位为 **1564**。
该结构结果不等于工艺时序或 PPA。取回证据位于
`build/blackwell/shift-commit-synth-20260923-01/`，最终源码哈希记录在
`build/blackwell/async_subsystem/shift-commit-manifest.json`。

产品顶层尚未把所有 MMA/CP/SHIFT 生产者接到同一个 TC 追踪器。
后续增加的 SHIFT→真实 mbarrier backing 组合验收见本文件首节，但跨线程顺序所需的 thread fence、
CP、完整 TMEM 操作矩阵、吞吐门槛与 SM100 实机对照仍未完成，不能据此宣称
P2 或整份计划完成。

## 2026-09-23 TMEM `shift.down` 真实 bank 路径

[SHIFT 引擎](../rtl/tmem/blackwell_tmem_shift_engine.sv)已接入
[RF/TMEM 执行路径](../rtl/tmem/blackwell_tmem_rf_subsystem.sv)的物理 bank 仲裁。
它先通过 bank 的 context/epoch/所有权检查预检全部 32×8 单元，之后逐列
读取原值并写入下移结果；最后一次写确认后才返回可背压的完成响应。
SHIFT 不进入 `wait::ld/st` 追踪器。

最终源码的 `allegro-tmem-shift-optimized-target-20260923-01` 完成 RTL lint
和 **4/4 定向测试**，覆盖两组 lane partition、全部八列结果、最后一行保持、
完成响应阻塞、非法 lane/column、晚发现的无所有权列不发生部分写入，以及
SHIFT 不污染 LD/ST wait。`allegro-tmem-shift-optimized-full-20260923-01`
在独立远端 CPU 目录完成全量 lint 和 **35 个配置、129/129 项测试**，
XML failure/error 均为零。归档哈希已校验，日志和 XML 分别位于
`build/blackwell/tmem-shift-optimized-target-20260923-01/` 与
`build/blackwell/tmem-shift-optimized-full-20260923-01/`。

`allegro-tmem-shift-optimized-synth-20260923-01` 的 sv2v/Yosys
`check -assert` 及独立结构检查通过：128 个 TMEM bank 为 **256 KiB**，
32 个 RF stage bank 为 **16 KiB**，均没有 reset 初始化。将 SHIFT 写总线
改为固定 lane-bank 连线后，相同综合流程的 SHIFT 引擎未映射通用逻辑
cell 数从 **728 降至 400**；这不是工艺面积或时序结果。
证据在 `build/blackwell/tmem-shift-optimized-synth-20260923-01/`，
源码哈希在 `build/blackwell/async_subsystem/tmem-shift-manifest.json`。

当前 SHIFT 仍没有向 TC commit 追踪器登记完成事件，也没有与 SM100 实机
核对 row 方向与尾行行为。CP、thread fence、全操作矩阵、共享 TC/TMEM
调度及性能门槛继续属于未完成范围；本增量不能标记 P2 或整份计划完成。

## 2026-09-23 TMEM `wait::ld/st` 独立完成域

新增 [WAIT 快照追踪器](../rtl/tmem/blackwell_tmem_wait_tracker.sv)，并接入
[RF/TMEM 执行路径](../rtl/tmem/blackwell_tmem_rf_subsystem.sv)。
`allegro-tmem-wait-compact-20260923-01` 在远端 CPU 完成全顶层 RTL lint；
定向 **3 个配置、5/5 项测试**通过，包括追踪器默认与 2-operation/
2-wait 小容量配置，以及真实 bank/RF 集成。验证了空等待、类别分离、
乱序操作完成、快照后新操作、错误传播、同边沿完成与等待、响应背压、
RF 目标背压、普通 DONE 被阻塞、以及成功重建 context 后复用相同 epoch。
取回日志与 XML 的归档哈希校验通过，位于
`build/blackwell/tmem-wait-compact-20260923-01/`。

`allegro-tmem-wait-compact-synth-20260923-01` 的 sv2v/Yosys
`check -assert` 与结构检查通过，确认 128 个 TMEM bank 仍为 **256 KiB**、
32 个 RF staging bank 仍为 **16 KiB**，存储均无 reset 初始化。
把失败历史 epoch 从每个 warp/类别复制改为每个 context 保存后，
WAIT 追踪器的未映射 Yosys cell 数从 **20,305** 降至 **1,932**；
该数字只用于相同脚本下的结构比较，不是时序、面积或功耗结果。
证据位于 `build/blackwell/tmem-wait-compact-synth-20260923-01/`。
最终源码的 `allegro-tmem-wait-compact-full-20260923-01` 在独立远端 CPU
目录通过全量 lint 与 **35 个配置、128/128 项测试**；XML 中 failure/error
均为零，取回归档哈希校验通过，位于
`build/blackwell/tmem-wait-compact-full-20260923-01/`。

该路径仍一次只执行一条 warp 数据指令，无法证明多命令并发或 TMEM 吞吐
达标；旧产品 Tensor 顶层没有迁移到此路径。CP、SHIFT、thread fence 和
SM100 实机对照仍未完成，P2–P5 退出条件也没有达成。

## 2026-09-23 RF SRAM 与 bank-word 分组

后续版本将 16 KiB RF 暂存改为 **32 个 128×32-bit 同步 1R1W bank**，并按
TMEM lane bank 与 128-bit word 合并同一 warp 的 LD/ST 请求。独立组合逻辑
测试以 205 组确定及随机输入验证读共享、不同 word 冲突拆拍、同 word 字节
合并和重叠 ST 的线程顺序；`allegro-rf-group-20260923-02` 的分组与整合
专项 2/2 项通过。完整 RF→TMEM→RF 数据流、packed 高半字保留、越界 ST
无部分写入和 RF 背压回归继续通过。
`allegro-rf-group-full-20260923-01` 在独立远端源码目录完成完整 lint 与
**33 个配置、124/124 项测试**，没有 failure/error；取回的日志和 XML 均通过
归档哈希校验，位于 `build/blackwell/rf-group-full-20260923-01/`。

`allegro-rf-group-synth-20260923-01` 通过 sv2v/Yosys `check -assert`
和独立结构检查：**128 个 128×128-bit TMEM bank（256 KiB）**及
**32 个 128×32-bit RF staging bank（16 KiB）**，全部未初始化；
执行器顶层寄存器位为 **1245**。这只证明未映射层次的可综合结构，
没有工艺 SRAM 映射、时序或 PPA 结果。

`allegro-rf-perf-20260923-01` 的真实 RTL 专项测试 1/1 通过：
两个 register 的普通 ST 在捕获 RF 源数据后 **13 周期**完成，packed split
ST 为 **11 周期**。`allegro-rf-steady-20260923-01` 的 2/2 项测试中，
新基准预热 32 次后连续统计 **4104 周期**，
单 warp、`.32x32b.x1` 的 128-byte ST 完成 **456 次**，有效 payload
吞吐为 **14.222 B/cycle**；源和终点使用同一真实 TMEM bank，结束后 LD
读回验证数据。这是单命令串行前端的工程数据，远低于物理 bank 端口总带宽，
也不是 NVIDIA LD/ST 实机对标或完整 GEMM 流水吞吐。

## 2026-09-23 TMEM warp RF 执行路径初版

[独立 RF 执行模块](../rtl/tmem/blackwell_tmem_rf_subsystem.sv)已把地址映射与完整
256 KiB TMEM bank 接成可运行的 warp LD/ST。`allegro-rf-full-20260923-01`
在远端 CPU 通过 **32 个配置、123/123 项测试**及全顶层 lint；日志与 XML
通过远端归档哈希校验，取回到 `build/blackwell/rf-full-20260923-01/`。
`allegro-rf-engine-20260923-04` 用最新专项测试再次通过 1/1：五种 shape
的执行样例、pack/unpack、非零 warp/base、源寄存器捕获后变化、RF 接收背压、
保留目标 cell 高半字，以及越界 ST 在任何写入前失败。专项日志位于
`build/blackwell/rf-engine-20260923-04/`。
`allegro-rf-synth-20260923-01` 通过 sv2v/Yosys `check -assert` 和独立结构
检查，确认执行器层次下仍有 128 个未初始化的 128×128-bit 同步 1R1W bank，
即完整 **262144 B** TMEM；归档位于 `build/blackwell/rf-synth-20260923-01/`。
该初版 RF 暂存没有推成 SRAM，执行器顶层综合网表有 **131234 个 flop 位**（含控制）。
它证明初版可综合，但不满足计划所需的高效暂存结构；网表也没有经过工艺映射或 PPA。

测试证明此独立路径的这些功能，不证明所有合法 repeat/modifier 的完整覆盖，
更不证明 P2 退出。初版逐 cell 调度且 ST 加做完整预检，既未接入旧产品顶层，
也未达到 NV 对齐的 LD/ST 吞吐目标。CP、SHIFT、WAIT、thread fence、
TMEM 与 TC 的资源/完成集成均仍缺失；SM100 实机一致性未验证。

## 2026-09-23 TMEM 与 FP16/BF16 算术增量

同日的 FP16/BF16 算术资源增量：`allegro-f16-array-20260923-03` 在默认
256 核和 4 核缩小配置上定向回归均通过。256 核实算术 RTL 连续 4096 周期
分别完成 FP16、BF16 各 4096 次向量请求：**每种类型 8192 operation/cycle**，
为本计划独立算术峰值的 100%。tag、逐 lane C、数值结果和输出背压通过。
`allegro-f16-synth-20260923-03` 的 sv2v/Yosys 层次检查确认
**256 个非 black-box `f16tf32_dot_prod`**，四分区各 64 个。
证据位于 `build/blackwell/f16-array-20260923-03/` 和
`build/blackwell/f16-synth-20260923-03/`。这是独立算术端口供数测试，
未计入 SMEM/TMEM/TMA 搬运或 scale/metadata，不能称为 P3 完整流水达标。

本轮加入 [TMEM bank/所有权后端](../rtl/tmem/blackwell_tmem_bank.sv)、
[普通 LD/ST RF 地址映射](../rtl/tmem/blackwell_tmem_rf_map.sv)及专项测试。
后端覆盖完整 256 KiB、32-column 分配单元、CTA/epoch 所有权、响应背压、
同 word 读写仲裁、byte mask、部分释放和资源耗尽时释放先行。
4096 个稳态周期中，物理接口每周期都接受 2048 B read 与 2048 B write；
这只是 TMEM bank 带宽，不是 LD/ST 指令或 MMA 吞吐。

| 远端 managed run | 结果 | 证据边界 |
|---|---|---|
| `allegro-tmem-final-20260923-01` | 29 配置，120/120 测试通过，RTL lint 通过 | packed 控制表等价重构之前的完整快照 |
| `allegro-tmem-packed-20260923-01` | 新 TMEM bank、RF map 定向 2/2 通过，完整 lint 通过 | packed 控制表和分配译码修改后的源码 |
| `allegro-tmem-synth-20260923-02` | sv2v/Yosys `check -assert` 与独立结构检查通过 | 完整 TMEM owner/storage 层次；128 个 128×128-bit 1R1W bank，无初始化，共 262144 B |

全部 RTL lint/仿真与综合均在配置的 RTX 5080 主机 CPU 上的独立 managed run
执行；综合复用 `openroad/orfs:latest` 镜像和隔离的 sv2v 0.0.13。
日志、XML、转换 Verilog、综合网表及结构 JSON 位于 gitignored
`build/blackwell/tmem-final-20260923-01/`、`tmem-packed-20260923-01/` 和
`tmem-synth-20260923-02/`，取回时通过归档校验。
增量源码哈希与 run ID 汇总在
`build/blackwell/async_subsystem/tmem-f16-manifest.json`。
当前产品 Tensor 顶层仍用旧 4 KiB 双 tile；本轮不满足 P2–P5 的完整指令和吞吐退出条件，
更不能宣称 SM100 实机一致性。

## 2026-09-18 历史基线

更新：2026-09-18（北京时间）。**整份 P0–P5 实施计划仍未完成。**
本次新增共享 SMEM、字节接口、排序跟踪、线程集合和真实 SMEM 集成；
不能据此宣称完整 SM100a 功能或单 SM 计算性能对齐。
接口与边界见 [共享后端合同](async_smem_contract.md) 和 [实施记录](async_tensor_implementation.md)。

## 当前源码验证

RTL lint / Cocotb 均在配置的 RTX 5080 主机 **CPU** 的独立 managed run 中执行。
环境为 Verilator 5.020、Cocotb 1.9.2、Python 3.12；没有使用 GPU 执行 RTL，
没有 B200/SM100 实机验证。全量回归现在启用 Verilator `--assert`。

| Run ID | 配置 | 结果 | 墙钟耗时 |
|---|---:|---:|---:|
| `allegro-smem-final-20260917-01` | 27 | **118/118** | 393.99s |
| `allegro-sram-synth-20260917-02` | TMEM、SMEM 两种物理配置 | 容量、1R1W、无初始化检查通过 | 24.43s |

全量运行结束于 `2026-09-17T16:01:11Z`，即北京时间 9 月 18 日 00:01。
覆盖此前全部 18 个配置，并新增共享 SMEM 后端 2 配置、字节接口 2 配置、
排序跟踪 2 配置、warp 集合 2 配置和真实 SMEM TMA/mbarrier 集成 1 配置。
全部 118 项执行无 failure/error。取回的日志、XML、综合网表均通过 archive SHA-256 校验。

最终 lint 没有 **LATCH、MULTIDRIVEN、UNOPTFLAT** 诊断。
仍有 unused、width 等告警，使用仓库的 `-Wno-fatal`，不是零告警验收。
本地只执行编辑、静态语法、文件清单、diff 和证据哈希检查。

## 共享 SMEM 吞吐

以下为真实共享 SRAM 与仲裁、字节拆分/重组接口的 RTL 测量；
所有客户端竞争同一物理数组，读写同时进行。

| 配置 | 有效读 | 有效写 | 稳态窗口 |
|---|---:|---:|---:|
| 8 客户端、每端口 8 个上下文，字节接口 | **128 B/cycle** | **128 B/cycle** | 4096 cycles |
| 3 客户端、每端口 3 个上下文，字节接口 | 76.78 B/cycle | 76.78 B/cycle | 4096 cycles |
| 物理仲裁后端，默认及 3 客户端配置 | 128 B/cycle | 128 B/cycle | 4096 cycles |

默认字节接口达到配置带宽的 100%，超过 90% 工程门槛。
该吞吐测试完整执行 4172 cycles，包含 reset、初始化、64-cycle 预热和排空；
4096-cycle 稳态窗口单独统计。三上下文配置故意缩小在途窗口，按窗口限制单独报告。
这些数字**不是 TMA 端到端搬运或 GEMM 吞吐**。旧 TMA 仍逐元素生成 tensor 事务，
线性 SMEM segment 仍为 32B；多上下文与合并尚未迁移。

## 异步、原子与真实数据通路

- 字节接口覆盖全部 128 种起始 byte offset、跨行重组、逐字节 mask、空 mask、
  地址高位和尾部越界；非法写在产生任何副作用前被拒绝。
- 同一客户端的重叠读写按依赖执行；不相交请求可并行，响应可按 tag 乱序返回。
- 每客户端独立响应 credit；停止一个消费者不会占满其他客户端的完成存储。
- 所有合法 shared reduction 类型/操作、符号边界、部分 element mask 拒绝和
  多客户端争用同一字的累加均与独立 byte/reference 模型一致。
- 排序测试覆盖真实 operation completion、延迟 maintenance ack、不同 issuer 前进、
  同边界接收、token 复用、错误排空及已排队后续 fence 的故障传播。
- 排序参考模型保留 generic、published、async 三个独立视图；不能通过直接读取
  全局最新字典值让缺失的发布/获取关系隐身。
- 线程集合测试由 32 个 thread packet 逐个到达，覆盖缺失/重复线程、非一致操作数、
  执行端 release、SIMT 完成背压和旧 epoch release。
- 真实 SMEM 集成中，TMA 与 mbarrier backing 接到 RTL SRAM；通用客户端通过硬件
  初始化和读回存储。暂停 SMEM 确认时 TMA load 不会提前完成。
- 真实存储测试覆盖 swizzle load/store、片上 reduction、mbarrier phase 等待，
  以及 store bulk-group `.read` 等待和完整等待的分离。
- 原有 TC commit 快照、空/重复 commit、TC arrival count=1、满软件 waiter 时 TC
  前进、旧 Tensor/TMEM、算术流水和所有 TMA/mbarrier 回归继续通过。

排序跟踪器与 warp 集合接口仍是待接入完整执行前端的模块。
真实 SMEM 集成测试的 GMEM 与 scope/proxy maintenance 是外部协议端点，
尚未证明全部产品命令路径的发布/获取集成。

## 综合结构

在已有 `openroad/orfs:latest` 镜像中运行 Yosys 0.64（git `6d2c445ae`），
镜像固定为 `sha256:e4e71714221bbabba09242c03d3c093af07f6231d4a76de17ecc6408061c6802`。
没有安装或修改共享工具环境。

`proc → opt → memory_dff → memory_share → memory_collect → opt_clean → check -assert`
之后，独立 netlist checker 检查实际 `$mem_v2` 单元：

| 配置 | 实际 banks | 每 bank | 物理容量 | 端口 |
|---|---:|---:|---:|---|
| TMEM | 128 | 128 × 128 bit | **262144 B** | 同步 1R1W |
| SMEM | 32 | 1824 × 32 bit | **233472 B** | 同步 1R1W |

所有 memory INIT 均为未指定值。此结果证明物理 SRAM 结构，
**不证明完整 TMEM 指令前端、整个子系统综合、技术 SRAM 宏映射或 PPA**。
已有 Yosys 镜像未提供 `read_slang`，没有把未完成的 SystemVerilog 全系统综合标为通过。

## 先前算术与控制基线

| Run ID | 配置 | 通过/执行 |
|---|---:|---:|
| `allegro-async-final-20260917-02` | 18 | 104/104 |
| `allegro-async-corners-20260917-01` | 4 | 4/4 |
| `allegro-async-numeric-20260917-03` | 1 | 6/6 |

此历史基线未修改算术 RTL。当时回归测得单 dot 的 FP16/BF16 32、TF32 16、
FP8/INT8/MXF8 64、MXF4/NVF4 128 operation/cycle；每类测量 4096 个稳态周期。
FMA 计 2 operation。当时尚无实例化并验收的 256-dot 阵列，不能把单 dot 数字乘 256
报告为已经达成的单 SM 计算吞吐。上方 2026-09-23 增量才单独验证了
256-dot FP16/BF16 阵列；它也不代表集成计算流水。此前 MMA-Sim 数值回归仍基于旧 inventory，
不能作为全部 PTX 9.4 指令或 SM100 实机的数值证明。

## 复现与剩余范围

远端独立源码目录中运行：

```sh
JOBS=16 make test-blackwell
# 使用已存在的 Yosys 容器镜像：
make synth-blackwell-sram
```

产物在 gitignored `build/blackwell/async_subsystem/`：
`smem-final-01/` 保存全量日志和 XML；`sram-synth-02/` 保存综合网表、日志和结构 JSON；
`smem-validation-summary.json`、`smem-implementation-manifest.json` 保存本次证据和源码哈希。
先前 `baseline.json`、`implementation-manifest.json` 等保留为历史基线，未改写成新一轮证据。

P0 完整合法性矩阵、P1 全执行前端接入、P2 完整 TMEM 指令与分配、
P3 将已验证阵列接入 collector/TMEM 并验收全链路、P4 全部精度及副作用、P5 TMA 并发/合并与性能收敛
仍有未实现或未验收项。完整流水 ≥85%、全部计算模式 ≥95%、TMA 有效 payload ≥90%
均不能由本记录中的 SMEM 测量替代。SM100 实机一致性仍明确记为**未验证**。
