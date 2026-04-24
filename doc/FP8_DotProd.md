# 32-Element FP8 Dot Product Unit Spec Based on FDA Algorithm

## 1. 设计目标

该单元用于实现 32 个 FP8 元素的点积累加：

$$
D = C + \sum_{k=0}^{31} A_k \times B_k
$$

其中：

* 输入向量长度：32
* 输入数据格式：FP8

  * 支持 E4M3 / E5M2，可通过参数选择
* 累加输入：FP32 `C`
* 输出格式：FP32 `D`
* 内部对齐累加精度：

$$
F = 25
$$

* 内部算法：FDA，Fused-Dot-Add
* 中间乘积不做浮点归一化
* 对齐后尾数截断，相当于 round-to-zero，RZ
* 最终 FP32 输出同样采用 RZ 舍入

---

## 2. 顶层接口定义

| 接口名称           |     位宽 | 说明                            |
| -------------- | -----: | ----------------------------- |
| `clk`          |      1 | 时钟信号                          |
| `rst_n`        |      1 | 低有效复位                         |
| `in_vld_i`     |      1 | 输入有效信号                        |
| `in_rdy_o`     |      1 | 输入就绪信号                        |
| `a_vec_i`      | 32 × 8 | FP8 输入向量 A，共 32 个元素           |
| `b_vec_i`      | 32 × 8 | FP8 输入向量 B，共 32 个元素           |
| `c_i`          |     32 | FP32 累加输入 C                   |
| `fp8_format_i` |      1 | FP8 格式选择，0 表示 E4M3，1 表示 E5M2  |
| `out_vld_o`    |      1 | 输出有效信号                        |
| `out_rdy_i`    |      1 | 下游就绪信号                        |
| `d_o`          |     32 | FP32 输出结果 D                   |

---

## 3. FP8 格式定义

### 3.1 E4M3

| 字段       | 位宽 | 说明   |
| -------- | -: | ---- |
| Sign     |  1 | 符号位  |
| Exponent |  4 | 指数字段 |
| Mantissa |  3 | 尾数字段 |

本规格对 E4M3 采用 finite-only 语义，确保 Step 1 可直接实现和验证：

* E4M3 无 `+Inf` / `-Inf` 编码；
* 当 `exp = 4'b1111` 且 `mant = 3'b111` 时，视为 NaN，符号位忽略；
* 除上述 NaN 编码外，其余 E4M3 编码均视为有限值。

---

### 3.2 E5M2

| 字段       | 位宽 | 说明   |
| -------- | -: | ---- |
| Sign     |  1 | 符号位  |
| Exponent |  5 | 指数字段 |
| Mantissa |  2 | 尾数字段 |

E5M2 通常支持 Inf / NaN 编码，因此 Special Check 阶段需要完整处理：

* NaN
* +Inf
* -Inf
* 0 × Inf
* +Inf 与 -Inf 混合

---

## 4. 运算语义

目标计算为：

$$
D = C + \sum_{k=0}^{31} A_k B_k
$$

FDA 内部将每个输入拆成：

$$
A_k = s_{a,k} \times 2^{e_{a,k}}
$$

$$
B_k = s_{b,k} \times 2^{e_{b,k}}
$$

乘积为：

$$
P_k = A_k B_k = s_k \times 2^{e_k}
$$

其中：

$$
s_k = s_{a,k} \times s_{b,k}
$$

$$
e_k = e_{a,k} + e_{b,k}
$$

注意：该乘积在 Step 2 中 **不归一化**。

例如：

$$
1.5 \times 2^{e_a} \times 1.5 \times 2^{e_b} = 2.25 \times 2^{e_a + e_b}
$$

而不是：

$$
1.125 \times 2^{e_a + e_b + 1}
$$

---

# 5. FDA 计算流程

## 5.1 Step 1：Special Value Check

该阶段检查所有输入中的特殊值。

检查对象包括：

* 32 个 `A_k`
* 32 个 `B_k`
* FP32 输入 `C`

需要检测：

| 条件                           | 输出结果             |
| ---------------------------- | ---------------- |
| 任意输入为 NaN                    | 输出 canonical NaN |
| 存在 `0 × Inf`                 | 输出 canonical NaN |
| 乘积项和 C 中同时存在 `+Inf` 与 `-Inf` | 输出 canonical NaN |
| 只存在 `+Inf`                   | 输出 `+Inf`        |
| 只存在 `-Inf`                   | 输出 `-Inf`        |
| 无特殊值                         | 进入 Step 2        |

