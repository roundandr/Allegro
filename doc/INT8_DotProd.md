# 32-Element INT8 Dot Product Unit Spec

## 1. 设计目标

该单元用于实现 32 个 8-bit 整数元素的点积累加：

$$
D = C + \sum_{k=0}^{31} A_k \times B_k
$$

其中：

* 输入向量长度：32
* 输入数据格式：INT8 / UINT8，可通过符号模式选择
* 累加输入：INT32 `C`
* 输出格式：INT32 `D`
* 中间乘积保持精确整数结果
* 累加路径使用扩展位宽，避免 32 路乘积求和阶段溢出
* 默认 INT32 输出采用 two's-complement wrap，支持可选 saturation

本单元是整数点积路径，不包含浮点 special value、指数对齐、归一化和舍入逻辑。

---

## 2. 顶层接口定义

| 接口名称 | 位宽 | 说明 |
| --- | --: | --- |
| `clk` | 1 | 时钟信号 |
| `rst_n` | 1 | 低有效复位 |
| `in_vld_i` | 1 | 输入有效信号 |
| `in_rdy_o` | 1 | 输入就绪信号 |
| `a_vec_i` | 32 x 8 | 8-bit 输入向量 A，共 32 个元素 |
| `b_vec_i` | 32 x 8 | 8-bit 输入向量 B，共 32 个元素 |
| `c_i` | 32 | INT32 累加输入 C |
| `a_unsigned_i` | 1 | A 操作数符号模式，0 表示 signed，1 表示 unsigned |
| `b_unsigned_i` | 1 | B 操作数符号模式，0 表示 signed，1 表示 unsigned |
| `sat_en_i` | 1 | 输出饱和使能，0 表示 wrap，1 表示 saturate 到 INT32 范围 |
| `out_vld_o` | 1 | 输出有效信号 |
| `out_rdy_i` | 1 | 下游就绪信号 |
| `d_o` | 32 | INT32 输出结果 D |
| `overflow_o` | 1 | 扩展累加结果超出 INT32 可表示范围 |

握手语义：

```text
in_fire  = in_vld_i  & in_rdy_o
out_fire = out_vld_o & out_rdy_i
```

流水线采用标准 `vld/rdy` 反压机制：

* `out_rdy_i = 0` 时，各级 valid 和数据保持；
* 反压向前传播，`in_rdy_o` 拉低；
* `rst_n = 0` 时，所有 stage valid 清零，`out_vld_o = 0`。

---

## 3. 数据格式定义

### 3.1 8-bit 输入操作数

每个输入元素为 8 bit，实际数值由符号模式决定。

| 模式 | 控制位 | 数值范围 | 解码规则 |
| --- | --: | ---: | --- |
| S8 | `unsigned = 0` | [-128, 127] | two's-complement signed integer |
| U8 | `unsigned = 1` | [0, 255] | unsigned integer |

对第 `k` 个元素：

$$
a_k =
\begin{cases}
\operatorname{signed8}(a\_vec\_i[k]), & a\_unsigned\_i = 0 \\
\operatorname{unsigned8}(a\_vec\_i[k]), & a\_unsigned\_i = 1
\end{cases}
$$

$$
b_k =
\begin{cases}
\operatorname{signed8}(b\_vec\_i[k]), & b\_unsigned\_i = 0 \\
\operatorname{unsigned8}(b\_vec\_i[k]), & b\_unsigned\_i = 1
\end{cases}
$$

若仅实现标准 signed INT8 点积，可将：

```text
a_unsigned_i = 1'b0
b_unsigned_i = 1'b0
```

---

### 3.2 INT32 C 和 D

`c_i` 与 `d_o` 均采用 32-bit two's-complement 整数格式。

INT32 可表示范围为：

$$
INT32\_MIN = -2^{31}
$$

$$
INT32\_MAX = 2^{31} - 1
$$

输出溢出策略：

| 条件 | `sat_en_i = 0` | `sat_en_i = 1` |
| --- | --- | --- |
| 扩展累加结果在 INT32 范围内 | 输出低 32 bit，`overflow_o = 0` | 输出原值，`overflow_o = 0` |
| 扩展累加结果大于 `INT32_MAX` | 输出低 32 bit，`overflow_o = 1` | 输出 `0x7fffffff`，`overflow_o = 1` |
| 扩展累加结果小于 `INT32_MIN` | 输出低 32 bit，`overflow_o = 1` | 输出 `0x80000000`，`overflow_o = 1` |

