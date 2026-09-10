# TMA 与 transaction barrier RTL 语义映射

## 定位

本实现是依据公开专利语义独立设计的、可综合研究模型，不是 NVIDIA
私有 RTL 的逆向结果，也不声称复现其 ISA 编码、微架构周期或物理实现。
技术来源是 transaction barrier 专利 US20230289242A1 的 Fig. 5/7/8/9，
以及 tensor memory access 专利 US20230289304A1 的 Fig. 6/7/9。专利只作为
只读技术资料使用。

## 语义与 RTL 对应

| 公开语义 | 本实现 | 自主设计边界 |
| --- | --- | --- |
| transaction barrier 同时跟踪线程到达与异步 transaction | `mbarrier_unit` 的 remaining arrive count 与 signed 64-bit transaction balance | 256-bit backing-state 位布局是本项目定义 |
| expectation 与 completion 可有限乱序 | `EXPECT_TX`/`ARRIVE_EXPECT_TX` 减 balance，TMA `TX_COMPLETE` 加 balance | 使用二补码 balance 和显式溢出锁定 |
| 两个完成条件同时满足才推进 phase | phase 只在 remaining=0 且 balance=0 时翻转，并重装 expected | phase 为 1 bit，arrive token 必须匹配当前 phase |
| wait 使用旧 phase token | phase 已变化则立即响应，否则进入 32-entry wait CAM | CAM 唤醒采用按低索引、每周期一个响应 |
| barrier state 可由 memory-backed 同步单元缓存 | 4-entry 全相联非一致性 cache、8-entry write-through buffer | 替换为 round-robin；有 waiter 的行不可逐出 |
| tensor copy 由 descriptor 描述多维 tensor/box/traversal | 128-byte descriptor、1–5D iterator、signed 起始坐标 | descriptor 二进制布局和 version=1 是本项目 ABI |
| 地址由坐标与 byte stride 生成 | `base + sum(coord[d] * stride[d])` | 单 iterator/setup 流水线；dim0 连续段合并 |
| 异步数据搬运与 barrier completion 相连 | 最后一项 GMEM/SMEM 响应后才发送一次 logical-byte `TX_COMPLETE` | 16-entry line MSHR，命令按序、GMEM 响应按 ID 乱序 |
| 越界 load/store 有区别 | load 写零，store 跳过写入 | OOB 元素仍推进 logical byte count |

## 公开接口约束

- GMEM 是 128-byte 单 beat，SMEM 是 32-byte 单 beat。valid-ready 被阻塞时
  payload 必须保持稳定；仿真断言直接检查这一点。
- GMEM ID 0–15 用于 MSHR，ID 16 保留给 descriptor fetch。SMEM ID 的最高位
  标识 TMA 或 barrier backing-memory 来源，其余位保留原 source ID。
- descriptor pointer 必须 128-byte 对齐；SMEM base 和 barrier backing address
  必须 32-byte 对齐。tensor GMEM base/stride 必须满足元素宽度对齐。
- descriptor cache 非一致。`DESC_INV` 的地址为零时全局失效，否则仅失效匹配行。
- barrier backing memory 同样非一致，软件不能绕过同步单元修改状态。
- 每个接受的 TMA 或 barrier 命令最终恰有一个响应；排队的 `TRY_WAIT` 响应延迟到
  phase 翻转或 barrier 锁定。

## 错误与恢复

descriptor、地址或 backend 错误通过 status 返回。barrier 的重复旧-phase
arrival、计数下溢、transaction balance 溢出和 backing-memory 错误会锁定状态；
已排队 waiter 以 locked status 被唤醒。锁定后只有 `INIT` 可以重建状态。

## 与 Tensor Core/TMEM 子系统的边界

`blackwell_tma_mbarrier_top` 保留原 tensor core MMA/STORE/WAIT 行为。旧
`TMA_REQ` 被公平轮询适配器转换成 zero-extended GMEM source 到 SMEM
destination 的 256-byte `LOAD_LINEAR`，真实搬运完成后再按旧 tag、barrier ID
和请求 phase 生成 `tma_done`。完整 1–5D TMA 和 phase-token barrier 接口只在
新顶层公开；使用方负责连接外部 GMEM/SMEM 后端，本工程不包含真实 TileLink/L2
协议接入。

## 明确延期

本阶段不实现 im2col、constant fill、swizzle、prefetch、multicast、reduction、
CGA/远端 coalescer、CUDA/PTX 编码、真实 L2/TileLink 协议、CDC/RDC、SRAM macro
或 place-and-route/PPA。当前工程入口只提供独立 RTL lint 与功能回归。
