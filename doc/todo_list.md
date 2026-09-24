# 📋 Todo List

### TMA 与 mbarrier

实现状态与后续缺口统一维护在 [TMA spec](tma_spec.md) 和
[mbarrier spec](mbarrier_spec.md)。copy 发出搬运，wait 检查完成；
global→shared 使用 mbarrier 字节计数，shared→global 使用 bulk-group。
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
