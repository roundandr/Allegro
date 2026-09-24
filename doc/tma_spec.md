# TMA：SM100a 语义、统一接口与实现规范

版本 v3；依据 NVIDIA PTX ISA **9.4** 与 Tensor Map API；查阅日期 **2026-09-11**。
本文件是工程 TMA 的唯一规范。公开规则是目标，测试通过不是公开语义的来源。
**[NV]** 官方规则，**[MAP]** 项目表示，**[RTL]** 实现，**[EXT]** 项目扩展，
**[OPEN]** 外部责任或公开未定义行为，**[TODO]** 范围外尚未实现能力。

## 1. 范围与结构

目标为 SM100a 的单 CTA 操作。外部 LSU/cache 承担原子执行、内存可见性和 multimem
物理路由；这些责任通过带属性的数据请求与独立排序确认表达，不能以普通写入代替。
跨 CTA SMEM、cluster multicast、`cta_group::2` 不执行，`multi_cta=1` 返回 UNSUPPORTED。
SM107f 的 report mechanism、override、32-bit multicast、eviction-priority prefetch，
以及 SM103a/SM107a 的 96B swizzle 不计入 SM100a。

| 层 | RTL | 职责 |
| --- | --- | --- |
| 命令与分组 | [`tma_engine`](../rtl/tma/tma_engine.sv) | issuer/tag、ticket、commit/wait/read、错误结果 |
| copy/map 分发 | [`tma_copy_engine`](../rtl/tma/tma_copy_engine.sv) | map 控制前排空此前数据操作、后端所有权 |
| 数据引擎 | [`tma_data_engine`](../rtl/tma/tma_data_engine.sv) | FIFO/cache/MSHR、有效字节、数据转换、独立完成事件 |
| 坐标与布局 | [`tma_tensor_map`](../rtl/tma/tma_tensor_map.sv) | tiled、interleave、swizzle、im2col、packing 地址 |
| descriptor 控制 | [`tma_map_control`](../rtl/tma/tma_map_control.sv) | replace、128B copy、proxy 发布和确认 |
| 公共 ABI | [`tma_mbarrier_pkg`](../rtl/common/tma_mbarrier_pkg.sv) | 命令、响应、后端属性、操作常量 |

**[EXT]** `COPY_SHARED` 提供同 CTA SMEM copy。PTX 的
`cp.async.bulk shared::cta→shared::cluster` 明确要求目标属于**不同 CTA**，因此此操作
是项目便利扩展，不能算作该 PTX 指令的合规实现。跨 CTA copy 仍未实现。
shared reduction 使用独立的 reduction 条款及其类型表；地址仍限制在本 CTA。

Tensor 只处理 MMA、STORE 和自己的 COMMIT/WAIT。调用方先通过 mbarrier 或 bulk-group
等待所需 TMA 数据，再提交 Tensor 计算。旧控制代理、barrier-ID 记分牌及双格式路径已移除。

## 2. 统一命令与响应

**[MAP]** `tma_cmd_t` 以 valid-ready 接受；`tma_rsp_t` 返回 issuer、tag、status、bytes。
每个接受的命令恰好一个诊断响应；不同命令可乱序返回。相同 issuer 的未完成命令使用不同 tag。
32-bit SMEM 地址已由前端验证属于本 CTA；global 地址为 64 bit。序号 `seq` 在活跃上下文内不回绕。

| opcode | 操作 | 完成机制 |
| --- | --- | --- |
| 0 / 1 | LOAD_TENSOR / STORE_TENSOR | mbarrier / bulk-group |
| 2 / 3 | LOAD_LINEAR / STORE_LINEAR | mbarrier / bulk-group |
| 4 | DESC_INV，地址零表示全部失效 | 诊断响应 |
| 5 / 6 | COMMIT_GROUP / WAIT_GROUP | 提交 / 等待该 issuer 的组 |
| 7 | COPY_SHARED，项目同 CTA 扩展 | mbarrier |
| 8 / 9 / 10 | REDUCE_LINEAR / REDUCE_TENSOR / REDUCE_SHARED | bulk / bulk / mbarrier |
| 11 / 12 | PREFETCH_LINEAR / PREFETCH_TENSOR | 无数据同步完成 |
| 13 / 14 / 15 | MAP_REPLACE / MAP_CP_FENCE / FENCE_PROXY | 更新 / 发布确认 / 排序确认 |

