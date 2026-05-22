# mbarrier：内存屏障机制说明书

mbarrier 是位于 `Shared Memory` 内的同步对象，用于协调多个 warp 在流水线中的生产与消费。相比于 `async_group` 机制，mbarrier不仅可以做 `CTA` 级别的同步，还可以实现 `Cluster` 级别的同步

--- 

## 1. mbarrier 功能

* 初始化 `期待的事件数（expected arrival count）` `期待的字节数（expected_tx）`
* 在 TMA 完成一定字节的传输时更新计数器
* 翻转 phase（0→1 或 1→0）
* 唤醒所有 `test_wait` / `try_wait` 的 warp

--- 

## 2. mbarrier 对象概述

软件视角：mbarrier 是存放在 SMEM 中的 64-bit 对象。
硬件将其解码为如下字段（内部表示）：

| 字段名              | 位宽    | 说明                    |
| ---------------- | ----- | --------------------- |
| `phase`          | 1     | 当前 phase（0/1），每完成一轮翻转 |
| `Expected arrival count`    | 21    | 期待到达的事务计数        |
| `Pending arrival count` | 21    | 剩余未完成的事务计数      |
| `tx-count`   | 21 |  期待的传输字节计数       |

> 说明：count皆为其相反数补码，例：期待到达的事务计数为2， 则Expected arrival count存入-2的补码。目的是后续每到达一个事务走的是加法通路，而非减法。

---

## 3. 指令行为规范

### Instruction-Level µop for mbarrier.xxx

| 指令                         | 微操作                           |
| --------------------------- | -------------------------------- |
| `mbarrier.init`             | 写入 expected arrival count，phase=0，tx=0 |
| `mbarrier.arrive(.noComplete)` | pending arrival count ++   |
| `mbarrier.arrive_drop(.noComplete)`      | expected arrival count ++  |
| `mbarrier.expect_tx`        | 写入 expected_tx 字节数      |
| `mbarrier.complete_tx`      | txCount ++      |
| `mbarrier.test_wait`        | 检查该阶段是否完成，若未完成返回 false  |
| `mbarrier.try_wait`         | 检查该阶段是否完成，若未完成返回 false, 并挂起 warp|
| `mbarrier.pending_count`    | 读 arrival_count / expected_count |


> 说明：mbarrier.init 写入的 expected_arrival_count 是其相反数的补码，因此后续执行mbarrier.arrive 是 pending arrival count ++ 而不是 -- 

以下为抽象行为，具体 ISA 编码由架构定义。

### 3.1 `mbarrier.init(addr, count)`

1. 构建 64-bit mbarrier 对象：
   * `phase = 0`
   * `Expected arrival count = (-count)two’s complement`
   * `Pending arrival count = (-count)two’s complement`
   * `tx-count = 0`
3. 向 SMEM 发出写请求，将 mbarrier 写入 addr

### 3.2 `mbarrier.arrive(.noComplete)(state, addr, count)`

1. 向 SMEM 发起读请求，读取位于 addr 的 mbarrier；
2. `Pending arrival count += count`
3. 若未指定`.noComplete`，且满足
`Pending arrival count == 0 && tx-count == 0`
则 `phase flip`，并将 Pending arrival count 重置为 Expected arrival count，同时根据 mbarrier 等待表中的条目，向对应 sub-core 的 warp scheduler 发送唤醒请求；
4. 向 SMEM 发起写请求，将更新后的 64-bit mbarrier 写回 addr；
5. `state` 是 arrive 事件返回的状态快照，将更新后的 64-bit mbarrier 写回 state 寄存器。

### 3.3 `mbarrier.arrive.drop(.noComplete)(state, addr, count)`

1. 向 SMEM 发出读请求，读取位于 addr 的 mbarrier
2. `Pending arrival count += count`、`Expected arrival count += count`
3. 若未指定`.noComplete`，且满足
`Pending arrival count == 0 && tx-count == 0`
则 `phase flip`，并将 Pending arrival count 重置为 Expected arrival count，同时根据 mbarrier 等待表中的条目，向对应 sub-core 的 warp scheduler 发送唤醒请求；
4. 向 SMEM 发起写请求，将更新后的 mbarrier 写回 addr；
5. `state` 是 arrive 事件返回的状态快照，将更新后的 64-bit mbarrier 写回 state 寄存器。

### 3.4 `mbarrier.expect_tx(addr, txCount)`

