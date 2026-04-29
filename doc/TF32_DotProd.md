# TF32 Dot Product FDA Unit Spec

## 1. 设计目标

实现一个 8-element TF32 fused-dot-add 单元：

```text
D = C + Σ(A[k] × B[k]), k = 0..7
```

其中 A/B 外部按 FP32 编码输入，进入乘法 datapath 前截断为 TF32：

```text
TF32 = FP32 sign + FP32 exponent + FP32 fraction[22:13]
```

低 13 bit fraction 直接丢弃，不做 RNE。

| 项目 | 规格 |
| --- | --- |
| 主 RTL 文件 | `src/main/tf32_dot_prod.sv` |
| 主模块 | `tf32_dot_prod` |
| 兼容 wrapper | `tf32_dot8_fda_f25` |
| 输入 A/B | 8 个 FP32 编码值，内部截断为 TF32 |
| 输入 C | FP32 |
| 输出 D | FP32 |
| Dot width | 8 |
| 内部对齐小数位 | F = 25 |
| 乘积计算 | TF32 significand × TF32 significand，精确定点乘法 |
| TF32 输入截断 | FP32 fraction 低 13 bit 截断，即 RZ |
| 对齐方式 | 以最大指数 `emax` 对齐 |
| 对齐截断 | shifted-out bits 直接截断，即 RZ |
| 累加方式 | 对齐后 signed Q7.25 定点累加 |
| 输出舍入 | FP32 输出，尾数按 RZ 截断到 23 fractional bits |
| 特殊值处理 | NVIDIA FDA 风格 NaN/Inf 规则 |

说明：TF32 的 significand 有效位宽为 11 bit，和 FP16 相同，因此 product significand 位宽仍为 22 bit Q2.20。不同点是 TF32 复用 FP32 的 8-bit exponent，指数范围和 FP32 一致。

## 2. 顶层接口

### 2.1 工程主接口

实现采用工程内统一 valid-ready 风格，输入向量为 flat packed bus。

```systemverilog
module tf32_dot_prod (
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
| `a_vec_i` | 256 | input | 8 个 FP32 编码 A，`a_vec_i[k*32 +: 32]` |
| `b_vec_i` | 256 | input | 8 个 FP32 编码 B，`b_vec_i[k*32 +: 32]` |
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

模块内部建议复用 `pipeline_reg` 串接 4 级流水，支持 backpressure。各级 payload 在 `valid=1` 且下游 `ready=0` 时保持稳定。

### 2.2 文档兼容接口

为了兼容单元级 spec，RTL 同文件提供 wrapper：

```systemverilog
module tf32_dot8_fda_f25 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [31:0] a_in [8],
    input  logic [31:0] b_in [8],
    input  logic [31:0] c_in,
    output logic        out_valid,
    output logic [31:0] d_out
);
```

Wrapper 将 `a_in[k]` / `b_in[k]` pack 到 `a_vec_i[k*32 +: 32]` / `b_vec_i[k*32 +: 32]`，并把 `out_rdy_i` 固定为 `1'b1`。该 wrapper 不暴露 backpressure。

## 3. Pipeline

实现为 4-stage FDA pipeline。

| Stage | RTL payload | 功能 |
| --- | --- | --- |
| S0 | `stage0_data_t` | 输入寄存；FP32 A/B 解码并截断为 TF32；FP32 C 解码；NaN/Inf/`0*Inf` 特殊值检测；8 路 TF32 significand 乘法；product sign/exponent/zero 生成；`emax` 搜索 |
| S1 | `stage1_data_t` | product/C 转换到 F=25；按 `emax` 对齐；对齐后再按符号转成 signed Q7.25 补码 |
| S2 | `stage2_data_t` | 8 products + C 的 33-bit signed Q7.25 累加 |
| S3 | `stage3_data_t` | 特殊值选择或 FP32 规约化 normalize + RZ pack 输出 |

Latency 为 4 个 `pipeline_reg` stage。无 stall 时，输入 fire 后第 4 个有效流水输出对应结果；持续 ready 时可每周期吞吐 1 个 dot8。

## 4. TF32 输入解码

TF32 不是独立 32-bit 存储格式。本单元外部接收 FP32 bit pattern，内部只保留 FP32 的 sign、8-bit exponent 和 fraction 高 10 bit：

```text
fp32_sign  = x[31]
fp32_exp   = x[30:23]
fp32_frac  = x[22:0]
tf32_frac  = fp32_frac[22:13]
tf32_drop  = fp32_frac[12:0]    // ignored
```