`completion` 为 0 mbarrier、1 bulk、2 none；合法数据方向必须选择对应完成机制。
`coord` 含五个 s32，普通 tensor 使用 rank 个；gather/scatter 使用 `{col,row0,row1,row2,row3}`。
`mode`：0 tile、1 im2col、2 im2col::w、3 im2col::w::128、4 im2col_no_offs、5 gather4、6 scatter4。
`im2col` 依次打包三个 u16 offset W/H/D、u16 halo、u16 wOffset，未用项忽略。

| 其他字段 | 意义 |
| --- | --- |
| desc_ptr、smem_addr、linear_addr、linear_bytes、barrier_addr | descriptor、SMEM、linear 对端、长度及对象地址 |
| issuer[9:0]、tag[15:0]、seq[63:0] | CTA 内线程、响应关联、排序序号 |
| dtype[3:0]、reduce_op[3:0] | linear reduction 类型/操作；tensor 类型来自 descriptor |
| cp_mask_enable、cp_mask[15:0] | linear store 每个16B块的字节选择 |
| ignore_oob、oob_start/end[3:0] | linear load 首尾忽略字节；前端须先验证 PTX u32 原操作数 |
| atomic128、scope | copy 的 weak 或 relaxed.b128 后端契约；reduction 另有逐元素原子属性 |
| multimem | linear store/reduce 的多目标地址；全部目标确认由后端负责 |
| wait_n、wait_read | 最近 N 个已提交组可保留；read 仅等待读取完成 |
| sem、scope、from_proxy、to_proxy | 排序控制；0 relaxed、1 release、2 acquire；scope=CTA/cluster/GPU/SYS |
| cache_hint、cache_policy | 可忽略的 L2 提示；不增加同步语义；multimem 无此 qualifier |
| map_shared、replace_field/ord/value、warp_converged | descriptor 修改及已由前端证明的 warp 前提 |

诊断 `bytes` 为逻辑 payload：不含 packed padding、swizzle 空隙、总线读取放大；OOB store
被跳过的逻辑元素仍在诊断长度内。prefetch、map 控制和 group 命令返回零。
错误 status 与任何标准完成谓词分开，不能将失败响应当成完成信号。

## 3. 项目内部 128B v3 descriptor

**[MAP]** 小端、64B 对齐；跨128B总线行时分两次读取。只执行 v3，拒绝 v1/v2。
这是公开属性的内部表示，**不是 CUDA opaque Tensor Map 的二进制布局**。
编码器为 [`TensorDescriptor.encode`](../verification/cocotb/tma_mbarrier_ref.py)。

| 位 | 字段 |
| --- | --- |
| 7:0 / 10:8 / 13:11 | version=3 / rank−1 / 保留零 |
| 15:14 / 79:16 | kind：tile0、im2col1、wide2 / global base |
| 239:80 | 五个 u32 globalDim−1，表示范围1..2^32 |
| 559:240 | 五个 u64 stride；非interleave的dim0隐含，由dtype决定；interleave的slot0为C外层stride |
| 639:560 / 719:640 | 五个 u16 boxDim / traversal |
| 723:720 / 725:724 | swizzle mode 0/32/64/128B；128B atomicity 16/32/32+flip8/64B |
| 735:726 | 保留零 |
| 783:736 / 831:784 | signed16 lower / upper W/H/D |
| 847:832 / 863:848 | channelsPerPixel / pixelsPerColumn |
| 867:864 / 869:868 / 870 | dtype / interleave none/16/32B / zero或OOB-NaN fill |
| 872:871 / 873 / 879:874 | L2 promotion / cache hint / 保留零 |
| 943:880 / 1023:944 | cache policy / 保留零 |