FP32 输出 canonical NaN 固定为：

```text
0x7FFFFFFF
```

### Special Check 输出信号

| 接口名称                   | 位宽 | 说明           |
| ---------------------- | -: | ------------ |
| `has_nan_o`              |  1 | 输入中存在 NaN    |
| `has_pos_inf_o`          |  1 | 结果路径中存在 +Inf |
| `has_neg_inf_o`          |  1 | 结果路径中存在 -Inf |
| `has_zero_mul_inf_o`     |  1 | 存在 0 × Inf   |
| `special_vld_o`          |  1 | 特殊值结果有效      |
| `special_result_o`       | 32 | 特殊值输出结果      |

为保证 Step 1 可实现，special check 需要基于输入符号恢复 product infinity 的符号：

$$
sign_{p,k} = sign_{a,k} \oplus sign_{b,k}
$$

若第 `k` 路满足：

* `a_is_inf_i[k] && !b_is_zero_i[k]`，或
* `b_is_inf_i[k] && !a_is_zero_i[k]`

则该路 product 为 infinity，并根据 `sign_{p,k}` 归入 `has_pos_inf_o` 或 `has_neg_inf_o`。

若 `c_is_inf_i = 1`，则根据 `c_sign_i` 归入 `has_pos_inf_o` 或 `has_neg_inf_o`。

---

## 5.2 Step 2：FP8 Decode and Exact Product

该阶段完成：

1. FP8 解码
2. 符号提取
3. 指数恢复
4. 尾数恢复
5. 精确 significand 乘法
6. 得到非归一化乘积

### 5.2.1 FP8 Decode

每个 FP8 输入被解码为：

$$
x = s_x \times 2^{e_x}
$$

其中：

* normal number：

$$
1 \le |s_x| < 2
$$

* subnormal number：

$$
0 < |s_x| < 1
$$

* zero：

$$
s_x = 0
$$

对于 subnormal，指数使用该格式的最小 normal exponent。

例如 BF16 中：

$$
2^{-127}
$$

应表示为：

$$
0.5 \times 2^{-126}
$$

FP8 也采用同样的规则处理 subnormal。

---

### 5.2.2 E4M3 Decode 参数

| 项目            |  值 |
| ------------- | -: |
| Exponent Bits |  4 |
| Mantissa Bits |  3 |
| Bias          |  7 |
| Normal 最小指数   | -6 |
| Normal 最大指数   | +8 |

normal number：

$$
x = (-1)^s \times \left(1 + \frac{m}{2^3}\right) \times 2^{E - 7}
$$

subnormal number：

$$
x = (-1)^s \times \left(\frac{m}{2^3}\right) \times 2^{-6}
$$

其中 `exp = 4'b1111 && mant = 3'b111` 保留为 NaN；其余 `exp = 4'b1111` 且 `mant != 3'b111` 的编码按有限 normal 数处理。

---

### 5.2.3 E5M2 Decode 参数

| 项目            |   值 |
| ------------- | --: |
| Exponent Bits |   5 |
| Mantissa Bits |   2 |
| Bias          |  15 |
| Normal 最小指数   | -14 |
| Normal 最大指数   | +15 |

normal number：

$$
x = (-1)^s \times \left(1 + \frac{m}{2^2}\right) \times 2^{E - 15}
$$

subnormal number：

$$
x = (-1)^s \times \left(\frac{m}{2^2}\right) \times 2^{-14}
$$

---

### 5.2.4 Product Form

每一项乘积为：

$$
P_k = A_k B_k = s_k \times 2^{e_k}
$$

其中：

$$
s_k = s_{a,k} \times s_{b,k}
$$

$$
e_k = e_{a,k} + e_{b,k}
$$

该阶段的乘积尾数必须保持精确，不允许：

* 精度截断
* overflow
* underflow
* normalization
* rounding

---

### 5.2.5 Product Decode 输出接口

| 接口名称              |  位宽 | 说明                      |
| ----------------- | --: | ----------------------- |
| `prod_sign[k]`    |   1 | 第 k 个乘积符号               |
| `prod_sig[k]`     | 参数化 | 第 k 个非归一化乘积 significand |
| `prod_exp[k]`     |   8 | 第 k 个乘积指数               |
| `prod_is_zero[k]` |   1 | 第 k 个乘积是否为 0            |

