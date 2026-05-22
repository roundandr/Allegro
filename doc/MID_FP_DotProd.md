# MID-FP Dot Product FDA Unit Spec

## 1. 设计目标

实现一个共享 TF32 / BF16 / FP16 的 fused-dot-add 单元：

```text
D = C + Σ(A[k] × B[k])
```

其中 TF32 使用 K=8，BF16/FP16 使用 K=16。三种模式共用一套 16-lane、11-bit significand 乘法与 FP32 accumulate datapath。
可选的 `scale_input_d_i` 在 C operand preprocess 中先执行 `C * 2^-scale_input_d_i`，用于承接 TCGen05 `.kind::tf32/.kind::f16` 的 `scale-input-d` 语义；普通 dot 调用将该端口接 0。

| 项目 | 规格 |
| --- | --- |
| 主 RTL 文件 | `src/main/mid_fp_dot_prod.sv` |
| 主模块 | `mid_fp_dot_prod` |
| 输入 A/B | TF32 模式为 8 个 FP32 编码值；BF16/FP16 模式为 16 个 16-bit 编码值 |
| 输入 C | FP32 |
| 输出 D | FP32 |
| Dot width | TF32 K=8；BF16/FP16 K=16 |
| 内部对齐小数位 | F = 25 |
| 乘积计算 | TF32/BF16/FP16 significand 统一映射到 11 bit 后精确定点乘法 |
| 共享算术核心 | 16 路 `11 × 11` multiplier、product exponent adder、`emax`、align、accumulate、FP32 pack |
| TF32 lane 使用 | 仅 lane 0..7 有效，lane 8..15 关闭且不参与 special / `emax` / sum |
| 对齐方式 | 以最大指数 `emax` 对齐 |
| 对齐截断 | shifted-out bits 直接截断，即 RZ |
| 累加方式 | 对齐后 signed Q7.25 定点累加 |
| 输出舍入 | FP32 输出，尾数按 RZ 截断到 23 fractional bits |
| 特殊值处理 | NVIDIA FDA 风格 NaN/Inf 规则 |

设计意图：

1. 删除独立 TF32 dot8 core 与 FP16/BF16 dot16 core 之间重复的 mantissa multiplier、exponent add、align、accumulate、pack 硬件。
2. 保持 TF32 单 request 只占 1 个 cycle 输入吞吐，不把 TF32 K8 拆成两拍或与 FP16 做 time-mux。
3. 将 TF32/BF16/FP16 的输入 decode 差异限制在 S0，其后进入统一 11-bit significand + signed unbiased exponent datapath。
4. 允许 `a_mode_i` / `b_mode_i` 随 request 逐拍变化；是否禁止不同 dtype 短窗口交错由上层 `dot_cluster_top` 的 admission policy 决定。

## 2. 顶层接口

### 2.1 工程主接口

实现采用工程内统一 valid-ready 风格，输入向量为 flat packed bus。

```systemverilog
module mid_fp_dot_prod (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         in_vld_i,
    output logic         in_rdy_o,
    input  logic [1:0]   a_mode_i,
    input  logic [1:0]   b_mode_i,
    input  logic [255:0] a_vec_i,
    input  logic [255:0] b_vec_i,
    input  logic [31:0]  c_i,
    input  logic [3:0]   scale_input_d_i,
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
| `a_mode_i` | 2 | input | A 输入格式模式，编码见 2.2 |
| `b_mode_i` | 2 | input | B 输入格式模式，编码见 2.2 |
| `a_vec_i` | 256 | input | A packed 输入向量 |
| `b_vec_i` | 256 | input | B packed 输入向量 |
| `c_i` | 32 | input | FP32 累加输入 C |
| `scale_input_d_i` | 4 | input | C operand 预缩放，`C_eff = C * 2^-scale_input_d_i`；普通 dot 接 0 |
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

### 2.2 模式编码

```systemverilog
localparam logic [1:0] MID_FP_MODE_TF32 = 2'd0;
localparam logic [1:0] MID_FP_MODE_BF16 = 2'd1;
localparam logic [1:0] MID_FP_MODE_FP16 = 2'd2;
```

| `a_mode_i` / `b_mode_i` | 模式 | Dot width | A/B packed 布局 |
| --- | --- | ---: | --- |
| `2'd0` | TF32 | 8 | `a_vec_i[k*32 +: 32]` / `b_vec_i[k*32 +: 32]`, `k=0..7` |
| `2'd1` | BF16 | 16 | `a_vec_i[k*16 +: 16]` / `b_vec_i[k*16 +: 16]`, `k=0..15` |
| `2'd2` | FP16 | 16 | `a_vec_i[k*16 +: 16]` / `b_vec_i[k*16 +: 16]`, `k=0..15` |
| `2'd3` | reserved | - | 上层不得发入；防御性实现可返回 canonical NaN |

