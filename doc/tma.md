# TMA 异步拷贝说明书
### TMA Async Copy Spec

Nvidia Hopper 架构引入 **TMA（Tensor Memory Accelerator）** 专门用于高效执行多维异步拷贝（Global Memory → Shared Memory / Tensor Memory）。
结合 **mbarrier（Memory Barrier）**，可构建高性能 Producer-Consumer Pipeline，使数据移动与计算完全解耦。

---

# 1. 异步拷贝总体流程

异步拷贝流程包含以下阶段：

1. 在 SMEM 中构建 mbarrier
2. TMA 解析 TensorMap 并发出异步拷贝请求
3. TMA 执行 GMEM → SMEM 传输
4. mbarrier 记录完成情况并唤醒等待的 warp

流程图概览：

```
Producer Warp
   │
   ├─► mbarrier.init()
   ├─► cp.async.bulk.tensor(...)    TMA Front-End
   │                                      │
   │                                      ▼
   │                             Decode TensorMap
   │                                      │
   │                                      ▼
   │                             TMA Context / AddrGen
   │                                      │
   │                                      ▼
   │                             GMEM Read → Data FIFO
   │                                      │
   │                                      ▼
   │                                SMEM Write Port
   │                                      │
   ▼                                      ▼
Consumer Warp ◄────────────── mbarrier phase complete
```

---

# 2. TMA：Tensor Memory Accelerator

TMA 是 Hopper 的核心数据移动单元，具有以下职责：

* 解析 TensorMap 描述符（1024-bit）
* 多维地址生成（1D/2D/3D/4D）
* swizzle/bank conflict 规避
* Global Memory DMA 读
* Shared/Tensor Memory 写
* 和 mbarrier 协作通知传输完成

TMA 以硬件异步方式运行，可在后台持续执行，warp 不需等待。

---

# 3. 异步拷贝执行步骤详解

## Step 1：mbarrier 初始化

```cpp
mbarrier.init(&bar, expected_tx);
```

* 将 barrier TX counter 归零
* 设置期望传输量
* phase 初始化为 0

---

## Step 2：TMA 加载并解析 TensorMap & 绑定 mbarrier

TensorMap 是一个 1024-bit 对象，包含：

* rank
* 各维 shape
* stride
* swizzle mode
* global base address
* smem/tmem base address
* multicast/cluster 信息

加载并解析 TensorMap：
1. TMA 根据 **Tensor Map 在 SMEM 的基址** 向 SMEM 发出 read-req
2. 将 rsp 写入 TMA 内部的 TensorMap Buffer
3. Addr Gen 解析 TensorMap

绑定 mbarrier：
1. Step1 创建 mbarrier 后将该 mbarrier 的基址写回寄存器
2. 从寄存器获取 **&mbarrier** 并将本次 TMA 操作与该 mbarrier 绑定
3. 向 **mbarrier_manage_unit** 发出更改请求，将 **TensorMap 解析出的拷贝字节数**写入绑定的 mbarrier 的 expected_tx 字段

> 综上所述，TMA 异步拷贝指令需要 2 个寄存器提供操作数，分别是 &tensorMap、&mbarrier
---

## Step 3：TMA 创建上下文并执行多维拷贝

TMA Context 包含：

* 多维计数器
* 当前 global_addr
* 当前 smem_addr
* 剩余 tile/行/字节
* in-flight burst 信息
* TensorMap 缓存的 stride/shape/swizzle

### 数据流：

```
GMEM Read → Data FIFO → SMEM Write Port → mbarrier.complete_tx
```

注意 backpressure 控制，保证：

* Data FIFO 不溢出，当Data FIFO is Full，要阻塞上游MEM的读取
* 上游MEM pipeline 不阻塞

---

## Step 4：mbarrier 完成并唤醒 warp

TMA 完成预设字节：

* mbarrier TX counter == expected_tx
* mbarrier 相位切换（phase flip）
* 所有等待的 warp 被唤醒

消费者 warp 执行：

```cpp
mbarrier.test_wait(&bar);   // 阻塞直到 phase 完成
wgmma.mma.async. ...
```

至此，GMEM → SMEM 数据已就绪。

---

# 5. TMA 涉及模块总结

## 5.1 TMA 子模块

| 模块                            | 作用                                        |
| ----------------------------- | ----------------------------------------- |
| **TMA Front-End**             | 接收 cp.async.bulk.tensor 指令，创建 TMA Context |
| **TensorMap Buffer**    | 缓存 1024-bit TensorMap                     |
| **TMA Context Table**         | 保存 TMA 任务状态（地址、循环、剩余量）                    |
| **AddrGen** | 多维坐标生成 + stride 累加 + swizzle              |
| **TMA Request FIFO**          | GMEM 读请求，处理 backpressure                  |
| **Data FIFO**                 | 缓冲 GMEM → SMEM 数据                         |


## 5.2 其余模块
| 模块                            | 作用                                        |
| ----------------------------- | ----------------------------------------- |
| **GMEM Read/Write Port**           | 读写 Global memory|
| **SMEM Read/Write Port**           | 读写 shared memory|
| **TMEM Read/Write Port**           | 读写 Tensor Memory（Blackwell）               |
| **mbarrier Manage Unit**           | TX count / 唤醒等待 warp |

---

# 6. 典型代码示例

```cpp
// Initialize mbarrier
mbarrier.init(&bar, bytes);

// Build TensorMap descriptor
tensormap.create(&desc, ...);

// Async copy
cp.async.bulk.tensor.shared::cta.global.mbarrier::complete_tx::bytes
    [smem_ptr], [desc], [bar];

// Wait for DMA completion
mbarrier.test_wait(&bar);

// Now consumer warp can read SMEM
ld.shared.s32 %r, [smem_ptr];
```

---