对于 E4M3：

* 输入 significand 精度为 4 bit，包括 hidden bit
* 乘积 significand 精度为：

$$
4 + 4 = 8 \text{ bits}
$$

对于 E5M2：

* 输入 significand 精度为 3 bit，包括 hidden bit
* 乘积 significand 精度为：

$$
3 + 3 = 6 \text{ bits}
$$

为了统一硬件路径，可以统一扩展为 8-bit product significand。

---

## 5.3 Step 3：Max Exponent Search and Alignment

该阶段寻找：

$$
e_{\max} = \max { e_c, e_0, e_1, \dots, e_{31} }
$$

其中：

* `e_c` 来自 FP32 输入 C 的原始 signed exponent
* `e_k` 来自第 k 个 FP8 乘积的原始 signed exponent

---

### 5.3.1 FP32 C Decode

FP32 输入 C 被解码为：

$$
C = s_c \times 2^{e_c}
$$

normal FP32：

$$
s_c = (-1)^s \times \left(1 + \frac{m}{2^{23}}\right)
$$

subnormal FP32：

$$
s_c = (-1)^s \times \left(\frac{m}{2^{23}}\right)
$$

RTL 内部对 subnormal 直接编码为：

$$
e_c = -149
$$

---

### 5.3.2 Max Exponent Search

输入比较项数量为 33 个：

* 32 个 product exponent
* 1 个 C exponent

推荐使用比较树实现：

```text
Level 0: 33 exponents
Level 1: pairwise max
Level 2: pairwise max
Level 3: pairwise max
Level 4: pairwise max
Level 5: final max
```

输出：

| 接口名称         | 位宽 | 说明                  |
| ------------ | -: | ------------------- |
| `emax_o`     |  8 | products 和 C 中的最大原始 exponent |
| `emax_vld_o` |  1 | emax 有效             |

由于 FP8 product exponent 范围较小，而 C 是 FP32，统一使用 signed 8-bit exponent 即可覆盖：

$$
[-126, 127]
$$

零项不参与 `emax` 搜索。若 32 个 product 和 `C` 全为零，则：

* `emax_vld_o = 0`
* `emax_o` 推荐输出 `8'sd0`
* `align_unit` 直接输出全零 fixed-point 项

---

### 5.3.3 Alignment

每个乘积和 C 均对齐到 `F=25` 的 fixed-point 域。公共基准指数为：

$$
base\_exp = e_{\max} - 25
$$

在当前 RTL 中，product 和 C 会先被编码到固定 `F=25` fractional-bit 域，然后再进入对齐级。

因此对齐级本身只需要：

$$
\text{shift} = e_{\max} - e
$$

$$
\hat{s} = \operatorname{RZ}(s^{frac} \gg \text{shift})
$$

其行为为：

* `emax` 搜索只比较原始 exponent；
* 对齐级本身不再执行左移；
* magnitude 只按 `emax - e` 右移，并直接丢弃 shifted-out bits；
* 右移始终执行 `round-to-zero`；
* 若右移量大于等于操作数位宽，则输出 0。

---

### 5.3.4 对齐后定点格式

每个对齐后的乘积项表示为：

$$
\hat{s}_k \times 2^{base\_exp}
$$

由于乘积 significand 未归一化，两个 FP8 normal 数相乘后：

$$
|s_k| < 4
$$

因此单个 product aligned significand 需要至少 2 个整数 magnitude bits。

C 的 significand 满足：

$$
|s_c| < 2
$$

因此 C 需要至少 1 个整数 magnitude bit。

为了统一路径，所有 aligned term 使用统一 signed fixed-point 格式：

```text
S2.25
```

含义：

| 字段                | 位宽 | 说明            |
| ----------------- | -: | ------------- |
| Sign              |  1 | 符号位           |
| Integer magnitude |  2 | 覆盖单项乘积最大值 < 4 |
| Fraction          | 25 | FDA 指定的 F=25  |

单项 aligned term 位宽为：

$$
1 + 2 + 25 = 28 \text{ bits}
$$

---

## 5.4 Step 4：Fixed-Point Accumulation

该阶段计算：

$$
S_{\text{sum}} = \hat{s}_c + \sum_{k=0}^{31} \hat{s}_k
$$

由于所有项均已对齐到同一个基准指数：

$$
base\_exp = e_{\max} - 25
$$

因此加法只需要 fixed-point integer addition。