swizzle mode 与 atomicity 分别存储，replace 一个字段不意外重置另一个字段。
未使用维度由编码器清零。合法性检查在执行端；编码器允许表示负向测试用的非法组合。

## 4. 坐标、格式与字节布局

**[NV/MAP]** 普通坐标按 C,W,H,D,N 的最快维在前顺序，rank 为1..5。
维度范围1..2^32，box范围1..256，traversal范围1..8；非interleave的第一个 traversal 被忽略。
普通 tiled 对 dim d 访问 `ceil(box[d]/step[d])` 个位置，dim0连续。
base至少16B对齐，较高维stride为16B倍数且小于2^40，并容纳前一维；
inner box和起始box地址满足16B约束。使用加宽乘加检查溢出。
load 的负/超界坐标填充；store 的各起始坐标必须非负，尾部超界跳过写入。
gather/scatter仅rank2、box[1]=1，无interleave；四个行坐标分别检查。

### 4.1 dtype 与 packing

类型编码沿用 PTX `tensormap.replace` 的属性值，**不同于 CUDA enum**。

| dtype | 类型 | payload / 布局 |
| --- | --- | --- |
| 0,1,2,3,4,5 | u8,u16,u32,s32,u64,s64 | 1/2/4/4/8/8字节，位保持 |
| 6,7,8,9,10 | f16,f32,f32.ftz,f64,bf16 | 常规宽度；copy不进行算术 |
| 11,12 | tf32、tf32.ftz | load对FP32执行TF32转换；4B存储 |
| 13 | b4x16 | 每16元素8B，无组间padding |
| 14 | b4x16_p64 | 每16元素8B payload、16B SMEM容器；仅load |
| 15 | b6x16_p32 load / b6p2x16 store | load每16元素12B payload、16B容器；store每字节取低6bit，重新紧密打包 |

**[RTL]** TF32转换为 RNE，处理指数进位和NaN。保存的SM120a golden验证两种TF32变体；
f32.ftz的copy位保持，FTZ不被误用为任意字节copy时清除subnormal。
带FTZ的tensor reduction把dtype传给后端，由对应算术契约处理。
**[OPEN]** NaN payload编码不是跨实现的额外保证；项目转换选用`0x7fffe000`。
特殊OOB填充对浮点类型使用重复16-bit `0x7ff7`，有GPU golden证据；不把它当普通 quiet NaN。
整数/packed选择此填充非法。

dtype13的C维度为偶数；dtype14/15的C维度为128倍数、inner box/channels=128，
base与较高维stride至少32B对齐。dtype14/15允许none或128B/atom16、atom32、atom64；首个坐标必须为128的倍数。dtype15无interleave。所有限制与模式/方向联合检查。
SMEM padding不计入mbarrier transaction bytes，填充空隙的保留是项目写mask行为，不能当作NVIDIA保证。

### 4.2 Interleave

**[NV]** 16/32B的C切片布局，仅rank3..5，无wide im2col；最后不足的C切片按零补齐。
32B interleave要求base/stride32B对齐，并与32B swizzle组合。
**[MAP]** v3保持逻辑C,W,H,D,N坐标；`K=slice_bytes*8/element_bits`。
地址由 `floor(C/K)*stride[0] + (C mod K)*element_bits/8 + sum(spatial*stride)` 给出。
SMEM次序为C-inner、W/H/D、C-outer、N；逻辑C起点为K的倍数，C方向traversal选择切片，partial slice补齐。
普通im2col将每像素的channels扩至完整切片，空间cursor规则不变。
CUDA API的interleave数组需由前端转换为此逻辑约定；GPU golden只使用有明确转换的单C切片例子，
不从opaque编码推导接口字段，不把未公开的数组编码细节当作硬件规范。

### 4.3 im2col 与 swizzle