TF32 计算 significand：

```text
sign: 1 bit
exp : 8 bits
frac: 10 bits
bias: 127
```

分类：

| 条件 | 类型 | significand | unbiased exponent |
| --- | --- | --- | --- |
| `exp == 0 && tf32_frac == 0` | zero | 0 | 0 |
| `exp == 0 && tf32_frac != 0` | subnormal | `{1'b0, tf32_frac}` | -126 |
| `0 < exp < 255` | normal | `{1'b1, tf32_frac}` | `exp - 127` |
| `exp == 255 && fp32_frac == 0` | infinity | 0 | 0 |
| `exp == 255 && fp32_frac != 0` | NaN | 0 | 0 |

注意：

* NaN 判断使用原始 FP32 fraction，即使 NaN payload 只落在低 13 bit，也必须保持 NaN。
* 有限输入先做 TF32 RZ 截断再进入乘法；若 FP32 subnormal 的高 10 bit fraction 全 0，则该 lane 在 TF32 datapath 中视为 zero。
* 本规格不做 FP32 到 TF32 的 RNE，也不保留 sticky bit。

RTL type:

```systemverilog
typedef struct packed {
    logic                    sign;
    logic [10:0]             sig;
    logic signed [9:0]       exp;
    logic                    is_zero;
    logic                    is_inf;
    logic                    is_nan;
} tf32_dec_t;
```

`EXP_W=10` 覆盖 TF32/FP32 exponent 范围和 product exponent 范围：

```text
TF32 finite exponent:  -126..127
TF32 product exponent: -252..254
```

## 5. FP32 C 解码

FP32 C 不截断为 TF32，直接以 FP32 精度进入 F=25 对齐路径。

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

## 7. TF32 Product

对每个 lane：

```text
sign_p[k] = sign_a[k] ^ sign_b[k]
sig_p[k]  = sig_a[k] × sig_b[k]
exp_p[k]  = exp_a[k] + exp_b[k]
```

TF32 significand 为 Q1.10，乘积为：

```text
Q1.10 × Q1.10 = Q2.20
```

| 字段 | RTL 位宽 | 数学说明 |
| --- | ---: | --- |
| `sign_p[k]` | 1 | product 符号 |
| `sig_p[k]` | 22 | Q2.20 product significand |
| `exp_p[k]` | signed 10 | `exp_a + exp_b`，理论范围 -252..254 |
| `is_zero_p[k]` | 1 | zero 或特殊值 lane 不参与普通累加 |

Product 不进行 normalize。例如 `1.5 × 1.5` 保持 `2.25 × 2^(ea+eb)`，不改写成 `1.125 × 2^(ea+eb+1)`。

## 8. Emax 与 F=25 对齐

最大指数：

```text
emax = max(exp_c, exp_p[0], exp_p[1], ..., exp_p[7])
```

Zero lane 不参与 `emax` 搜索。`emax` 在 S0 与 product 生成同级完成，并随 product/C payload 传到 S1。若 C 和所有 product 都为 zero，则 S0 标记 zero payload。

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

S1 先完成无符号 magnitude 对齐，然后再按符号转成 signed Q7.25 补码：

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

S1 先按 exponent 差值右移得到无符号 magnitude，再按符号转成 signed Q7.25 补码：

```text
shift_c = emax - exp_c
aligned_c_signed = sign_c ? -signed({1'b0, c_mag >> shift_c})
                          :  signed({1'b0, c_mag >> shift_c})
```

右移全部为 RZ，shifted-out bits 直接丢弃。

## 9. 定点格式与位宽

RTL localparams：

```systemverilog
localparam int DOT_WIDTH          = 8;
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
8 × max(TF32 product significand) + max(C significand)
< 8 × 4 + 2
= 34
```

因此 signed Q6.25 已足够表达所有对齐后的有限累加结果；本规格仍建议采用 signed Q7.25，与 FP16 F=25 单元保持 datapath 位宽一致，降低共享 align/pack 逻辑的集成成本。

| 字段 | 位宽 | 说明 |
| --- | ---: | --- |
| `aligned_p_signed[k]` | 33 | signed Q7.25 product |
| `aligned_c_signed` | 33 | signed Q7.25 C |
| `sum` / `sum_fixed` | 33 | signed Q7.25 累加结果 |

注意：`aligned_prod_flat` 是 `8 × 33 = 264 bit` 的 packed bus，但每个 lane 仍是 33 bit。

## 10. Accumulate

S2 计算：