---

### 5.4.1 累加器位宽

单个 product aligned significand 最大幅值小于：

$$
4
$$

32 个乘积的最大幅值小于：

$$
32 \times 3.0625 = 98
$$

再加上 C，C 最大 aligned significand 小于：

$$
2
$$

因此总和最大幅值小于：

$$
100
$$

为了覆盖：

$$
[-100, +100]
$$

整数 magnitude 至少需要 7 bit，因为：

$$
2^6 = 64 < 100
$$

$$
2^7 = 128 > 100
$$

因此 accumulator fixed-point 格式为：

```text
S7.25
```

总位宽为：

$$
1 + 7 + 25 = 33 \text{ bits}
$$

RTL 采用：

```text
SUM_W = 33
```

---

### 5.4.2 加法树结构

推荐使用平衡加法树：

```text
33 inputs:
  32 product terms
  1 C term

Stage A: 33 -> 17
Stage B: 17 -> 9
Stage C: 9 -> 5
Stage D: 5 -> 3
Stage E: 3 -> 2
Stage F: 2 -> 1
```

由于 Step 3 已经完成截断，Step 4 只做 fixed-point exact addition，因此：

* 不需要浮点加法器
* 不需要动态指数对齐
* 不需要中间舍入
* 加法结果与加法顺序无关

---

## 5.5 Step 5：FP32 Normalize and RZ Rounding

Step 4 之后得到：

$$
S_{\text{sum}} \times 2^{base\_exp}
$$

需要将其归一化为 FP32。

---

### 5.5.1 Zero Check

如果：

$$
S_{\text{sum}} = 0
$$

则输出：

```text
+0
```

也可以根据设计需求保留 signed zero，但推荐输出 canonical `+0`。

---

### 5.5.2 Sign Extraction

输出符号为：

$$
sign_D = sign(S_{\text{sum}})
$$

若 `S_sum` 为负，则取绝对值进入 normalize：

$$
S_{\text{abs}} = |S_{\text{sum}}|
$$

---

### 5.5.3 Leading-One Detection

对 `S_abs` 做 leading-one detection，得到最高有效 bit 位置：

$$
lod_pos
$$

然后将其规格化为：

$$
1.xxxxx \times 2^{e_D}
$$

输出指数为：

$$
e_D = base\_exp + shift
$$

其中 `shift` 由 leading-one 位置决定。

---

### 5.5.4 FP32 Exponent Check

若归一化后的指数满足：

$$
e_D \ge 128
$$

则输出：

```text
+Inf / -Inf
```

符号由 `sign_D` 决定。

若结果落入 FP32 subnormal 区间，则需要右移生成 FP32 subnormal，并继续使用 RZ 截断。

---

### 5.5.5 RZ Rounding to FP32

FP32 fraction bits 为 23 bit。

最终 significand 使用 round-to-zero：

$$
\text{frac}*{FP32} = \text{trunc}*{23}(\text{normalized significand})
$$

也就是说：

* 不看 guard bit
* 不看 round bit
* 不看 sticky bit
* 直接丢弃 23 bit 之后的低位

---

# 6. Pipeline

| Stage | 名称                                      | 主要功能                                     |
| --- | --- | --- |
| S0    | Input Register / Decode / Product Generation | 输入寄存、FP8 解码、FP32 C 解码、特殊值检查、32 路 FP8 significand 精确乘法并生成非归一化 product |
| S1    | Max Exponent Search                     | 搜索 32 个 product 与 C 的原始 exponent 最大值 |
| S2    | Alignment                               | 计算 shift amount，对齐到 `S2.25`，并输出 `base_exp = emax - 25` |
| S3    | Fixed-Point Accumulation                | 33 输入 fixed-point 加法树，得到 `S7.25` 累加结果 |
| S4    | FP32 Normalize / RZ Round               | 归一化、溢出处理、subnormal 处理、RZ 输出 FP32         |



# 7. 子模块划分

## 7.1 `fp8_decode_unit`

### 功能

将 FP8 输入解码为：

$$
s \times 2^e
$$

### 接口定义

| 接口名称             | 位宽 | 说明                 |
| ---------------- | -: | ------------------ |
| `fp8_i`          |  8 | FP8 输入             |
| `fp8_format_i`   |  1 | 0: E4M3，1: E5M2    |
| `sign_o`         |  1 | 符号位                |
| `sig_o`          |  4 | 统一扩展后的 significand |
| `exp_o`          |  8 | signed exponent    |
| `is_zero_o`      |  1 | 是否为 zero           |
| `is_subnormal_o` |  1 | 是否为 subnormal      |
| `is_inf_o`       |  1 | 是否为 Inf            |
| `is_nan_o`       |  1 | 是否为 NaN            |