rank3/4/5对应NWC/NHWC/NDHWC。空间区间为`[lower[d],size[d]+upper[d])`，
corner分别用signed16/8/5bit范围，运行时offset为unsigned16/8/5bit。
channels为1..256，pixels为1..1024；空间traversal不减少pixels。
cursor逐W/H/D进位再进N，加入运行时offset后判断OOB；SMEM为pixel-major/channel-minor。
`im2col_no_offs`用于store，lower非负、upper不正，起始坐标非负。

wide仅遍历W/N，H/D固定。wOffset=0..31，同时平移W边界和起点。
W模式halo=0..511，payload为`(pixels+halo)*channels`个元素；
W128模式halo=0..31，在128主像素后追加四组halo，第g组从像素`(g+1)*32`开始。
wide要求swizzle且不允许flip8；Driver Wide encoder可编码集合与内部属性组合分别说明，
不能从项目表示反推CUDA opaque格式。

swizzle以绝对SMEM地址a为输入，base offset参与计算：
`a' = a XOR (((a/128) mod (span/atom))*atom)`；flip8在奇数row再XOR8。
32/64B span用16B atom；128B支持16/32/64及32+flip8。
atom32/64要求对应SMEM基址对齐；flip8仅load且不用于wide。
inner payload先按span扩展行距，再执行置换；padding不产生虚假完成字节。

## 5. 完成域、线程与内存顺序

load/shared reduction成功后执行mbarrier complete_tx，expect/arrival由调用方独立提供。
store/reduce global使用bulk-group，**不更新mbarrier**。每issuer保留当前组序号；
COMMIT允许空组；WAIT N排除最新N个已提交组和未提交组。
`.read`只等待源读取，普通wait等待目标写入与排序确认。tensor load的group仅跟踪descriptor读取。
读取完成是所有对应读取响应均已收到；后续目标写入可以继续等待。

**[RTL]** 控制ticket与copy解耦，保留控制资源；乱序memory response按ID匹配。
复制错误不会发出成功mbarrier通知。分组错误按issuer保留到上下文reset；
已消费错误copy响应后，后续覆盖该组的wait仍返回错误，不能“遗忘失败”。
这是项目恢复策略，不是PTX对错误程序的保证。序号耗尽前drain/reset，组号不允许静默回绕。

### 5.1 数据后端

GMEM为128B、SMEM为32B带ID请求/响应。**读写都必须遵守byte mask**：
未选中的字节不访问，读结果未选中字节返回零。特别是ignore_oob不能先越界读整行再丢弃数据。
读取ID在响应前不重用；请求payload及属性在反压期间保持稳定。

`bw_mem_attr_t`携带kind(read/write/reduce/prefetch)、dtype、reduce_op、multimem、atomic128、
issuer、seq、scope、proxy、cache hint/policy、L2 promotion。
reduction写请求必须在所选scope内逐元素原子执行，不能翻译成普通读加普通写。
atomic128 copy要求自然对齐的16B强访问；byte mask只选择该原子单位内合法字节。
multimem成功写响应代表**所有目标**完成，部分目标完成不能提前确认；`.read`仍仅代表源已读完。
prefetch允许后端忽略，确认不表示SMEM数据可用，也不建立同步。

### 5.2 排序后端与前端职责

`bw_order_req_t`带id、issuer、seq、kind、scope、from/to proxy、addr、bytes。
release确认必须覆盖该issuer相应proxy中此前操作的发布，**不能只对barrier的8B地址做空操作**。
acquire确认建立相应scope的可见性，前端在成功响应前不得发出依赖读取。
barrier地址标识同步对象；tensor非连续范围用addr=bytes=0表示该序号覆盖的全部地址。
proxy fence的非零范围约束descriptor发布/获取对象。外部缓存和LSU负责兑现此契约。