默认推荐 `sat_en_i = 0`，与普通 two's-complement integer adder 的 wrap 行为一致。

---

## 4. 运算语义

目标计算为：

$$
D = C + \sum_{k=0}^{31} A_k B_k
$$

整数路径中，每个乘积为精确整数：

$$
P_k = A_k B_k
$$

不存在：

* NaN / Inf
* subnormal
* 指数对齐
* normalization
* rounding

所有中间计算均按 two's-complement 整数语义实现。

---

# 5. INT8 计算流程

## 5.1 Step 1：Input Decode

该阶段完成 32 路 A/B 操作数的符号扩展或零扩展。

对每个 lane：

```text
if unsigned:
    operand_ext = {1'b0, operand[7:0]}
else:
    operand_ext = {operand[7], operand[7:0]}
```

推荐统一扩展为 signed 9-bit 内部操作数，覆盖 S8、U8，再生成 signed 18-bit product。

### Decode 输出接口

| 接口名称 | 位宽 | 说明 |
| --- | --: | --- |
| `a_ext_o[k]` | 9 | 第 k 个 A 操作数，signed 扩展后整数 |
| `b_ext_o[k]` | 9 | 第 k 个 B 操作数，signed 扩展后整数 |

---

## 5.2 Step 2：Exact 8x8 Product

该阶段计算 32 路精确乘积：

$$
P_k = a_k \times b_k
$$

### 5.2.1 乘积范围

不同符号模式下的单项乘积范围如下：

| A 模式 | B 模式 | 最小乘积 | 最大乘积 | 推荐 product 位宽 |
| --- | --- | --: | --: | --: |
| S8 | S8 | -16256 | 16384 | signed 18 |
| S8 | U8 | -32640 | 32385 | signed 18 |
| U8 | S8 | -32640 | 32385 | signed 18 |
| U8 | U8 | 0 | 65025 | signed 18 |

统一使用 signed 18-bit product：

```text
PROD_W = 18
```

signed 18-bit 范围为：

$$
[-2^{17}, 2^{17}-1]
$$

可覆盖全部 8-bit 整数乘积模式。

### Product 输出接口

| 接口名称 | 位宽 | 说明 |
| --- | --: | --- |
| `prod_o[k]` | 18 | 第 k 个精确整数乘积 |

实现要求：

* 乘法器输入按 Step 1 的符号/零扩展结果解释；
* 乘积必须精确，不允许截断；
* 乘积阶段不做 saturation；
* 乘积阶段不产生 overflow。

---

## 5.3 Step 3：32-Lane Product Reduction

该阶段计算 32 个乘积的局部和：

$$
P_{\text{sum}} = \sum_{k=0}^{31} P_k
$$

### 5.3.1 局部和范围

最大正向范围来自 U8 x U8：

$$
32 \times 255 \times 255 = 2{,}080{,}800
$$

最小负向范围来自 S8 x U8 或 U8 x S8：

$$
32 \times (-128) \times 255 = -1{,}044{,}480
$$

signed 22-bit 范围为：

$$
[-2^{21}, 2^{21}-1]
$$

即：

$$
[-2{,}097{,}152, 2{,}097{,}151]
$$

因此 32 路 product reduction 推荐使用：

```text
PSUM_W = 22
```

若设计只支持 S8 x S8，`PSUM_W = 21` 已足够；为统一模式，本规格固定使用 22 bit。

### 5.3.2 加法树结构

推荐使用平衡加法树或 CSA tree：

```text
32 inputs:
  32 product terms

Stage A: 32 -> 16
Stage B: 16 -> 8
Stage C: 8 -> 4
Stage D: 4 -> 2
Stage E: 2 -> 1
```

若使用 CSA reduction，最终一级使用 CPA 得到 `P_sum`。

该阶段只做整数加法，因此：

* 不需要浮点加法器；
* 不需要指数比较；
* 不需要 sticky / guard / round bit；
* 不需要中间 rounding。

---

## 5.4 Step 4：Add INT32 C

该阶段计算扩展精度结果：

$$
S_{\text{sum}} = \operatorname{sext}(C) + \operatorname{sext}(P_{\text{sum}})
$$