说明：

* 当 `fp8_format_i = 0`（E4M3）时，`is_inf_o` 恒为 `1'b0`；
* 当 `fp8_format_i = 0`（E4M3）且 `exp = 4'b1111 && mant = 3'b111` 时，`is_nan_o = 1'b1`；
* 当 `fp8_format_i = 1`（E5M2）时，按 E5M2 的 Inf / NaN 编码规则生成 `is_inf_o` 与 `is_nan_o`。

---

## 7.2 `fp8_product_unit`

### 功能

计算：

$$
P_k = A_k B_k
$$

但不归一化。

### 接口定义

| 接口名称          | 位宽 | 说明                        |
| ------------- | -: | ------------------------- |
| `a_sign_i`    |  1 | A 符号                      |
| `a_sig_i`     |  4 | A significand             |
| `a_exp_i`     |  8 | A exponent                |
| `b_sign_i`    |  1 | B 符号                      |
| `b_sig_i`     |  4 | B significand             |
| `b_exp_i`     |  8 | B exponent                |
| `prod_sign_o` |  1 | product 符号                |
| `prod_sig_o`  |  8 | exact product significand |
| `prod_exp_o`  |  8 | product exponent          |
| `prod_zero_o` |  1 | product 是否为 0             |

### 内部逻辑

符号：

$$
sign_k = sign_{a,k} \oplus sign_{b,k}
$$

指数：

$$
e_k = e_{a,k} + e_{b,k}
$$

尾数：

$$
s_k = s_{a,k} \times s_{b,k}
$$

---

## 7.3 `fp32_c_decode_unit`

### 功能

解码 FP32 C：

$$
C = s_c \times 2^{e_c}
$$

### 接口定义

| 接口名称               | 位宽 | 说明                         |
| ------------------ | -: | -------------------------- |
| `c_i`              | 32 | FP32 输入 C                  |
| `c_sign_o`         |  1 | C 符号                       |
| `c_sig_o`          | 24 | C significand，含 hidden bit |
| `c_exp_o`          |  8 | C signed exponent          |
| `c_is_zero_o`      |  1 | C 是否为 zero                 |
| `c_is_subnormal_o` |  1 | C 是否为 subnormal            |
| `c_is_inf_o`       |  1 | C 是否为 Inf                  |
| `c_is_nan_o`       |  1 | C 是否为 NaN                  |

---

## 7.4 `special_check_unit`

### 功能

实现 FDA Step 1。

### 接口定义

| 接口名称                | 位宽 | 说明         |
| ------------------- | -: | ---------- |
| `a_sign_i[31:0]`    | 32 | A 符号位 |
| `b_sign_i[31:0]`    | 32 | B 符号位 |
| `a_is_zero_i[31:0]` | 32 | A 是否为 zero |
| `b_is_zero_i[31:0]` | 32 | B 是否为 zero |
| `a_is_inf_i[31:0]`  | 32 | A 是否为 Inf  |
| `b_is_inf_i[31:0]`  | 32 | B 是否为 Inf  |
| `a_is_nan_i[31:0]`  | 32 | A 是否为 NaN  |
| `b_is_nan_i[31:0]`  | 32 | B 是否为 NaN  |
| `c_sign_i`          |  1 | C 符号位 |
| `c_is_inf_i`        |  1 | C 是否为 Inf  |
| `c_is_nan_i`        |  1 | C 是否为 NaN  |
| `has_nan_o`         |  1 | 输入中存在 NaN |
| `has_pos_inf_o`     |  1 | 结果路径中存在 +Inf |
| `has_neg_inf_o`     |  1 | 结果路径中存在 -Inf |
| `has_zero_mul_inf_o`|  1 | 存在 0 × Inf |
| `special_vld_o`     |  1 | 特殊值输出有效    |
| `special_result_o`  | 32 | 特殊值输出      |

实现要点：