TMA数据引擎收到全部目标确认后，再等待async→generic release确认，才执行complete_tx或返回完整完成。
map发布确认前后续copy不能越过map控制。mbarrier自身release/acquire见其权威规范。
对象init发布、线程间同步、地址空间验证、warp到齐和操作数一致性仍由前端负责。
模块不提供通用LSU/cache、跨CTA路由或部分写入回滚。

## 6. Reduction、linear 和 descriptor 控制

### 6.1 合法 reduction 组合

| 操作 | shared目的 | linear global / multimem | tensor global |
| --- | --- | --- | --- |
| add | u32,s32,u64 | u32,s32,u64,f16,bf16,f32,f64 | 同左但无f64；支持descriptor的f32.ftz属性 |
| min/max | u32,s32 | u32,s32,u64,s64,f16,bf16 | 同左 |
| inc/dec | u32 | u32 | u32 |
| and/or/xor | b32 | b32,b64 | b32,b64 |

项目b32/b64按u32/u64的位宽编码。reduction为relaxed；tensor固定GPU scope；
shared scope限制CTA/cluster。浮点add采用RNE，linear f16/bf16保留subnormal，对应noftz；
linear f32默认同样保留。参考后端用独立精确分数舍入检查，RTL负责合法性、请求与确认，不做非原子的RMW。

linear地址/大小为16B粒度，零长度合法并正常终结。
cp_mask只用于linear store，16位mask在每16B块重复。
ignore_oob只用于global→本CTA shared；首尾各0..15字节。公开规则允许目标忽略字节值不确定，
项目确定性地置零，不把该选择写成NVIDIA保证。

### 6.2 Tensor Map 更新与发布

