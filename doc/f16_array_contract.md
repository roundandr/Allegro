# FP16/BF16 算术阵列合同

`blackwell_f16_dot_array` 默认实例化 256 个真实 `f16tf32_dot_prod`，
按 **4 分区 × 64 dot** 组织。每个核每周期接收一组独立 K16 操作数，
处理 FP16 或 BF16 乘法及 FP32 累加输入，返回一个 FP32 D。
统一 valid-ready 和 tag FIFO 保证各核锁步，输出消费者阻塞时整个向量与 tag
保持稳定。输入/输出端口是算术微操作向量，不是已译码的完整 `tcgen05.mma`。

RTX 5080 远端 CPU 上的 Verilator/Cocotb 测试连续提供 4096 周期数据，
默认 256 核配置的 FP16 和 BF16 各接受并退休 4096 个阵列请求，
即 **8192 operation/cycle**（FMA 计 2 operation），达到本计划这两种类型的
独立算术峰值。另覆盖逐 lane 不同 C、全部输出对照、tag 顺序及结果背压。
sv2v/Yosys 层次检查确认 256 个非 black-box 实算术核，
不等于全阵列门级 PPA 或整个异步子系统已综合。

仍须将 A/B operand collector、广播复用、TMEM D 读写、累加旁路、指令完成、
SMEM/TMA 供数和 RF 输出接到此阵列。此测试没有测量这些路径，
也不能替代 P3 完整流水的 ≥85% 门槛。
