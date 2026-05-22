# **Tensor Core Architecture Specification (Draft)**

*Version 0.9 — Architecture-Level Specification*
*Project: 异步 Tensor Core*

---

## **1. Overview**

Tensor Core 是一种专为矩阵乘加（Matrix Multiply-Accumulate, MMA）设计的专用执行单元（DPU）。其目标是为深度学习工作负载提供数量级提升的吞吐率，通过硬件矩阵指令与特殊数据路径实现持续的高并行度。

Tensor Core 系统由以下组件构成：

* **Tensor Core Data Processing Unit (DPU)**
* **Operand Delivery Path**：从 GMEM / SMEM / Tensor Memory 读取片段（tiles）
* **Tensor Memory (TMEM)**：用于存储 tile 级中间张量
* **Shared Memory (SMEM)**：软件可控 scratchpad
* **TMA（Tensor Memory Accelerator）**：执行矩阵 tile 的分块 DMA
* **mbarrier / async-group / wgmma-group**：用于跨warp/warpgroup的同步

本 spec 以 **tile-based MMA pipeline** 为核心组织结构。

---

## **2. Execution Model**

### **2.1 Programming Model**

典型 MMA 指令：

```
wgmma.mma_async.sync.aligned.m16n16k16.f16.f16.f16 {d}, a, b, c;
```

指令语义：

* A、B 为矩阵块（tiles）
* C、D 为累加器（accumulator tile）
* 操作以 warpgroup（128 threads）为粒度进行调度
* MMA 是 **异步** 的，即发射后不会立即阻塞线程

### **2.2 Warpgroup Execution**

Warpgroup = 128 threads
每次 MMA 操作通常具有如下内部执行流程：

```
issue_mma → fetch operands → dispatch to tensor core → systolic accumulate → writeback
```

多条 MMA 指令通过 **commit_group / wait_group** 实现顺序控制。

---

## **3. Operand & Data Model**

### **3.1 Tile-Based Access**

数据以 tile 为基本单位传输和计算。

* 常见 tile：16×16, 32×32, 64×128 等
* 数据不以标量为单位移动，而是 **TensorMap** 描述的大 tile

### **3.2 Operand Sources**

| Operand | 来源                 | 说明          |
| ------- | ------------------ | ----------- |
| A Tile  | SMEM / GMEM / TMEM | 通常通过 TMA 加载 |
| B Tile  | SMEM / GMEM / TMEM | 同上          |
| C Tile  | Register 或 TMEM    | 累加器 tile    |
| D Tile  | 写回 Register/TMEM   | 结果          |

### **3.3 Tensor Memory (TMEM)**

新架构中的类似 Blackwell 的 **Tensor Memory** 特性：

* 以“列”为分配粒度（32B 对齐）
* 动态容量管理：`alloc` / `dealloc`
* 支持直接与 Tensor Core datapath peer-to-peer 数据交换
* 延迟远低于 GMEM，高于 SMEM

TMEM 是中等容量（KB~MB级）、高带宽、可分配的片上缓冲区。

---

## **4. Data Movement System**

### **4.1 TMA (Tensor Memory Accelerator)**

专门用于 tile 级 DMA：

```
cp.async.bulk.tensor.2d.shared.global
```

**能力：**

* 根据 TensorMap 自动计算 tile 地址
* 自动处理 stride / swizzling
* 异步 push → SMEM / TMEM
* 具备硬件 backpressure（FIFO 满会暂停前端发射）

### **4.2 Swizzling**

用于 SMEM 中的地址重排：

* 减少 bank conflict
* 决定 SMEM tile 的布局模式
* 通常由 TensorMap 的 swizzle 字段指定

---

## **5. Synchronization Model**

### **5.1 mbarrier**

mbarrier 是 SMEM 驻留的 barrier 对象，用于以下场景：

* 异步拷贝完成通知
* 多 stage pipeline 控制（双缓冲、三缓冲）
* 多 warp 同步

关键指令：

```
mbarrier.init
mbarrier.arrive
mbarrier.arrive.expect_tx
mbarrier.test_wait
mbarrier.try_wait.parity
```

### **5.2 WGMMA Group Synchronization**

每个 warpgroup 有 "group slots"：

```
wgmma.commit_group // 结束当前 batch
wgmma.wait_group   // 等待所有之前 commit 的 group 完成
```

作用类似于软件管理的“指令簇”。

---

## **6. Tensor Core Datapath**

Tensor Core datapath 中包含：

* Systolic Array 或 Dot-Product Array
* FP8/FP16/BF16/FP32/Fp4 支持
* Accumulation pipeline
* Operand Pre-fetch Buffer（OPB）
* Output Fragment Buffer（OFB）

内部管线阶段：

1. Dispatch
2. Load Operands (A/B tiles)
3. Systolic computation
4. Accumulate to C
5. Output writeback

典型延迟：

* **4~8 cycles pipeline depth**
* **吞吐 = 每个周期完成多个 FMA tile**

---

## **7. Pipeline Model for Software**

### **Stage Pipeline (3-buffer example)**

```
Stage 0: TMA load A/B into SMEM
Stage 1: Tensor Core consumes SMEM tiles → MMA
Stage 2: Writeback / Prefetch next tiles
```

软件控制循环（伪代码）：

```c
for (ko = 0; ko < K_tiles; ++ko) {
    int write_stage = ko % num_stages;
    int read_stage  = (ko - 1 + num_stages) % num_stages;

    mbarrier.try_wait(stage_barrier[write_stage]);
    launch_tma_async(stage_smem[write_stage]);

    mbarrier.arrive.expect_tx(stage_barrier[write_stage], tile_bytes);

    if (ko > 0)
        wgmma.mma_async(stage_smem[read_stage]);
}
wgmma.commit_group();
wgmma.wait_group();
```

---

## **8. ISA Interface Summary**

### **8.1 MMA Instructions**

* `wgmma.mma_async`
* `wgmma.commit_group`
* `wgmma.wait_group`

### **8.2 Tensor Map Instructions**

* `tensormap.replace`
* `tensormap.create`

### **8.3 TMA copy**

* `cp.async.bulk.tensor.2d.shared.global`
* `cp.async.bulk.tensor.1d.shared.global`

### **8.4 Tensor Memory Management**

* `tcgen.alloc`
* `tcgen.dealloc`
* `tcgen.relinquish_alloc_permit`

---

## **9. Resource and Constraints**

| Resource              | Meaning                  |
| --------------------- | ------------------------ |
| Tensor Core Slots     | 每 warpgroup 可并行执行的 MMA 数 |
| Inflight Tensor Count | 限制同时进行的 MMA 操作数量         |
| TMA Request FIFO      | 限制 pending DMA 数量        |
| SMEM bandwidth        | 决定预取速度                   |
| TMEM columns          | 分配失败会阻塞 alloc 指令         |

---

## **10. Performance Model**

### **10.1 Sustained TFLOPS**

理论峰值由：

```
(Tile_M × Tile_N × Tile_K × FMA_per_cycle × num_tensor_cores × freq)
```

决定。

### **10.2 Overlap Rules**

以下可完全重叠：

* TMA loading 与 Tensor Core compute
* MMA dispatch 与 writeback
* 多 stage pipeline 中的不同 stage

但以下不可重叠：

* 超出 inflight tensor 限制时的 MMA 发射
* mbarrier 阶段同步

---

## **11. Hardware Block Diagram (Textual)**

```
GMEM → TMA → SMEM/TMEM → Operand Buffer → Tensor Core Array
                                           ↓
                                         Accumulator → TMEM / Register File
```

---


