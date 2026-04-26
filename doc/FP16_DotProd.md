# FP16 Dot Product FDA Unit Spec

## 1. 设计目标

实现一个 16-element FP16 fused-dot-add 单元：

```text
D = C + Σ(A[k] × B[k]), k = 0..15
```

| 项目 | 规格 |
| --- | --- |
| 主 RTL 文件 | `src/main/fp16_dot_prod.sv` |
| 主模块 | `fp16_dot_prod` |
| 兼容 wrapper | `fp16_dot16_fda_f25` |
| 输入 A/B | 16 个 FP16 |
| 输入 C | FP32 |
| 输出 D | FP32 |
| Dot width | 16 |
| 内部对齐小数位 | F = 25 |
| 乘积计算 | FP16 significand × FP16 significand，精确定点乘法 |
| 对齐方式 | 以最大指数 `emax` 对齐 |
| 对齐截断 | shifted-out bits 直接截断，即 RZ |
| 累加方式 | 对齐后 signed Q7.25 定点累加 |
| 输出舍入 | FP32 输出，尾数按 RZ 截断到 23 fractional bits |
| 特殊值处理 | NVIDIA FDA 风格 NaN/Inf 规则 |

## 2. 顶层接口

### 2.1 工程主接口

实现采用工程内统一 valid-ready 风格，输入向量为 flat packed bus。

```systemverilog
module fp16_dot_prod (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         in_vld_i,
    output logic         in_rdy_o,
    input  logic [255:0] a_vec_i,
    input  logic [255:0] b_vec_i,
    input  logic [31:0]  c_i,
    output logic         out_vld_o,
    input  logic         out_rdy_i,
    output logic [31:0]  d_o
);
```

| 接口名称 | 位宽 | 方向 | 说明 |
| --- | ---: | --- | --- |
| `clk` | 1 | input | 正边沿时钟 |
| `rst_n` | 1 | input | 低有效异步复位 |
| `in_vld_i` | 1 | input | 输入有效 |
| `in_rdy_o` | 1 | output | 输入可接收 |
| `a_vec_i` | 256 | input | 16 个 FP16 A，`a_vec_i[k*16 +: 16]` |
| `b_vec_i` | 256 | input | 16 个 FP16 B，`b_vec_i[k*16 +: 16]` |
| `c_i` | 32 | input | FP32 累加输入 C |
| `out_vld_o` | 1 | output | 输出有效 |
| `out_rdy_i` | 1 | input | 下游可接收 |
| `d_o` | 32 | output | FP32 输出 D |

输入 fire：

```systemverilog
in_fire = in_vld_i & in_rdy_o
```

输出 fire：

```systemverilog
out_fire = out_vld_o & out_rdy_i
```

模块内部使用 `pipeline_reg` 串接 5 级流水，因此支持 backpressure。各级 payload 在 `valid=1` 且下游 `ready=0` 时保持稳定。

### 2.2 文档兼容接口

为了兼容原 spec，RTL 同文件提供 wrapper：

```systemverilog
module fp16_dot16_fda_f25 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [15:0] a_in [16],
    input  logic [15:0] b_in [16],
    input  logic [31:0] c_in,
    output logic        out_valid,
    output logic [31:0] d_out
);
```

Wrapper 将 `a_in[k]` / `b_in[k]` pack 到 `a_vec_i[k*16 +: 16]` / `b_vec_i[k*16 +: 16]`，并把 `out_rdy_i` 固定为 `1'b1`。该 wrapper 不暴露 backpressure。

## 3. Pipeline

实现为 5-stage FDA pipeline。

| Stage | RTL payload | 功能 |
| --- | --- | --- |
| S0 | `stage0_data_t` | 输入寄存；FP16 A/B 解码；FP32 C 解码；NaN/Inf/`0*Inf` 特殊值检测 |
| S1 | `stage1_data_t` | 16 路 FP16 significand 乘法；product sign/exponent/zero 生成 |
| S2 | `stage2_data_t` | `emax` 搜索；product/C 转换到 F=25；对齐到 signed Q7.25 |
| S3 | `stage3_data_t` | 16 products + C 的 33-bit signed Q7.25 累加 |
| S4 | `stage4_data_t` | 特殊值选择或 FP32 normalize + RZ pack |

Latency 为 5 个 `pipeline_reg` stage。无 stall 时，输入 fire 后第 5 个有效流水输出对应结果；持续 ready 时可每周期吞吐 1 个 dot16。

## 4. FP16 解码

