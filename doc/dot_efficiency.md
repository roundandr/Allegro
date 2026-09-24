# 单个 Allegro 点积单元能效基线

2026-09-18，对一个完整的 `f16tf32_dot_prod` 做综合级功耗估算。
保留 TF32/BF16/FP16 运行时选择、五级流水和 valid-ready 控制；功耗激励使用
FP16×FP16→FP32、K=16、C=0、scale=0，连续满载。

**三组中位能效为 4,279.06 GFLOP/s/W，即 4.279 TFLOP/s/W；每 FLOP 能耗为
0.23370 pJ。**

| 指标 | 结果 |
|---|---:|
| 工艺/角落 | ASAP7 RVT TT NLDM，0.7 V，25°C |
| 选定周期 / 频率 | 1.59 ns / 628.931 MHz |
| 实际稳态吞吐 | 1 个点积/周期，20.1258 GFLOP/s |
| 总功耗中位数 | 4.70332 mW |
| Internal / Switching / Leakage（种子 917） | 2.99894 mW / 1.70249 mW / 1.89142 µW |
| 标准单元数 | 27,732 |
| 单元面积合计 | 2,896.317 µm² |
| 选定周期下最差 setup slack | +149.145 ps |
| VCD 活动标注 | 103,785 引脚，未标注 0 |

| 种子 | 总功耗 (mW) | GFLOP/s/W | pJ/FLOP |
|---|---:|---:|---:|
| 917 | 4.703323 | 4279.056 | 0.233696 |
| 918 | 4.702895 | 4279.446 | 0.233675 |
| 919 | 4.704863 | 4277.656 | 0.233773 |

## 方法与验证

- 每组 256 周期预热、10,000 周期采样，A/B 独立均匀取样于 [-1,1] 后转换为
  FP16。窗口 15.9 µs 内实际完成 10,000 个点积，按常用 `2K=32 FLOP` 计数。
- 精度、C、缩放和握手输入在综合时保持为端口；未把硬件裁剪成 FP16 专用核。
- sv2v v0.0.13 → Yosys 0.64 → ASAP7 标准单元；OpenROAD/OpenSTA
  `26Q2-1846-g49bd051a10` 读取同一 Liberty 和门级 VCD 计算功耗。
- ABC 使用 BUFx2 输入驱动、3.898 fF 输出负载进行映射及缓冲。STA 输入 slew
  50 ps，输入/输出延迟各 100 ps，输出负载 3.898 fF；复位从功能 setup 路径中排除。
- 初始 1 GHz 的 setup slack 为负；按所需周期加 10% 裕量并向上取整到 10 ps，
  选择 1.59 ns。选定周期下报告无 max-slew/max-capacitance 违规。
- 原始 RTL、转换后模型和门级模型均通过现有三精度与背压回归：每模型 1,000
  个随机样例及 18 个定向样例。三组各 10,256 个输入在三个模型上逐项匹配
  MMA-Sim F=25/RZ 参考，输出时序一致。
- 显式开启 Verilator `--trace-underscore`，覆盖 Yosys 自动命名的内部信号。
  功耗汇总要求未标注引脚为零，并检查 VCD 时间单位、窗口长度及功率单位。
- Liberty 的 STA-1212 警告来自 FAx1/HAxp5 单元的输出间 timing arc；这两个
  单元均未出现在映射网表中。输入延迟提示只涉及已排除 setup 检查的 `rst_n`。

## 结果边界

这是基于预测性 ASAP7 工艺库与零延迟门级活动的**综合级估算**，不是硅片功耗实测。
总功耗包含寄存器内部功耗、组合逻辑功耗及泄漏；未建模实际时钟树缓冲、布线寄生、
时延引起的毛刺、TMEM/SMEM 和系统供电开销。面积是单元面积合计，不是布局后核心面积。
结果依赖随机输入分布、固定 C=0 与持续满载条件，也不能直接当作 NVIDIA Tensor Core
或整卡能效。

## 复现与原始证据

- 执行入口：远端独立源码目录运行 `make dot-efficiency`。
- [流程说明](../verification/benchmarks/dot_efficiency/README.md) / [参数配置](../verification/benchmarks/dot_efficiency/config.json)。
- [完整报告](../build/blackwell/dot_efficiency/REPORT.md)、
  [逐组 CSV](../build/blackwell/dot_efficiency/results.csv)、
  [结构化 JSON](../build/blackwell/dot_efficiency/results.json)。
- 同目录保留 `mapped.v`、`activity_*.vcd.gz`、Liberty、时序/功耗/回归日志，以及源码快照与 SHA256。
- 功能验证运行：`allegro-dot-eff-20260918-06`；最终完整波形与功耗运行：
  `allegro-dot-eff-20260918-07`。后者复用已验证且哈希未变的算术源码和网表，重新采集完整内部活动。
  最终功耗采用 07 的结果。
- 最终运行耗时约 277 秒，主机进程采样峰值 RSS 约 4.02 GiB；全部在远端 CPU 执行。
  运行记录与取回校验信息保存在 `build/blackwell/dot_efficiency_run/`。