```text
sum_fixed = aligned_c_signed
          + aligned_p_signed[0]
          + aligned_p_signed[1]
          + ...
          + aligned_p_signed[7]
```

实现中可先使用 combinational loop 累加到 `sum_acc_tmp`。由于所有输入都已经完成 F=25 RZ 对齐，累加过程不再产生额外舍入。数学上加法顺序不影响结果；实现形式可后续替换为 balanced adder tree 以优化时序。

## 11. FP32 Normalize + RZ Pack

S3 对 `sum_fixed × 2^base_exp` 规约化并 pack 成 FP32，其中：

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

## 12. RTL 结构建议

当前实现将功能以内联 function、struct payload 和 4 个 `pipeline_reg` 实例组织在 `tf32_dot_prod` 中。相比 FP16 单元，TF32 dot8 lane 数更少，可将 product 生成和 `emax` 搜索合并到 S0，缩短流水级数。

| 规格功能 | RTL 实现 |
| --- | --- |
| TF32 decode | S0 `function automatic tf32_dec_t decode_tf32_from_fp32` |
| FP32 C decode | S0 `function automatic fp32_dec_t decode_fp32` |
| special case handler | S0 `always_comb` |
| TF32 product array | S0 `always_comb` loop |
| max exponent search | S0 `always_comb` |
| align to F25 | S1 `function automatic align_mag_rz` |
| signed two's-complement conversion | S1 对齐后按符号转换 |
| fixed-point accumulate | S2 `always_comb` |
| FP32 normalize RZ | S3 `function automatic pack_fp32_rz` |
| pipeline registers | `pipeline_reg` × 4 |

## 13. 关键设计点总结

| 设计点 | 规格 |
| --- | --- |
| 主模块 | `tf32_dot_prod` |
| 兼容模块 | `tf32_dot8_fda_f25` wrapper |
| 输入格式 | 外部 FP32 编码，内部 TF32 截断 |
| 输入布局 | `a_vec_i[k*32 +: 32]` / `b_vec_i[k*32 +: 32]` |
| valid-ready | 主模块支持 `in_vld_i/in_rdy_o/out_vld_o/out_rdy_i` |
| TF32 截断 | FP32 fraction 低 13 bit 直接截断 |
| TF32 product 是否 normalize | 不 normalize |
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
          + Σ Trunc_F25(TF32_RZ(sa[k]) × TF32_RZ(sb[k]) × 2^(ea[k] + eb[k] - emax))
        ]
    }
```

其中：

```text
F = 25
```

`TF32_RZ` 表示将 FP32 输入截断到 TF32 significand，即保留 10 个 fraction bit；`Trunc_F25` 表示保留 25 个 fractional bits，低位直接截断。

## 15. 验证建议

已执行的本地 lint：

```text
verilator --lint-only --sv src/main/pipeline_reg.sv src/main/tf32_dot_prod.sv
```

已执行的基本仿真：

```text
iverilog -g2012 -Wall -o /tmp/tf32_dot_prod_mmasim.vvp \
  src/main/pipeline_reg.sv \
  src/main/tf32_dot_prod.sv \
  /tmp/tf32_dot_prod_basic_tb.sv

vvp /tmp/tf32_dot_prod_basic_tb.vvp
```

结果：

```text
PASS d=41000000
```

已执行的 MMA-Sim 对比：

```text
python3 /tmp/tf32_mmasim_verify.py
```

参考模型来自 `MMA-Sim/mmasim/simulator/arithmetic.py`：

```text
truncate_to_tf32(A)
truncate_to_tf32(B)
nv_fused_dot_add(A_tf32, B_tf32, C, n_fractional_bits=25, output_type="f32")
```

结果：

```text
MMA-Sim TF32 compare PASS: 85 cases
```

最低覆盖内容：

| 类型 | 说明 |
| --- | --- |
| Basic | 8 路 `1.0f * 1.0f` 输出 `8.0f` |
| TF32 truncation | FP32 lower 13 fraction bit 改变不影响 product |
| C-only | A/B 全 zero，输出 C |
| Cancellation | 正负 product 抵消 |
| Subnormal | FP32 subnormal 截断到 TF32 subnormal 或 zero |
| Special | `0 * Inf`、`+Inf`、`-Inf`、NaN |
| Random | deterministic FP32 case，经 `truncate_to_tf32()` 后与 MMA-Sim 比较 |

当前状态：`src/main/tf32_dot_prod.sv` 已实现 4-stage TF32 dot8 F=25 datapath，并通过 Verilator lint、basic dot8 仿真和 85 组 MMA-Sim finite case 对比。