FP16 格式：

```text
sign: 1 bit
exp : 5 bits
frac: 10 bits
bias: 15
```

分类：

| 条件 | 类型 | significand | unbiased exponent |
| --- | --- | --- | --- |
| `exp == 0 && frac == 0` | zero | 0 | 0 |
| `exp == 0 && frac != 0` | subnormal | `{1'b0, frac}` | -14 |
| `0 < exp < 31` | normal | `{1'b1, frac}` | `exp - 15` |
| `exp == 31 && frac == 0` | infinity | 0 | 0 |
| `exp == 31 && frac != 0` | NaN | 0 | 0 |

RTL type:

```systemverilog
typedef struct packed {
    logic                    sign;
    logic [10:0]             sig;
    logic signed [9:0]       exp;
    logic                    is_zero;
    logic                    is_inf;
    logic                    is_nan;
} fp16_dec_t;
```

说明：FP16 product exponent 理论上 signed 7 bit 足够，但 RTL 统一使用 `EXP_W=10`，与 FP32 C exponent 和 `emax` 对齐，减少符号扩展与拼接复杂度。

## 5. FP32 C 解码

FP32 格式：

```text
sign: 1 bit
exp : 8 bits
frac: 23 bits
bias: 127
```

分类：

| 条件 | 类型 | significand | unbiased exponent |
| --- | --- | --- | --- |
| `exp == 0 && frac == 0` | zero | 0 | 0 |
| `exp == 0 && frac != 0` | subnormal | `{1'b0, frac}` | -126 |
| `0 < exp < 255` | normal | `{1'b1, frac}` | `exp - 127` |
| `exp == 255 && frac == 0` | infinity | 0 | 0 |
| `exp == 255 && frac != 0` | NaN | 0 | 0 |

RTL type:

```systemverilog
typedef struct packed {
    logic                    sign;
    logic [23:0]             sig;
    logic signed [9:0]       exp;
    logic                    is_zero;
    logic                    is_inf;
    logic                    is_nan;
} fp32_dec_t;
```

## 6. 特殊值规则

普通 datapath 只处理 finite 输入。S0 先处理 NaN / Inf / `0 × ∞`。

### 6.1 NaN

任一条件成立时输出 canonical NaN：

```text
任意 A[k] 是 NaN
任意 B[k] 是 NaN
C 是 NaN
任意 A[k] × B[k] 出现 0 × ∞ 或 ∞ × 0
同时存在 +∞ 和 -∞
```

输出：

```text
32'h7fff_ffff
```

### 6.2 Inf

对每个乘积：

| 情况 | 结果 |
| --- | --- |
| finite × finite | finite |
| zero × finite | zero |
| finite × zero | zero |
| inf × nonzero finite | signed inf |
| nonzero finite × inf | signed inf |
| inf × inf | signed inf |
| zero × inf | NaN |
| inf × zero | NaN |

统计所有 product infinity 和 C infinity：

| 条件 | 输出 |
| --- | --- |
| 同时存在 `+∞` 和 `-∞` | `32'h7fff_ffff` |
| 只存在 `+∞` | `32'h7f80_0000` |
| 只存在 `-∞` | `32'hff80_0000` |
| 不存在 Inf / NaN | 进入普通 datapath |

## 7. FP16 Product

对每个 lane：

```text
sign_p[k] = sign_a[k] ^ sign_b[k]
sig_p[k]  = sig_a[k] × sig_b[k]
exp_p[k]  = exp_a[k] + exp_b[k]
```

FP16 significand 为 Q1.10，乘积为：

```text
Q1.10 × Q1.10 = Q2.20
```

| 字段 | RTL 位宽 | 数学说明 |
| --- | ---: | --- |
| `sign_p[k]` | 1 | product 符号 |
| `sig_p[k]` | 22 | Q2.20 product significand |
| `exp_p[k]` | signed 10 | `exp_a + exp_b`，理论范围 -28..30 |
| `is_zero_p[k]` | 1 | zero 或特殊值 lane 不参与普通累加 |

Product 不进行 normalize。例如 `1.5 × 1.5` 保持 `2.25 × 2^(ea+eb)`，不改写成 `1.125 × 2^(ea+eb+1)`。

## 8. Emax 与 F=25 对齐

最大指数：

```text
emax = max(exp_c, exp_p[0], exp_p[1], ..., exp_p[15])
```

Zero lane 不参与 `emax` 搜索。若 C 和所有 product 都为 zero，则 S2 输出 zero payload。