TF32 模式下，`a_vec_i[255:0]` 正好承载 8 个 FP32 bit pattern。共享 datapath 的 lane 8..15 没有对应 TF32 输入 slot，必须由 lane valid mask 关闭。

### 2.3 集成边界

RTL 只提供一个综合/集成入口：`mid_fp_dot_prod`。TF32、BF16、FP16 由同一套 shared datapath 执行，上层通过 `a_mode_i` / `b_mode_i` 分别选择 A/B 精度。

不再提供按精度拆分的兼容 wrapper，避免上层误实例化多个 wrapper 后复制多份 mid-FP core。若某个旧单元测试需要数组形式输入，应在 testbench 内完成 pack，不应在 RTL 中增加 wrapper module。

## 3. Pipeline

实现为 5-stage FDA pipeline，与当前 FP16/BF16 datapath 对齐。

| Stage | RTL payload | 功能 |
| --- | --- | --- |
| S0 | `stage0_data_t` | 输入寄存；按 `a_mode_i` / `b_mode_i` 解码 TF32/BF16/FP16 A/B；生成 lane valid mask；执行 C operand `scale-input-d` 预处理并解码 FP32 C；NaN/Inf/`0*Inf` 特殊值检测 |
| S1 | `stage1_data_t` | 16 路 11-bit significand 乘法；product sign/exponent/zero 生成；平衡比较树搜索并寄存 `emax` |
| S2 | `stage2_data_t` | product/C 转换到 F=25；使用寄存后的 `emax` 对齐到 signed Q7.25 |
| S3 | `stage3_data_t` | 16 products + C 的 33-bit signed Q7.25 累加；无效 lane 累加项为 0 |
| S4 | `stage4_data_t` | 特殊值选择或 FP32 normalize + RZ pack |

Latency 为 5 个 `pipeline_reg` stage。无 stall 时，输入 fire 后第 5 个有效流水输出对应结果；持续 ready 时可每周期吞吐 1 个 dot。

说明：当前 TF32 独立实现是 4-stage。合并到 `mid_fp_dot_prod` 后，TF32 latency 增加到 5-stage，但吞吐保持 1 req/cycle。

## 4. TF32/BF16/FP16 解码

S0 将三种输入格式统一解码成：

```systemverilog
typedef struct packed {
    logic                    valid;
    logic                    sign;
    logic [10:0]             sig;
    logic signed [9:0]       exp;
    logic                    is_zero;
    logic                    is_inf;
    logic                    is_nan;
} mid_fp_dec_t;
```

`valid=0` 的 lane 必须满足：

```text
sig = 0
exp = 0
is_zero = 1
is_inf = 0
is_nan = 0
```

并且不参与 special 统计、`emax` 搜索和普通累加。

### 4.1 TF32 解码

TF32 模式外部接收 FP32 bit pattern，内部只保留 FP32 的 sign、8-bit exponent 和 fraction 高 10 bit：

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

| 条件 | 类型 | valid | significand | unbiased exponent |
| --- | --- | ---: | --- | --- |
| `lane >= 8` | disabled | 0 | 0 | 0 |
| `exp == 0 && tf32_frac == 0` | zero | 1 | 0 | 0 |
| `exp == 0 && tf32_frac != 0` | subnormal | 1 | `{1'b0, tf32_frac}` | -126 |
| `0 < exp < 255` | normal | 1 | `{1'b1, tf32_frac}` | `exp - 127` |
| `exp == 255 && fp32_frac == 0` | infinity | 1 | 0 | 0 |
| `exp == 255 && fp32_frac != 0` | NaN | 1 | 0 | 0 |

注意：

* NaN 判断使用原始 FP32 fraction，即使 NaN payload 只落在低 13 bit，也必须保持 NaN。
* 有限输入先做 TF32 RZ 截断再进入乘法；若 FP32 subnormal 的高 10 bit fraction 全 0，则该 lane 在 TF32 datapath 中视为 zero。
* 本规格不做 FP32 到 TF32 的 RNE，也不保留 sticky bit。