### 5.4.1 扩展累加位宽

`C` 为 signed INT32：

$$
[-2^{31}, 2^{31}-1]
$$

`P_sum` 最大正值小于：

$$
2^{21}
$$

因此 `C + P_sum` 需要 33-bit signed 扩展结果覆盖：

```text
SUM_W = 33
```

signed 33-bit 范围为：

$$
[-2^{32}, 2^{32}-1]
$$

可覆盖 INT32 C 与 32 路 INT8 product sum 的精确和。

### Add C 输出接口

| 接口名称 | 位宽 | 说明 |
| --- | --: | --- |
| `sum_o` | 33 | 扩展精度累加结果 |
| `d_o` | 32 | INT32 输出结果 |
| `pos_overflow_o` | 1 | `sum_o > INT32_MAX` |
| `neg_overflow_o` | 1 | `sum_o < INT32_MIN` |
| `overflow_o` | 1 | `pos_overflow_o | neg_overflow_o` |

---

## 5.5 Step 5：INT32 Pack

该逻辑合并在 S3 末端，将 33-bit 扩展结果写回为 32-bit INT32，不单独占用流水级。

### 5.5.1 Wrap 模式

当 `sat_en_i = 0`：

```text
d_o = sum_o[31:0]
```

`overflow_o` 仍然报告真实数学结果是否超出 INT32 范围。

### 5.5.2 Saturation 模式

当 `sat_en_i = 1`：

```text
if pos_overflow:
    d_o = 32'h7fff_ffff
else if neg_overflow:
    d_o = 32'h8000_0000
else:
    d_o = sum_o[31:0]
```

---

# 6. Pipeline

| Stage | 名称 | 主要功能 |
| --- | --- | --- |
| S0 | Input Decode / Product Generation | 输入寄存、S8/U8 decode、32 路 9-bit 统一 signed operand 精确整数乘法，输出 signed 18-bit product |
| S1 | Product Reduction | 32 路 product reduction，完成 `32 -> 16 -> 8 -> 4 -> 2 -> 1`，输出 signed 22-bit `P_sum` |
| S3 | Add C / Overflow Check / INT32 Pack | `P_sum + C`，得到 signed 33-bit `S_sum`，生成 overflow，并在 S3 末端完成 wrap 或 saturate 输出 |

整数路径的关键路径通常位于 S0 乘法器阵列和 S1 reduction tree。当前实现将 product reduction 合并为一级流水：

```text
S1: 32 -> 16 -> 8 -> 4 -> 2 -> 1
```

---

# 7. 子模块划分

## 7.1 `int8_decode_unit`

### 功能

将 packed 8-bit 输入解码为 signed 扩展整数。

### 接口定义

| 接口名称 | 位宽 | 说明 |
| --- | --: | --- |
| `x_i` | 8 | 8-bit 输入 |
| `unsigned_i` | 1 | 0: S8，1: U8 |
| `x_ext_o` | 9 | signed 9-bit 扩展输出 |

### 实现要点

* S8 模式执行符号扩展；
* U8 模式执行零扩展；
* 输出统一按 signed 9-bit 参与后续乘法。

---

## 7.2 `int8_product_unit`

### 功能

计算单 lane 乘积：

$$
P_k = A_k B_k
$$

### 接口定义

| 接口名称 | 位宽 | 说明 |
| --- | --: | --- |
| `a_ext_i` | 9 | signed 扩展后的 A |
| `b_ext_i` | 9 | signed 扩展后的 B |
| `prod_o` | 18 | 精确 product |

### 实现要点

实际乘法只需要 8x8 有效位参与，可根据 `a_unsigned_i` / `b_unsigned_i` 选择 signed 或 unsigned multiplier 实现：

```text
S8 x S8: signed   x signed
S8 x U8: signed   x unsigned
U8 x S8: unsigned x signed
U8 x U8: unsigned x unsigned
```

RTL 也可以统一先扩展到 signed 9-bit，再使用 signed multiplier 生成 18-bit product。

---

## 7.3 `int8_reduction_unit`

### 功能

累加 32 个 signed 18-bit product：

$$
P_{\text{sum}} = \sum_{k=0}^{31} P_k
$$

### 接口定义