RTL 中：

| 字段 | 位宽 | 说明 |
| --- | ---: | --- |
| `emax` | signed 10 | 最大 exponent |
| `base_exp` | signed 10 | `emax - 25`，传给 FP32 pack |

### 8.1 Product 对齐

Product significand：

```text
sig_p[k]: Q2.20
```

先补齐到 F=25：

```text
prod_mag = sig_p[k] << 5
```

得到 unsigned Q2.25，有效宽度 27 bit，再零扩展到 `ALIGN_MAG_W=32`。

按 exponent 差值右移：

```text
shift_p[k] = emax - exp_p[k]
aligned_mag = prod_mag >> shift_p[k]
```

再按符号转成 signed Q7.25：

```text
aligned_p_signed[k] = sign_p[k] ? -signed({1'b0, aligned_mag})
                                :  signed({1'b0, aligned_mag})
```

### 8.2 C 对齐

C significand：

```text
sig_c: Q1.23
```

先补齐到 F=25：

```text
c_mag = sig_c << 2
```

得到 unsigned Q1.25，有效宽度 26 bit，再零扩展到 `ALIGN_MAG_W=32`。

按 exponent 差值右移并按符号转成 signed Q7.25：

```text
shift_c = emax - exp_c
aligned_c_signed = sign_c ? -signed({1'b0, c_mag >> shift_c})
                          :  signed({1'b0, c_mag >> shift_c})
```

右移全部为 RZ，shifted-out bits 直接丢弃。

## 9. 定点格式与位宽

RTL localparams：

```systemverilog
localparam int EXP_W              = 10;
localparam int PROD_SIG_W         = 22;
localparam int ALIGN_FRAC_BITS    = 25;
localparam int ALIGN_INT_BITS     = 7;
localparam int ALIGN_MAG_W        = ALIGN_INT_BITS + ALIGN_FRAC_BITS; // 32
localparam int ALIGN_TERM_W       = ALIGN_MAG_W + 1;                  // 33
localparam int SUM_W              = ALIGN_TERM_W;                     // 33
```

定点 accumulator 格式：

```text
signed Q7.25
1 sign bit + 7 integer bits + 25 fractional bits = 33 bits
```

最大值边界：

```text
16 × max(FP16 product significand) + max(C significand)
< 16 × 4 + 2
= 66
```

因此 signed Q7.25 覆盖 `[-128, +127]`，足够表达所有对齐后的有限累加结果。

| 字段 | 位宽 | 说明 |
| --- | ---: | --- |
| `aligned_p_signed[k]` | 33 | signed Q7.25 product |
| `aligned_c_signed` | 33 | signed Q7.25 C |
| `sum` / `sum_fixed` | 33 | signed Q7.25 累加结果 |

注意：`aligned_prod_flat` 是 `16 × 33 = 528 bit` 的 packed bus，但每个 lane 仍是 33 bit。

## 10. Accumulate

S3 计算：

```text
sum_fixed = aligned_c_signed
          + aligned_p_signed[0]
          + aligned_p_signed[1]
          + ...
          + aligned_p_signed[15]
```

实现中使用一个 combinational loop 累加到 `sum_acc_tmp`。由于所有输入都已经完成 F=25 RZ 对齐，累加过程不再产生额外舍入。数学上加法顺序不影响结果；实现形式可后续替换为 balanced adder tree 以优化时序。

## 11. FP32 Normalize + RZ Pack

S4 对 `sum_fixed × 2^base_exp` pack 成 FP32，其中：

```text
base_exp = emax - 25
sum_fixed: signed Q7.25
```

### 11.1 Zero

若：

```text
sum_fixed == 0
```

输出：

```text
32'h0000_0000
```

不保留 signed zero。

### 11.2 符号与绝对值

```text
sign_d  = sum_fixed[32]
abs_sum = abs(sum_fixed)
```

`abs_sum` 保留 33 bit。按本规格数值边界，`abs_sum[32]` 不应为 1；若实现或输入扩展导致该 bit 置位，pack 逻辑仍会从最高 bit 搜索。

### 11.3 Leading One 与指数

RTL 从 `SUM_W-1` 到 0 搜索最高有效 1：

```text
msb_idx = highest_set_bit(abs_sum)
exp_unbiased = base_exp + msb_idx
```

因为 `base_exp = emax - 25`，这等价于：

```text
exp_unbiased = emax + (msb_idx - 25)
```

### 11.4 Normal / Subnormal / Overflow