1. 向 SMEM 发出读请求，读取位于 addr 的 mbarrier
2. `tx-count = (-txCount)two’s complement`
3. 向 SMEM 发出写请求，将已更新的 mbarrier 写入 addr

### 3.5 `mbarrier.complete_tx(addr, txCount)`

1. 向 SMEM 发出读请求，读取位于 addr 的 mbarrier
2. `tx-count = (-txCount)two’s complement`
3. 若 `Pending arrival count == 0 && tx-count == 0` 则 `phase flip`、`Pending arrival count = Expected arrival count`，并根据 mbarrier 等待表中的记录条目向对应 sub-core 的 warp scheduler 发起唤醒请求
4. 向 SMEM 发出写请求，将已更新的 mbarrier 写入 addr

### 3.6 `mbarrier.test_wait(waitComplete, addr, state)`
1. 向 SMEM 发出读请求，读取位于 addr 的 mbarrier；
2. `waitComplete = state(phase) != phase`，注：`(state(phase) != phase)` 表示前一个 arrive 操作的快照中的 phase 跟此次查询到 phase 不一样，代表着前一个 phase 已完成；
3. 将 waitComplete 写回对应 sub-core 的寄存器。

### 3.7 `mbarrier.try_wait(waitComplete, addr, state)`
1. 向 SMEM 发出读请求，读取位于 addr 的 mbarrier；
2. `waitComplete = state(phase) != phase`，注：`(state(phase) != phase)` 表示前一个 arrive 操作的快照中的 phase 跟此次查询到 phase 不一样，代表着前一个 phase 已完成
3. 若 mbarrier 未完成，即 `state(phase) == phase`，则向对应 sub-core 的 warp scheduler 发起挂起请求；
3. 将 waitComplete 写回对应 sub-core 的寄存器。

### 3.8 `mbarrier.pending_count(count, state)`
1. 解析 `state` 快照保留的 `Pending arrival count`
2. 将 `Pending arrival count` 写回 count 寄存器
---

## 4. mbarrier 典型用例：

```
// Example 1a, thread synchronization with test_wait:

.reg .b64 %r1;
.shared .b64 shMem;

mbarrier.init.shared.b64 [shMem], N;  // N threads participating in the mbarrier.
...
mbarrier.arrive.shared.b64  %r1, [shMem]; // N threads executing mbarrier.arrive

// computation not requiring mbarrier synchronization...

waitLoop:
mbarrier.test_wait.shared.b64    complete, [shMem], %r1;
@!complete nanosleep.u32 20;
@!complete bra waitLoop;

// Example 1b, thread synchronization with try_wait :

.reg .b64 %r1;
.shared .b64 shMem;

mbarrier.init.shared.b64 [shMem], N;  // N threads participating in the mbarrier.
...
mbarrier.arrive.shared.b64  %r1, [shMem]; // N threads executing mbarrier.arrive

// computation not requiring mbarrier synchronization...

waitLoop:
mbarrier.try_wait.relaxed.cluster.shared.b64    complete, [shMem], %r1;
@!complete bra waitLoop;


// Example 2, thread synchronization using phase parity :

.reg .b32 i, parArg;
.reg .b64 %r1;
.shared .b64 shMem;

mov.b32 i, 0;
mbarrier.init.shared.b64 [shMem], N;  // N threads participating in the mbarrier.
...
loopStart :                           // One phase per loop iteration
    ...
    mbarrier.arrive.shared.b64  %r1, [shMem]; // N threads
    ...
    and.b32 parArg, i, 1;
    waitLoop:
    mbarrier.test_wait.parity.shared.b64  complete, [shMem], parArg;
    @!complete nanosleep.u32 20;
    @!complete bra waitLoop;
    ...
    add.u32 i, i, 1;
    setp.lt.u32 p, i, IterMax;
@p bra loopStart;


// Example 3, Asynchronous copy completion waiting :

.reg .b64 state;
.shared .b64 shMem2;
.shared .b64 shard1, shard2;
.global .b64 gbl1, gbl2;

mbarrier.init.shared.b64 [shMem2], threadCount;
...
cp.async.ca.shared.global [shard1], [gbl1], 4;
cp.async.cg.shared.global [shard2], [gbl2], 16;

// Absence of .noinc accounts for arrive-on from prior cp.async operation
cp.async.mbarrier.arrive.shared.b64 [shMem2];
...
mbarrier.arrive.shared.b64 state, [shMem2];

waitLoop:
mbarrier.test_wait.shared::cta.b64 p, [shMem2], state;
@!p bra waitLoop;

// Example 4, Synchronizing the CTA0 threads with cluster threads
.reg .b64 %r1, addr, remAddr;
.shared .b64 shMem;

cvta.shared.u64          addr, shMem;
mapa.u64                 remAddr, addr, 0;     // CTA0's shMem instance

// One thread from CTA0 executing the below initialization operation
@p0 mbarrier.init.shared::cta.b64 [shMem], N;  // N = no of cluster threads

barrier.cluster.arrive;
barrier.cluster.wait;

// Entire cluster executing the below arrive operation
mbarrier.arrive.release.cluster.b64              _, [remAddr];

// computation not requiring mbarrier synchronization ...

// Only CTA0 threads executing the below wait operation
waitLoop:
mbarrier.try_wait.parity.acquire.cluster.shared::cta.b64  complete, [shMem], 0;
@!complete bra waitLoop;
```

