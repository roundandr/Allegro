# SM100a 单 CTA 实现与验收矩阵

依据 **NVIDIA PTX ISA 9.4**、Tensor Map API，查阅日期 **2026-09-11**。
权威规则位于 [TMA spec](tma_spec.md) 和 [mbarrier spec](mbarrier_spec.md)。
本表目前只覆盖 **TMA 与 mbarrier**，不是整份计划要求的 TC/TMEM 全合法组合矩阵；
因此 P0 的全子系统合法性冻结尚未完成。TC/TMEM 的现有实现边界见
[实施记录](async_tensor_implementation.md) 和 [TMEM RF 合同](tmem_rf_execution_contract.md)。
本表区分模块实现、外部后端责任和范围外能力；同 CTA shared copy 特别标为项目扩展。
不包含 CUDA opaque 二进制兼容、物理多播网络或完整 GPU 前端/LSU。

官方来源：

- [P1：mbarrier对象与操作](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#parallel-synchronization-and-communication-instructions-mbarrier)
- [P2：tensor布局](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#tensor-tiled-mode)
- [P3：linear bulk copy](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#data-movement-and-conversion-instructions-cp-async-bulk)
- [P4：tensor copy与限制](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#data-movement-and-conversion-instructions-tensor-copy-restrictions)
- [P5：bulk-group](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#data-movement-and-conversion-instructions-cp-async-bulk-commit-group)
- [P6：linear reduction](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#data-movement-and-conversion-instructions-cp-reduce-async-bulk)
- [P7：tensor reduction](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#data-movement-and-conversion-instructions-cp-reduce-async-bulk-tensor)
- [P8：multimem copy/reduce](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#data-movement-and-conversion-instructions-multimem-cp-async-bulk)
- [P9：prefetch](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#data-movement-and-conversion-instructions-cp-async-bulk-prefetch)
- [P10：tensormap.replace](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#data-movement-and-conversion-instructions-tensormap-replace)
- [P11：tensormap.cp_fenceproxy](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#parallel-synchronization-and-communication-instructions-tensormap-cp-fenceproxy)
- [P12：memory model](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#memory-consistency-model)
- [D：Tensor Map API](https://docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__TENSOR__MEMORY.html)
- [G：设备端descriptor更新示例](https://docs.nvidia.com/cuda/cuda-c-programming-guide/#device-side-encoding-and-modification-of-a-tensor-map)

RTL缩写：B=[mbarrier core](../rtl/mbarrier/mbarrier_unit.sv)，BF=[barrier frontend](../rtl/mbarrier/mbarrier_frontend.sv)，
D=[data engine](../rtl/tma/tma_data_engine.sv)，A=[address/layout](../rtl/tma/tma_tensor_map.sv)，
M=[map control](../rtl/tma/tma_map_control.sv)，Q=[dispatcher](../rtl/tma/tma_engine.sv)。
测试均在[test_tma_mbarrier.py](../verification/cocotb/test_tma_mbarrier.py)，集成测试另行链接。

| 官方条款 | 合法组合 / 项目接口 | RTL | 对应测试 | 责任与状态 |
| --- | --- | --- | --- | --- |
| P1 对象 | b64、8B对齐、同行四个对象 | B | `mbarrier_objects_counts_tokens` | 实现 |
| P1 counts | v0 20-bit、v1 9-bit arrival；signed21 tx合法范围 | B | `mbarrier_extended_layout_lifecycle` | 实现 |
| P1 init/inval | 布局由init固定；正常复用先inval | B | `mbarrier_transaction_order_timeout_recovery` | 实现；程序生命周期由前端遵守 |
| P1 arrive | count减pending；返回操作前phase token | B | `mbarrier_objects_counts_tokens` | 实现 |
| P1 noComplete | 不得完成phase；合法release.cta | B/BF | `mbarrier_extended_layout_lifecycle` | 实现 |
| P1 drop | 永久减expected且不降为0；含noComplete/expect变体 | B | `mbarrier_extended_layout_lifecycle` | 实现 |
| P1 combined | expect后arrival/drop一次 | B | `mbarrier_transaction_order_timeout_recovery` | 实现 |
| P1 software tx | expect加、complete减，relaxed.cta/cluster | B/BF | `mbarrier_extended_layout_lifecycle` | 实现 |
| P1 token | 独立opaque编码；pending_count只接受v0 noComplete token | B | `mbarrier_extended_layout_lifecycle` | 实现；不解码NVIDIA对象 |
| P1 layout | CHECK_LAYOUT独立谓词 | B | `mbarrier_extended_layout_lifecycle` | 实现 |
| P1 test_wait | state/parity，非阻塞、失败无report | B/BF | `mbarrier_primary_conditional_reports` | 实现 |
| P1 try_wait | primary/conditional；有限hint时限 | B/BF | `mbarrier_transaction_order_timeout_recovery` | 实现 |
| P1 v1报告 | 当前与前一primary的8-bit report；conditional保持/推进 | B | `mbarrier_primary_conditional_reports` | 实现；OR聚合为项目生产者契约 |
| P1普通cp.async | issuer此前序号；arrive/noinc、空前缀 | BF | `ordinary_cp_async_prior_sequence_and_noinc` | 实现；普通LSU登记/完成为外部输入 |
| P1普通cp.async资源 | 登记与完成独立通道，乱序完成，表满可释放 | BF | `async_registration_capacity_and_independent_completion` | 实现 |
| P1/P12排序 | release先确认再更新；成功acquire先确认再返回 | BF | `mbarrier_ordering_acknowledgements` | 模块控制已实现；可见性由外部ack保证 |
| P2/D tiled | rank1..5、各宽度、stride1..8、维度2^32 | A/D | `tiled_ranks_widths_strides_oob` | 实现 |
| P2/P4方向/OOB | load填充、store非负坐标及尾部mask | A/D | `parameter_limits_and_invalid_combinations` | 实现 |
| P2 gather/scatter | rank2、四行、box1=1、无interleave | A/D | `v3_nvidia_format_golden`、`v3_packing_interleave_scatter` | 实现 |
| P2/D interleave | rank3..5、16/32B切片、32B swizzle组合 | A | `v3_packing_interleave_scatter`、`strong_copy_and_extended_layout_boundaries` | 实现；接口使用规范化C,W,H,D,N |
| P2 swizzle | 32/64/128，16/32/64 atom及合法flip8 | A | `swizzle_official_rows_and_roundtrip` | 实现 |
| P2 im2col | 3..5D、offset、traversal、halo/OOB | A | `im2col_spatial_wide_halo` | 实现 |
| P2 wide | w/w128，pixels/halo字节数、无interleave | A | `im2col_spatial_wide_halo`、GPU golden | 实现 |
| P2 im2col store | no_offs、lower≥0、upper≤0 | A/D | `im2col_spatial_wide_halo` | 实现 |
| P4/D dtype | 常规整数/浮点、TF32转换、FTZ属性 | A/D | `v3_nvidia_format_golden` | 实现；NaN编码选择单独标注 |
| P4 packed | b4x16/b4x16_p64/b6x16_p32/b6p2x16 | A/D | `v3_packing_interleave_scatter` | 实现；payload与padding分离 |
| P4 packed限制 | C维度/box/首坐标、32B地址、atom64 | A | `strong_copy_and_extended_layout_boundaries` | 实现 |
| P4 OOB-NaN | 仅浮点dtype；独立特殊填充 | D | `v3_nvidia_format_golden` | 实现；具体值有共同架构实测证据 |
| P3 linear | 16B地址/大小；含零长度 | D | `bulk_masks_shared_prefetch_and_release` | 实现 |
| P3 cp_mask | global store每16B重复mask | D | `bulk_masks_shared_prefetch_and_release` | 实现 |
| P3 ignore_oob | 本CTA load首尾0..15；被mask字节不访问 | D | `strong_copy_and_extended_layout_boundaries` | 实现；目标忽略字节置零为项目选择 |
| P3 relaxed.b128 | 16B自然对齐强访问、合法scope | D | `strong_copy_and_extended_layout_boundaries` | 属性与分段已实现；后端执行原子访问 |
| P3 shared copy | PTX要求目的CTA与源CTA不同 | D | `bulk_masks_shared_prefetch_and_release` | **同CTA操作仅项目扩展；标准跨CTA变体未实现** |
| P6 shared reduction | 本CTA目标、表列整数/位操作组合 | D | `typed_reduction_all_combinations_and_contention` | 校验/请求实现；后端逐元素原子执行 |
| P6 linear reduction | 完整合法type/op表、noftz/RNE属性 | D | `typed_reduction_all_combinations_and_contention` | 同上；禁止普通RMW替代 |
| P7 tensor reduction | tile/no_offs、合法类型、固定relaxed.gpu | A/D | `typed_reduction_all_combinations_and_contention` | 实现及外部原子契约 |
| P8 multimem | linear store/reduce、cp_mask/atomic128组合 | D/Q | `multimem_all_targets_and_order_failure` | 请求及完成跟踪实现；网络/全部目标确认由后端提供 |
| P9 prefetch | linear/tensor及load模式，不写SMEM/不通知barrier | A/D | `bulk_masks_shared_prefetch_and_release` | 提示请求实现；缓存可忽略 |
| P3/P9/D hints | cache policy与L2 promotion | D | `bulk_masks_shared_prefetch_and_release` | 传递实现；不增加同步 |
| P5 group | 多issuer、空组、多组、wait N、read | Q | `bulk_groups_read_visibility_and_issuers` | 实现 |
| P5 descriptor读取 | load只在group中跟踪descriptor读取 | Q/D | `descriptor_completion_and_invalidation` | 实现 |
| P5错误 | 已退休copy失败不能使覆盖它的wait返回成功 | Q | `multimem_all_targets_and_order_failure` | 项目故障记录，reset恢复 |
| P10/G replace | global/shared、所有字段、stride ordinal、独立atomicity | M | `descriptor_replace_publish_and_reread` | 实现；内部v3编码 |
| P11/G publish | 128B一次copy、写确认后release | M | `descriptor_replace_publish_and_reread` | 实现；warp到齐/一致性为前端前提 |
| P12 proxy | 带issuer/seq/scope/proxy/range请求确认 | D/M/BF | `descriptor_replace_publish_and_reread`、`mbarrier_ordering_acknowledgements` | 模块控制实现；可见性为外部责任 |
| 项目ABI迁移 | 删除旧代理和barrier-ID记分牌；Tensor只等自身工作 | 连接顶层 | [统一接口集成测试](../verification/cocotb/test_blackwell_integration.py) | 实现；保留256B实际搬运与计算依赖 |
| 项目backend契约 | 反压、延迟/乱序响应、原子竞争、部分多目标完成、错误 | D/B/BF/M/Q | 通道监视器及全部专项 | [独立参考后端](../verification/cocotb/blackwell_backend_ref.py) |

## 范围外与公开未定义行为

跨CTA SMEM、cluster multicast、`cta_group::2`按权威spec保留完整目标说明，不宣称实现。
SM107f/SM103a专属能力不泛化为SM100a。项目错误码、fault pinning、恢复方式及NaN payload
不是NVIDIA对非法程序的保证。未遵守对象生命周期、原子后端契约、warp前提或proxy发布的程序
不能通过当前模块“自动修正”。

## 验证记录

保留原有12配置的功能覆盖，另增小资源配置，现为13配置。
远端完整回归86项执行全部通过；末次descriptor维度边界修正后，相关测试在三组TMA配置中再次通过。
三个顶层lint通过。精确源码哈希、运行顺序、日志与静态核对见[验证记录](sm100a_validation.md)。

GPU共同子集：[原布局golden](../verification/cocotb/golden/nvidia_tma_sm120a.json)、
[格式golden](../verification/cocotb/golden/nvidia_tma_formats_sm120a.json)。生成器和source SHA保留，
不符合完成字节数的探测结果没有被当作golden。GPU为SM120a，不能替代SM100a目标限定。