MAP_REPLACE修改global或shared中的完整内部128B记录，先读取再更新指定字段并写回。
字段编号：0 global_address、1 rank、2 box_dim、3 global_dim、4 global_stride、5 element_stride、
6 elemtype、7 interleave、8 swizzle_mode、9 atomicity、10 fill。
rank使用零基数；global_dim的u32零值映射为2^32（内部存储减一后的0xffffffff）；ord=0..4；global_address/stride为u64，其余为u32语义，非法值拒绝。
普通global_stride的ord=0对应dim1，内部存储slot为(ord+1)%5；ord4使用非interleave时的备用slot0。
interleave输入由前端规范化到本文C,W,H,D,N约定，C外层stride通过slot0表示，不能直接照抄CUDA数组。
这一映射对应[CUDA官方设备端更新例子](https://docs.nvidia.com/cuda/cuda-c-programming-guide/#device-side-encoding-and-modification-of-a-tensor-map)中独立于global_dim的stride编号。
字段检查和最终descriptor组合检查分开；连续replace可先形成中间状态，正式copy再检查组合。
它是generic-proxy弱操作，调用方不得与其他修改者竞争。

MAP_CP_FENCE在`warp_converged=1`前提下只执行一次shared→global 128B copy，
等待全部写确认，再请求generic→tensormap release。scope由命令指定。
FENCE_PROXY表示后续proxy acquire/release；消费者在确认后才读取新map。
控制结束时descriptor cache失效，后续读取重新访问后端。失败只报告失败，不回滚已写的部分记录。

## 7. 错误与验证

status：00成功；20 opcode；21 descriptor对齐；22 descriptor参数；23 rank；24类型；
25 SMEM对齐；26溢出；27不支持组合；28排序失败；30 GMEM；31 SMEM；32 mbarrier；3f内部协议。
错误会排空已发数据事务且不发成功completion；外部系统负责停止非法后续依赖并恢复上下文。

完整的“官方条款→合法组合→接口→RTL→测试”见
[实现验收矩阵](sm100a_implementation_matrix.md)。验证状态以其记录为准。
`make test-blackwell`在配置远端CPU执行三个顶层lint与回归；产物位于忽略的`build/blackwell/`。
GPU只验证SM120a与目标的共同子集；保存的golden及生成器不代表SM100a硬件完整认证。
### 1.1 cluster、multicast 与 CTA-pair 的完整目标契约

本节全部为 **[NV/TODO]**，当前 RTL 不执行。依据 S3 的方向、completion 与 CTA-group 条款：

| 操作 | 数据目的地 | barrier / 完成对象 |
| --- | --- | --- |
| linear global→shared::cluster | 指定 CTA 的 DSMEM | 目标 CTA 的 mbarrier，按 copy bytes 完成 |
| linear shared::cta→shared::cluster | 本 CTA SMEM 到远端 DSMEM | 远端 mbarrier；不能替换成 store bulk-group |
| tensor global→shared::cluster、group 1 | 指定 CTA 的 DSMEM | mbarrier 与目的数据在同一 CTA |
| tensor global→shared::cluster、group 2 | 指定 CTA 的 DSMEM | mbarrier 可在目的 CTA 或其 peer CTA |
| multicast group 1 | mask 每个选中 CTA 的同一 CTA-relative SMEM offset | 每个目的 CTA 的同一 mbarrier offset 各接收 completion |
| multicast group 2 | mask 每个选中 CTA 的同一 SMEM offset | 每份 completion 路由到该 CTA-pair 中、与 mbar 地址所在 CTA rank 奇偶性相同的成员 |

CTA-pair 按官方相邻偶/奇 cluster rank 配对。group 2 并不表示隐式复制两份数据；
copy 的目的地仍由地址和 mask 指定，改变的是允许的 completion 路由。
同一 pair 的两个目的 CTA 都被选中时，选定 barrier 要分别记账两份数据的完成字节，
不能把两份通知去重。默认 group 为 1。

SM100a multicast 使用 16-bit mask，bit k 表示 cluster rank k；无效/不存在的 CTA
不能作为合法目的地。PTX 9.4 的 32-bit multicast/report 变体有 SM107f 限制，
不作为 SM100a 的扩展实现目标。每个目的 CTA 必须先建立 SMEM/barrier 生命周期，
在所有远端访问完成前保持存活；cluster 同步建立这些前提，TMA 本身不启动或保活 CTA。

copy 为 weak memory operation；其 mbarrier complete-tx 具有 release.cluster 语义。
成功 acquire wait 与 release 配合才建立规定的跨 CTA 可见性，mask 广播不能代替同步。
未来项目接口须增加 CTA 路由、16-bit mask、group 选择与独立目标 barrier 身份；
目前用 `multi_cta=1` 明确拒绝这些请求，不会静默执行成本地 copy。

## 10. 引用与非规范性架构参考

- **S1** [PTX 9.4 — Tensor-map](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#tensor-tensormap)。
- **S2** [PTX — Tiled、im2col、swizzle](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#tensor-tiled-mode)。
- **S3** [PTX — cp.async.bulk.tensor](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#data-movement-and-conversion-instructions-cp-async-bulk-tensor)，同章含 linear、reduction 和 prefetch。
- **S4** [PTX — bulk completion](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#data-movement-and-conversion-instructions-cp-async-bulk-commit-group)。
- **S5** [PTX — Memory Consistency Model](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#memory-consistency-model)。
- **S6** [CUDA Driver API — Tensor Memory](https://docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__TENSOR__MEMORY.html)。
- **S7** [本工程 mbarrier 规范](mbarrier_spec.md)。
- **S8** [PTX — Tensor copy restrictions](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#data-movement-and-conversion-instructions-tensor-copy-restrictions)。
- **S9** [PTX — Tensor copy instruction families](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#data-movement-and-conversion-instructions-tensor-copy)。

在线 NVIDIA 页面可能更新；以上版本与查阅日期限定本次审查。

以下专利仅解释 descriptor cache、请求生成和完成跟踪的架构来源，不替代 S1–S6 的公开指令语义：
[US20230289304A1](https://patents.google.com/patent/US20230289304A1/en)。

![Descriptor 与请求组织，Fig.6](images/tma_mbarrier/tma_patent_fig6.png)
![Tensor/box/traversal，Fig.7A](images/tma_mbarrier/tma_patent_fig7a.png)