---

## 5.硬件支持
### 5.1 MBMU（mbarrier Manage Unit）硬件顶层架构

![顶层架构](TMA&MBMU.drawio.png)

MBMU 是位于 **SM层级** 的专用同步管理单元，负责：

* 执行所有 `mbarrier.xxx` 指令；
* 维护 mbarrier 等待表；
* 协调 TMA、SMEM 与 Warp Scheduler 之间的同步关系。

其总体由以下 6 个核心模块组成：

1. **mbarrier 指令仲裁器（Instruction Arbiter）**
2. **指令执行逻辑（Execution Logic）**
3. **mbarrier 等待表（Wait Table）**
4. **TMA 接口（TMA Interface）**
5. **Warp Scheduler 接口（Scheduler Interface）**
6. **SMEM 读写接口（SMEM Interface）**
7. **指令发射接口（Issue Interface）**
8. **写回接口（Writeback Interface）**

### 5.2 mbarrier 指令仲裁器（Instruction Arbiter）

功能：

* 接收来自多个 sub-core 的 `mbarrier.xxx` 指令请求；
* 对同一周期内的多个 mbarrier 访问进行：

  * 端口仲裁
  * 地址冲突检测
* 保证：

  * 同一个 mbarrier 对象在一个时刻只被一个执行实例修改；
  * arrive / complete / expect_tx 等更新操作的顺序一致性。

仲裁策略可采用：
* 固定优先级（实现成本低）

### 5.3 指令执行逻辑（Execution Logic）

该模块是 MBMU 的核心 FSM，负责完成第 4 节中定义的所有“抽象行为”，包括：

* `init`：构造 64-bit mbarrier 初始值；
* `arrive / arrive_drop`：

  * 更新 `Pending arrival count`
  * 更新 `Expected arrival count`
  * 判定 phase flip 条件；
* `expect_tx / complete_tx`：

  * 更新 `tx-count`
  * 参与 phase flip 判定；
* `test_wait / try_wait`：

  * 对比 `state.phase` 与当前 `phase`；
* `pending_count`：

  * 解析 state 快照中的 pending 字段。

该执行逻辑内部包含：

* 加法器（用于补码计数的加法运算）
* 比较器（`Pending arrival count == 0 && tx-count == 0`）
* phase 翻转逻辑（1-bit 取反）
* 状态快照打包逻辑（构造返回的 `state`）

### 5.4 mbarrier 等待表（Wait Table）

mbarrier 等待表用于记录所有因 `mbarrier.try_wait` 而被挂起的 warp 信息，其维护字段包括：

| 字段          | 说明              |
| ------------ | --------------- |
| warp_id      | 被挂起的 warp 编号    |
| barrier_addr | 等待的 mbarrier 地址 |
| phase        | 等待的目标 phase     |
| sub-core id  | 该 warp 所属的调度分区  |

行为规则：

* 当 warp 执行 `try_wait` 且未完成时：
  * 其`warp_id` `sub-core_id`被插入等待表；
* 当发生 `phase flip` 时：
  * MBMU 遍历等待表；
  * 对所有 `barrier_addr 匹配 & phase 匹配` 的条目触发唤醒。

---

### 5.5 TMA 接口（TMA Interface）