| 接口名称 | 位宽 | 说明 |
| --- | --: | --- |
| `prod_i[31:0]` | 32 x 18 | 32 个 product |
| `psum_o` | 22 | 32 路乘积局部和 |

### 实现要点

* 可采用 binary adder tree；
* 可采用 CSA tree 加末级 CPA；
* 每一级加法需要按目标输出范围保留足够符号扩展位；
* 不允许中间截断。

---

## 7.4 `int32_accum_unit`

### 功能

将 product sum 与 INT32 C 相加：

$$
S_{\text{sum}} = C + P_{\text{sum}}
$$

### 接口定义

| 接口名称 | 位宽 | 说明 |
| --- | --: | --- |
| `psum_i` | 22 | 32 路 product sum |
| `c_i` | 32 | INT32 累加输入 |
| `sum_o` | 33 | 扩展精度累加结果 |
| `pos_overflow_o` | 1 | 正溢出 |
| `neg_overflow_o` | 1 | 负溢出 |
| `overflow_o` | 1 | 任意方向溢出 |

### Overflow 判定

```text
INT32_MAX_EXT = 33'sh0_7fff_ffff
INT32_MIN_EXT = 33'sh1_8000_0000

pos_overflow_o = (sum_o > INT32_MAX_EXT)
neg_overflow_o = (sum_o < INT32_MIN_EXT)
overflow_o     = pos_overflow_o | neg_overflow_o
```

---

## 7.5 `int32_pack_logic`

### 功能

作为 S3 末端组合逻辑，根据 `sat_en_i` 将 33-bit 扩展结果转换为 INT32 输出。

### 接口定义

| 接口名称 | 位宽 | 说明 |
| --- | --: | --- |
| `sum_i` | 33 | 扩展精度累加结果 |
| `sat_en_i` | 1 | saturation 使能 |
| `pos_overflow_i` | 1 | 正溢出 |
| `neg_overflow_i` | 1 | 负溢出 |
| `d_o` | 32 | INT32 输出 |

---

# 8. 边界用例

## 8.1 全零输入

若 `A_k = 0` 或 `B_k = 0` 对所有 lane 成立：

$$
D = C
$$

---

## 8.2 S8 x S8 最大正值

当：

```text
A_k = -128
B_k = -128
C   = 0
```

则：

$$
P_k = 16384
$$

$$
D = 32 \times 16384 = 524288
$$

输出：

```text
d_o = 32'h0008_0000
overflow_o = 1'b0
```

---

## 8.3 U8 x U8 最大正值

当：

```text
A_k = 255
B_k = 255
C   = 0
```

则：

$$
D = 32 \times 65025 = 2080800
$$

输出：

```text
d_o = 32'h001f_c020
overflow_o = 1'b0
```

---

## 8.4 INT32 正溢出

当：

```text
C = 32'h7fff_ffff
P_sum = 1
```

则扩展结果为：

$$
S_{\text{sum}} = 2^{31}
$$

输出：

| `sat_en_i` | `d_o` | `overflow_o` |
| --- | --- | --- |
| 0 | `32'h8000_0000` | 1 |
| 1 | `32'h7fff_ffff` | 1 |

---

## 8.5 INT32 负溢出

当：

```text
C = 32'h8000_0000
P_sum = -1
```

则扩展结果为：

$$
S_{\text{sum}} = -2^{31} - 1
$$

输出：

| `sat_en_i` | `d_o` | `overflow_o` |
| --- | --- | --- |
| 0 | `32'h7fff_ffff` | 1 |
| 1 | `32'h8000_0000` | 1 |

---

# 9. 与 FP8 点积单元的主要差异

| 项目 | FP8 Dot Product | INT8 Dot Product |
| --- | --- | --- |
| 输入格式 | E4M3 / E5M2 | S8 / U8 |
| 累加输入 | FP32 | INT32 |
| 输出格式 | FP32 | INT32 |
| special value | NaN / Inf / 0 x Inf | 无 |
| 中间乘积 | significand x significand + exponent | 8-bit integer x 8-bit integer |
| 对齐方式 | 按最大 exponent 对齐到 fixed-point 域 | 无需对齐 |
| 舍入 | RZ | 无舍入 |
| 归一化 | FP32 normalize | 无 |
| 溢出处理 | FP32 Inf / subnormal / zero | wrap 或 saturate 到 INT32 |

---