* 对每一路 `k`，先检测 `0 × Inf`；
* 对每一路 `k`，若存在有限非零数与 Inf 相乘，则用 `a_sign_i[k] ^ b_sign_i[k]` 判定 product infinity 极性；
* `c_is_inf_i` 通过 `c_sign_i` 参与 `has_pos_inf_o` / `has_neg_inf_o` 聚合；
* 若 `has_nan_o || has_zero_mul_inf_o || (has_pos_inf_o && has_neg_inf_o)`，则 `special_result_o = 32'h7fff_ffff`；
* 若仅 `has_pos_inf_o`，则 `special_result_o = 32'h7f80_0000`；
* 若仅 `has_neg_inf_o`，则 `special_result_o = 32'hff80_0000`。

---

## 7.5 `emax_search_unit`

### 功能

搜索 33 个有效项中的最大原始 exponent。

### 接口定义

| 接口名称               |     位宽 | 说明                    |
| ------------------ | -----: | --------------------- |
| `prod_exp_i[31:0]`     | 32 × 8 | 32 个 product exponent |
| `prod_is_zero_i[31:0]` |     32 | 32 个 product 是否为 0 |
| `c_exp_i`              |      8 | C exponent            |
| `c_is_zero_i`          |      1 | C 是否为 0            |
| `emax_o`               |      8 | 最大原始 exponent |
| `emax_vld_o`           |      1 | 最大指数有效                |

实现要点：

* 仅对 `prod_is_zero_i[k] = 0` 的 product 参与比较，比较值为 `prod_exp_i[k]`；
* 仅当 `c_is_zero_i = 0` 时，C 才参与比较，比较值为 `c_exp_i`；
* 若所有输入项都为零，则 `emax_vld_o = 0`，后级按全零数据路径处理。

---

## 7.6 `align_unit`

### 功能

将 32 个 product 和 C 对齐到 `F=25` 的固定小数域，并截断到 `S2.25`。

### 接口定义

| 接口名称                   |      位宽 | 说明                               |
| ---------------------- | ------: | -------------------------------- |
| `prod_sign_i[31:0]`    |      32 | product sign                     |
| `prod_mag_i[31:0]`     | 32 × 27 | 已编码到 `F=25` fixed-point 域的 product magnitude |
| `prod_exp_i[31:0]`     |  32 × 8 | product exponent                 |
| `c_sign_i`             |       1 | C sign                           |
| `c_mag_i`              |      27 | 已编码到 `F=25` fixed-point 域的 C magnitude |
| `c_exp_i`              |       8 | C exponent                       |
| `emax_i`               |       8 | 最大原始 exponent                |
| `aligned_prod_o[31:0]` | 32 × 28 | 对齐后的 product fixed-point 值，S2.25 |
| `aligned_c_o`          |      28 | 对齐后的 C fixed-point 值，S2.25       |
| `base_exp_o`           |       8 | 公共基准指数，`base_exp_o = emax_i - 25` |

实现要点：

* product 的移位量为 `emax_i - prod_exp_i[k]`；
* C 的移位量为 `emax_i - c_exp_i`；
* 对齐级只按 magnitude 右移并执行 `RZ`；
* 若 `emax_vld = 0`，则 `aligned_prod_o`、`aligned_c_o` 和 `base_exp_o` 全部输出 0。

---

## 7.7 `fixed_accum_unit`

### 功能

计算：

$$
S_{\text{sum}} = \hat{s}_c + \sum_{k=0}^{31} \hat{s}_k
$$

### 接口定义

| 接口名称                   |      位宽 | 说明                                        |
| ---------------------- | ------: | ----------------------------------------- |
| `aligned_prod_i[31:0]` | 32 × 28 | 32 个对齐后的 product                          |
| `aligned_c_i`          |      28 | 对齐后的 C                                    |
| `sum_o`                |      33 | fixed-point 累加结果，格式为 `S7.25` |
| `sum_zero_o`           |       1 | 累加结果是否为 0                                 |

---

## 7.8 `fp32_normalize_unit`

### 功能

将 fixed-point sum 转换为 FP32。

### 接口定义

| 接口名称          | 位宽 | 说明                     |
| ------------- | -: | ---------------------- |
| `sum_i`       | 33 | fixed-point 累加结果       |
| `base_exp_i`  |  8 | 对齐使用的公共基准指数         |
| `d_o`         | 32 | FP32 输出                |
| `overflow_o`  |  1 | 输出是否 overflow 到 Inf    |
| `underflow_o` |  1 | 输出是否为 subnormal 或 zero |
| `is_zero_o`   |  1 | 输出是否为 zero             |

---