### 4.2 BF16 解码

BF16 格式：

```text
sign: 1 bit
exp : 8 bits
frac: 7 bits
bias: 127
```

分类：

| 条件 | 类型 | valid | significand | unbiased exponent |
| --- | --- | ---: | --- | --- |
| `exp == 0 && frac == 0` | zero | 1 | 0 | 0 |
| `exp == 0 && frac != 0` | subnormal | 1 | `{1'b0, frac, 3'b000}` | -126 |
| `0 < exp < 255` | normal | 1 | `{1'b1, frac, 3'b000}` | `exp - 127` |
| `exp == 255 && frac == 0` | infinity | 1 | 0 | 0 |
| `exp == 255 && frac != 0` | NaN | 1 | 0 | 0 |

### 4.3 FP16 解码

FP16 格式：

```text
sign: 1 bit
exp : 5 bits
frac: 10 bits
bias: 15
```

分类：

| 条件 | 类型 | valid | significand | unbiased exponent |
| --- | --- | ---: | --- | --- |
| `exp == 0 && frac == 0` | zero | 1 | 0 | 0 |
| `exp == 0 && frac != 0` | subnormal | 1 | `{1'b0, frac}` | -14 |
| `0 < exp < 31` | normal | 1 | `{1'b1, frac}` | `exp - 15` |
| `exp == 31 && frac == 0` | infinity | 1 | 0 | 0 |
| `exp == 31 && frac != 0` | NaN | 1 | 0 | 0 |

说明：TF32 和 BF16 的 raw exponent 都是 8 bit、bias 都是 127；FP16 raw exponent 是 5 bit、bias 是 15。三者 decode 后统一使用 signed `EXP_W=10` 的 unbiased exponent，后续 product exponent adder、`emax`、alignment exponent subtract 都可共享。

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

所有 A/B special 统计必须受 `valid` gating。TF32 模式下 lane 8..15 即使对应内部临时信号为 X 或输入 bus 其他 bit pattern 为 NaN/Inf，也不得影响最终结果。

### 6.1 NaN

任一条件成立时输出 canonical NaN：

```text
任意 valid A[k] 是 NaN
任意 valid B[k] 是 NaN
C 是 NaN
任意 valid A[k] × B[k] 出现 0 × ∞ 或 ∞ × 0
同时存在 +∞ 和 -∞
`a_mode_i` 或 `b_mode_i` 为 reserved 且实现选择防御性返回 NaN
```

输出：

```text
32'h7fff_ffff
```

### 6.2 Inf

对每个 valid 乘积：

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

统计所有 valid product infinity 和 C infinity：

| 条件 | 输出 |
| --- | --- |
| 同时存在 `+∞` 和 `-∞` | `32'h7fff_ffff` |
| 只存在 `+∞` | `32'h7f80_0000` |
| 只存在 `-∞` | `32'hff80_0000` |
| 不存在 Inf / NaN | 进入普通 datapath |

## 7. MID-FP Product

对每个 lane：

```text
sign_p[k] = sign_a[k] ^ sign_b[k]
sig_p[k]  = sig_a[k] × sig_b[k]
exp_p[k]  = exp_a[k] + exp_b[k]
```

三种输入统一映射到 Q1.10 significand：

```text
TF32 sig = {hidden, frac[9:0]}
BF16 sig = {hidden, frac[6:0], 3'b000}
FP16 sig = {hidden, frac[9:0]}
```

统一乘积为：

```text
Q1.10 × Q1.10 = Q2.20
```

| 字段 | RTL 位宽 | 数学说明 |
| --- | ---: | --- |
| `lane_valid[k]` | 1 | lane 是否参与 special / `emax` / sum |
| `sign_p[k]` | 1 | product 符号 |
| `sig_p[k]` | 22 | Q2.20 product significand |
| `exp_p[k]` | signed 10 | `exp_a + exp_b` |
| `is_zero_p[k]` | 1 | zero、special 或 invalid lane 不参与普通累加 |

Product 不进行 normalize。例如 `1.5 × 1.5` 保持 `2.25 × 2^(ea+eb)`，不改写成 `1.125 × 2^(ea+eb+1)`。

TF32 模式下：

```text
lane_valid[0..7]  = 1
lane_valid[8..15] = 0
```

BF16/FP16 模式下：

```text
lane_valid[0..15] = 1
```

## 8. Emax 与 F=25 对齐