| 接口名称 | 位宽 | 说明 |
| --- | --- | --- |
| `tma_complete_tx_valid` | 1 | TMA 发起一次异步完成更新请求 |
| `tma_complete_tx_addr` | `SMEM_ADDR_W` | 目标 mbarrier 在 SMEM 中的地址 |
| `tma_complete_tx_count` | 21 | 本次完成的传输字节数，等效映射为一次 `mbarrier.complete_tx` |
| `tma_complete_tx_ready` | 1 | MBMU 可接受来自 TMA 的更新请求 |

该路径保证异步 DMA 传输与 warp 同步逻辑在同一 mbarrier 对象上正确汇合，且 `tx-count` 与 `Pending arrival count` 共同参与 phase flip 判定。

---

### 5.6 Warp Scheduler 接口（Warp Scheduler Interface）

| 接口名称 | 位宽 | 说明 |
| --- | --- | --- |
| `sched_sleep_valid` | 1 | `try_wait` 未完成时请求调度器挂起 warp |
| `sched_sleep_warp_id` | `WARP_ID_W` | 需要挂起的 warp 编号 |
| `sched_sleep_reason` | `WAIT_REASON_W` | 挂起原因，固定为 `MBARRIER` |
| `sched_wake_valid` | 1 | phase flip 后请求调度器唤醒 warp |
| `sched_wake_warp_id` | `WARP_ID_W` | 需要唤醒的 warp 编号 |
| `sched_wake_subcore_id` | `SUBCORE_ID_W` | 目标 warp 所属调度分区 |

该接口覆盖两类行为：一是 `mbarrier.try_wait` 未完成时将 warp 从 READY 队列移出并置为 `SLEEP`；二是在 `Pending == 0 && tx == 0` 导致 phase flip 后，将匹配等待项的 warp 从 `SLEEP` 恢复到 `READY`。

---

### 5.7 SMEM 读写接口（SMEM Interface）

| 接口名称 | 位宽 | 说明 |
| --- | --- | --- |
| `smem_req_valid` | 1 | 发起一次 mbarrier SMEM 访问请求 |
| `smem_req_addr` | `SMEM_ADDR_W` | 目标 mbarrier 地址 |
| `smem_req_write` | 1 | 1 表示写，0 表示读 |
| `smem_req_wdata` | 64 | 写入的 mbarrier 对象数据 |
| `smem_rsp_valid` | 1 | SMEM 返回数据有效 |
| `smem_rsp_rdata` | 64 | 读取到的 mbarrier 对象数据 |

所有 `init / arrive / drop / expect_tx / complete_tx / test_wait / try_wait` 均通过该接口访问 SMEM，其中 `test_wait` 为只读，其余操作为读改写。接口至少支持 64-bit 原子读写，并保证同一 mbarrier 对象的顺序一致性。

---
### 5.8 指令发射接口（Issue Interface）

| 接口名称 | 位宽 | 说明 |
| --- | --- | --- |
| `issue_mbarrier_valid` | 1 | 发射阶段送入一条 mbarrier 指令 |
| `issue_mbarrier_opcode` | `MBARRIER_OP_W` | 指令类型，如 `init/arrive/drop/expect_tx/complete_tx/test_wait/try_wait` |
| `issue_mbarrier_addr` | `SMEM_ADDR_W` | 目标 mbarrier 地址 |
| `issue_mbarrier_count` | 21 | 到达计数或 tx 计数操作数 |
| `issue_mbarrier_state_idx` | `REG_IDX_W` | `state` 操作数或目的寄存器索引 |
| `issue_mbarrier_ready` | 1 | MBMU 可接受新指令 |

该接口是 `mbarrier` 指令进入 MBMU 的唯一入口，保证其不占用普通 ALU/LSU 执行端口，并保持同步控制路径与数值运算路径物理解耦。

---

### 5.9 写回接口（Writeback Interface）

| 接口名称 | 位宽 | 说明 |
| --- | --- | --- |
| `wb_mbarrier_valid` | 1 | mbarrier 执行结果需要写回寄存器文件 |
| `wb_mbarrier_rd` | `REG_IDX_W` | 写回目标寄存器编号 |
| `wb_mbarrier_data` | `WB_DATA_W` | 写回数据，可承载 `state`、`waitComplete` 或 `pending_count` |
| `wb_mbarrier_ready` | 1 | 写回通路可接受结果 |

该接口与普通指令写回端口共享一致的时序语义，并与 Scoreboard 正确交互，保证 RAW/WAW 相关性不被破坏。

---