先左移归一化：

```text
norm_sum = abs_sum << ((SUM_W - 1) - msb_idx)
sig24    = norm_sum[SUM_W-1 -: 24]
```

输出规则：

| 条件 | 输出 |
| --- | --- |
| `exp_unbiased > 127` | signed infinity |
| `-126 <= exp_unbiased <= 127` | normal FP32，`exp_field=exp_unbiased+127`，`frac=sig24[22:0]` |
| `exp_unbiased < -149` | zero |
| otherwise | subnormal，`sig24 >> (-126 - exp_unbiased)` 后取 `frac=sig24[22:0]` |

所有 FP32 fraction 输出为 RZ，不做 RNE，不做 sticky rounding。

## 12. RTL 结构

当前实现没有拆成独立子模块，而是将这些功能以内联 function、struct payload 和 5 个 `pipeline_reg` 实例组织在 `fp16_dot_prod` 中。

| 规格功能 | RTL 实现 |
| --- | --- |
| FP16 decode | `function automatic fp16_dec_t decode_fp16` |
| FP32 decode | `function automatic fp32_dec_t decode_fp32` |
| special case handler | S0 `always_comb` |
| FP16 product array | S1 `always_comb` loop |
| max exponent search | S2 `always_comb` |
| align to F25 | `function automatic align_fixed_rz` |
| fixed-point accumulate | S3 `always_comb` |
| FP32 normalize RZ | `function automatic pack_fp32_rz` |
| pipeline registers | `pipeline_reg` × 5 |

## 13. 关键设计点总结

| 设计点 | RTL 对齐后的规格 |
| --- | --- |
| 主模块 | `fp16_dot_prod` |
| 兼容模块 | `fp16_dot16_fda_f25` wrapper |
| 输入格式 | `a_vec_i[k*16 +: 16]` / `b_vec_i[k*16 +: 16]` |
| valid-ready | 主模块支持 `in_vld_i/in_rdy_o/out_vld_o/out_rdy_i` |
| FP16 product 是否 normalize | 不 normalize |
| product significand | 22 bit Q2.20 |
| product exponent RTL 位宽 | signed 10 |
| 对齐基准 | `emax = max(C exponent, product exponents)` |
| 内部对齐精度 | F = 25 |
| product 对齐前转换 | `Q2.20 << 5 = Q2.25` |
| C 对齐前转换 | `Q1.23 << 2 = Q1.25` |
| 对齐右移舍入 | RZ，直接截断 |
| 累加格式 | signed Q7.25 |
| 单 lane 累加位宽 | 33 bit |
| FP32 输出舍入 | RZ 到 23 fractional bits |
| NaN 输出 | `32'h7fff_ffff` |
| FP32 overflow | signed infinity |

## 14. 数学等价表达

在无 NaN / Inf 的情况下，该单元实现：

```text
D = Normalize_FP32_RZ {
        2^emax × [
            Trunc_F25(sc × 2^(ec - emax))
          + Σ Trunc_F25(sa[k] × sb[k] × 2^(ea[k] + eb[k] - emax))
        ]
    }
```

其中：

```text
F = 25
```

`Trunc_F25` 表示保留 25 个 fractional bits，低位直接截断。

## 15. 验证状态

已执行的本地检查：

```text
verilator --lint-only --sv src/main/pipeline_reg.sv src/main/fp16_dot_prod.sv
```

结果：通过。

已执行的仿真：

```text
iverilog -g2012 -Wall -o /tmp/fp16_dot_prod_mmasim.vvp \
  src/main/pipeline_reg.sv \
  src/main/fp16_dot_prod.sv \
  /tmp/fp16_dot_prod_mmasim_tb.sv

vvp /tmp/fp16_dot_prod_mmasim.vvp
```

结果：

```text
MMA-Sim compare PASS: 30 cases
```

覆盖内容：

| 类型 | 说明 |
| --- | --- |
| Basic | 16 路 `1.0h * 1.0h` 输出 `16.0f` |
| C-only | A/B 全 zero，输出 C |
| Cancellation | 正负 product 抵消 |
| Special | `0 * Inf`、`+Inf`、NaN |
| Random | 24 组 deterministic FP16/FP32 case |

说明：本机 Python 环境没有 `torch`，验证时使用 `/tmp` 下的最小 torch shim 让 `MMA-Sim` 的 `nv_fused_dot_add` 可执行；参考函数仍来自 `MMA-Sim/mmasim/simulator/arithmetic.py`。