最大指数：

```text
emax = max(exp_c, exp_p[k] for all valid nonzero product lanes)
```

Zero lane、special lane、invalid lane 不参与 `emax` 搜索。若 C 和所有 valid product 都为 zero，则 S2 输出 zero payload。

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

若 `lane_valid[k] == 0` 或 `is_zero_p[k] == 1`，则：

```text
aligned_p_signed[k] = 0
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
localparam int NUM_ELEMS          = 16;
localparam int SIG_W              = 11;
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
BF16/FP16: 16 × max(product significand) + max(C significand)
         < 16 × 4 + 2
         = 66

TF32:      8 × max(product significand) + max(C significand)
         < 8 × 4 + 2
         = 34
```

因此 signed Q7.25 覆盖 `[-128, +127]`，足够表达所有对齐后的有限累加结果。

| 字段 | 位宽 | 说明 |
| --- | ---: | --- |
| `aligned_p_signed[k]` | 33 | signed Q7.25 product |
| `aligned_c_signed` | 33 | signed Q7.25 C |
| `sum` / `sum_fixed` | 33 | signed Q7.25 累加结果 |

注意：`aligned_prod_flat` 是 `16 × 33 = 528 bit` 的 packed bus，但每个 lane 仍是 33 bit。TF32 模式下高 8 lane 对应项为 0。

## 10. Accumulate

S3 计算：

```text
sum_fixed = aligned_c_signed
          + aligned_p_signed[0]
          + aligned_p_signed[1]
          + ...
          + aligned_p_signed[15]
```

TF32 模式下，`aligned_p_signed[8..15]` 必须为 0，因此数学等价于 K=8 dot。

实现中可以沿用 combinational loop 累加到 `sum_acc_tmp`。由于所有输入都已经完成 F=25 RZ 对齐，累加过程不再产生额外舍入。数学上加法顺序不影响结果；实现形式可后续替换为 balanced adder tree 以优化时序。

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

建议实现将这些功能以内联 function、struct payload 和 5 个 `pipeline_reg` 实例组织在 `mid_fp_dot_prod` 中。

| 规格功能 | RTL 实现 |
| --- | --- |
| TF32/BF16/FP16 decode | `function automatic mid_fp_dec_t decode_mid_fp` |
| FP32 decode | `function automatic fp32_dec_t decode_fp32` |
| lane valid mask | S0 根据 `a_mode_i` / `b_mode_i` 和 lane index 生成 |
| special case handler | S0 `always_comb`，所有 A/B special 统计受 `lane_valid` gating |
| shared product array | S1 `always_comb` loop，16 路 `11 × 11` |
| product exponent adder | S1 `a_exp + b_exp`，16 路 signed 10-bit |
| max exponent search | S1 `always_comb` 平衡比较树，只搜索 valid nonzero product 和 nonzero C，并随 `stage1_data_t` 寄存 |
| align to F25 | `function automatic align_fixed_rz` |
| fixed-point accumulate | S3 `always_comb` |
| FP32 normalize RZ | `function automatic pack_fp32_rz` |
| pipeline registers | `pipeline_reg` × 5 |

共享边界：

| 类型 | 是否共享 | 说明 |
| --- | --- | --- |
| TF32/BF16/FP16 multiplier | 是 | 三者统一 11-bit significand |
| TF32/BF16/FP16 exponent add | 是 | decode 后统一 signed unbiased exponent |
| TF32/BF16/FP16 align/pack | 是 | 均输出 FP32，F=25 |
| F6/F8 core | 否 | K32、FP8/FP6 decode/MX scale 语义不同 |
| FP4 core | 否 | K64、FP4 scale block 语义不同 |
| INT8 core | 否 | 整数乘加、overflow/saturation 语义不同 |

## 13. 关键设计点总结

