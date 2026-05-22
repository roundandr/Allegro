# cocotb + MMA-Sim for NVFP4 Dot

这个目录给 `64-element NVFP4 GDFS dot product` 单元提供一个最小 `cocotb` 验证骨架。

设计取舍：

* `golden` 直接调用 `MMA-Sim` 的 `nv_fused_dot_add_with_block_scale()`。
* `256-bit FP4` 和 `32-bit scale` 的拆包、以及 `NaN/Inf` 顶层特判，在本地 adapter 中完成。
* 这样不用把单个 dot 单元硬塞进 `m16n8k64` / `m128n8k64` 的 tile 接口里。

## 目录说明

* `mma_sim_nvfp4_ref.py`: 将 DUT 原始端口打包格式转换为 MMA-Sim reference 输入。
* `test_nvfp4_dot.py`: `cocotb` 测试。
* `Makefile`: 最小运行入口。

## 依赖

需要本地 Python 环境至少安装：

```bash
pip install cocotb torch
```

如果你用 `pytest` 驱动，也可以补：

```bash
pip install pytest pytest-xdist
```

## 运行

当前仓库默认就是：

```bash
cd src/test/cocotb
make
```

常用可调参数：

```bash
NUM_CASES=1000 RANDOM_SEED=1234 make
```

如果后面 DUT 拆成多个 RTL 文件，再覆盖 `VERILOG_SOURCES`：

```bash
make TOPLEVEL=fp4_dot_prod \
  VERILOG_SOURCES="/abs/path/to/fp4_dot_prod.sv /abs/path/to/dependency_0.sv /abs/path/to/dependency_1.sv"
```

## 接口假设

`test_nvfp4_dot.py` 当前按 `fp4_dot_prod.sv` 的真实端口名驱动：

* `clk`
* `rst_n`
* `in_vld_i`
* `in_rdy_o`
* `a_fp4_i`
* `b_fp4_i`
* `a_sf_i`
* `b_sf_i`
* `c_fp32_i`
* `out_vld_o`
* `out_rdy_i`
* `d_fp32_o`

如果你的 RTL 端口名不同，直接改 `test_nvfp4_dot.py` 里的驱动函数即可。

## 为什么 `n_fractional_bits = 35`

`MMA-Sim` 在 `k == 64` 的 `mxf4nvf4` block-scale 路径上，内部使用 35 个累加 fractional bits。这个设置来自 `MMA-Sim` 的 `tcgen05mma_block_scale` / `mma_block_scale` 实现，和 NVFP4 block-scale 点积路径一致。
