# 📋 Todo List

### 🔍 Nvidia Hopper 异步拷贝及 mbarrier
* **异步拷贝流程**
    * 在 SMEM 中构建 mbarrier
    * TMA 解析 TensorMap 并发出拷贝请求
    * GMEM、SMEM 执行拷贝(mbarrier.test_wait)
    * mbarrier complete phase 唤醒等待的 warp
* **硬件支持**：
  * **SMEM** (Scratchpad)
  * **TMA** (TensorMap AddrGen, Data FIFO, Request FIFO, TMA context)
---

### 🔎 Nvidia Blackwell TensorCore 5th Generation PTX

* Tensor Memory 交互：
  * **SMEM**
  * **RMEM**
  * **Tensor Core**
* 内存序：
  * Hopper SM 为顺序发射顺序执行强内存序
  * Blackwell Tensor Core 为乱序执行、极弱内存序
* 硬件支持：
  * **Tensor Mem**
  * **TensorMem Allocator**（负责分配和释放 TMEM）
  * **Tensor Copy Engine**（负责 TMEM 与 SMEM 交互
  * **Tensor Core**
---

## 📆 下周计划
* [ ] 编写硬件模块 **Spec**
* [ ] 进行 **RTL 实现**

---