| 设计点 | RTL 对齐后的规格 |
| --- | --- |
| 主模块 | `mid_fp_dot_prod` |
| 输入格式 | `a_mode_i` / `b_mode_i` = TF32/BF16/FP16 |
| valid-ready | 主模块支持 `in_vld_i/in_rdy_o/out_vld_o/out_rdy_i` |
| TF32 packed 布局 | `a_vec_i[k*32 +: 32]` / `b_vec_i[k*32 +: 32]`，`k=0..7` |
| BF16/FP16 packed 布局 | `a_vec_i[k*16 +: 16]` / `b_vec_i[k*16 +: 16]`，`k=0..15` |
| TF32 高 lane | lane 8..15 invalid，所有 special / `emax` / sum 逻辑必须 mask |
| product 是否 normalize | 不 normalize |
| product significand | 22 bit Q2.20 |
| product exponent RTL 位宽 | signed 10 |
| 对齐基准 | `emax = max(C exponent, valid product exponents)` |
| 内部对齐精度 | F = 25 |
| product 对齐前转换 | `Q2.20 << 5 = Q2.25` |
| C 对齐前转换 | `Q1.23 << 2 = Q1.25` |
| 对齐右移舍入 | RZ，直接截断 |
| 累加格式 | signed Q7.25 |
| 单 lane 累加位宽 | 33 bit |
| FP32 输出舍入 | RZ 到 23 fractional bits |
| NaN 输出 | `32'h7fff_ffff` |
| FP32 overflow | signed infinity |
| TF32 latency | 统一为 5-stage，比旧 TF32 独立 core 增加 1 stage |
| BF16/FP16 latency | 5-stage，与旧 FP16/BF16 core 一致 |

## 14. 数学等价表达

在无 NaN / Inf 的情况下，该单元实现：

```text
D = Normalize_FP32_RZ {
        2^emax × [
            Trunc_F25(sc × 2^(ec - emax))
          + Σ[k in valid lanes] Trunc_F25(sa[k] × sb[k] × 2^(ea[k] + eb[k] - emax))
        ]
    }
```

其中：

```text
F = 25
valid lanes = 0..7  for TF32
valid lanes = 0..15 for BF16/FP16
```

`Trunc_F25` 表示保留 25 个 fractional bits，低位直接截断。

TF32 有限输入在进入上述数学表达前先做：

```text
TF32_RZ(x) = {x.sign, x.exp, x.frac[22:13]}
```

## 15. 验证计划

该 spec 对应新模块，当前状态为待实现。建议按以下顺序验证。

已知等价基准：

| 模式 | 参考实现 |
| --- | --- |
| TF32 | `src/main/tf32_dot_prod.sv` |
| BF16 | `src/main/fp16_dot_prod.sv` with `fmt_is_bf16_i=1` |
| FP16 | `src/main/fp16_dot_prod.sv` with `fmt_is_bf16_i=0` |

单元级 directed 覆盖：

| 类型 | 场景 |
| --- | --- |
| Basic TF32 | 8 路 `1.0f * 1.0f` 输出 `8.0f` |
| Basic BF16 | 16 路 `1.0bf16 * 1.0bf16` 输出 `16.0f` |
| Basic FP16 | 16 路 `1.0h * 1.0h` 输出 `16.0f` |
| C-only | A/B 全 zero，输出 C |
| Cancellation | 正负 product 抵消 |
| TF32 lane mask | lane 8..15 关闭；高 lane 临时值为 NaN/Inf/random 时结果不变 |
| Special | NaN、`0*Inf`、`+Inf`、`-Inf`、正负 Inf 冲突 |
| RZ 边界 | 大指数差导致 shifted-out bits 截断，FP32 normal/subnormal/overflow pack |
| Backpressure | `out_rdy_i=0` 时 valid/data 保持 |
| Mixed mode pipeline | 连续发送 TF32 -> BF16 -> FP16 -> TF32，检查顺序和结果 |

随机等价覆盖：

```text
mid_fp_dot_prod(mode=TF32) == tf32_dot_prod
mid_fp_dot_prod(mode=BF16) == fp16_dot_prod(fmt_is_bf16_i=1)
mid_fp_dot_prod(mode=FP16) == fp16_dot_prod(fmt_is_bf16_i=0)
```

顶层集成覆盖：

| 类型 | 场景 |
| --- | --- |
| Dense dispatch | `dot_cluster_top` 将 TF32/BF16/FP16 发入同一个 `mid_fp_dot_prod` |
| Sparse dispatch | A-side 2:4 compaction 后的 physical vector 发入 `mid_fp_dot_prod` |
| Metadata alignment | TF32/BF16/FP16 response metadata 均使用 5-cycle latency |
| Resource group | TF32/BF16/FP16 均归入 `SHARE_GROUP_MIDFP` |

目标：

```text
Verilator lint clean
MID-FP unit directed/regression PASS
dot_cluster_top regression PASS
mid_fp_dot_prod line/branch coverage >= 90%
dot_cluster_top branch coverage = 100%
```
