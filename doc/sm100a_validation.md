# SM100a 单 CTA TMA/mbarrier 验证记录

查阅与验证日期：2026-09-11。语义依据为 NVIDIA PTX ISA 9.4 与 Tensor Map API；
逐项范围、合法组合、RTL 和测试对应关系见[实现矩阵](sm100a_implementation_matrix.md)。

## 工作区与环境

- 分支：`blackwell_subsystem`；基准 HEAD：`af54d8680155dbe790d82498d02486a1184677da`。
- 本次修改保留在工作区，未提交、未推送。原有未提交修改继续保留，独立副本未修改。
- 按 `AGENTS.md`，所有 RTL lint/仿真在配置远端主机的 CPU 执行；
  独立目录为 `/tmp/allegro_sm100a_complete.o6pKqT`，未使用其他远端工程的构建目录。
- Verilator 5.020、Cocotb 1.9.2、Python 3.12；随机种子 `20260813`。
- 最终源码清单含 73 个 RTL、filelist、脚本、测试与 golden 文件。
  本地文件、远端文件与清单逐项 SHA-256 一致。

清单位于本地忽略目录 `build/blackwell/sm100a_complete/final-source-manifest.json`，
SHA-256 为 `560445d50d43e8c589d8e2ebba494dd9f7a0c69c94664a1604f3e1a110bf5e9d`。
该清单对应最后一次边界修正后的源码；完整回归与修正后定向检查的顺序如下。

## RTL 结果

远端执行 `make test-blackwell`，三个顶层 lint 通过，完整回归 **13 配置、86 次测试执行通过，0 失败、0 跳过**。
相同测试在不同参数配置下分别计数，不代表 86 个不同测试函数。

| 测试组 | 配置 | 每配置用例数 | 合计 |
| --- | --- | ---: | ---: |
| TMA/mbarrier | 默认 | 23 | 23 |
| TMA/mbarrier | CMD=3、DESC=1、MSHR=3、WAIT=1、WRITE=2、CLOCK_NS=5 | 23 | 23 |
| TMA/mbarrier | CMD=2、DESC=2、MSHR=2、WAIT=2、WRITE=3、ASYNC=6 | 23 | 23 |
| TMEM | 默认、PORT_MODE=1、PORT_MODE=2 | 3 | 9 |
| Tensor wrapper | 默认、REG_SLICE=0、REG_SLICE=2 | 1 | 3 |
| Tensor subsystem | 默认；STAGING=1/REG=0/TMEM=1/SMEM_READ=1；STAGING=4/REG=2/TMEM=2 | 1 | 3 |
| 统一接口连接顶层 | 默认 | 2 | 2 |

完整回归后，只修改了 `tensormap.replace global_dim` 的 u32 零值边界：
维度值以减一编码保存，零操作数按 u32 回绕编码为 `0xffffffff`，表示 2^32。
同时在 `descriptor_replace_publish_and_reread` 中补充该断言。
对最终源码再次运行：

```bash
BLACKWELL_TEST_TOP=tma_mbarrier_tb \
  TESTCASE=descriptor_replace_publish_and_reread make test-blackwell
```

三个顶层 lint 再次通过；该测试在三组 TMA 配置中 **3/3 通过**。
末次检查是针对该边界修正的定向回归，没有将它表述为又一次完整 86 项回归。

lint 顶层为 `blackwell_tensor_subsystem`、`tma_mbarrier_subsystem`、
`blackwell_tma_mbarrier_top`。沿用项目 `-Wall -Wno-fatal` 设置：无错误，
保留宽度扩展、未使用信号/参数和变量遮蔽警告；“通过”不表示零警告。

## 覆盖与后端契约

- mbarrier：v0/v1、64-bit 对象子字访问、计数边界、旧 phase token、
  drop/noComplete、pending_count/check_layout、report 与 conditional phase、
  state/parity 等待、超时、失效重建、普通 cp.async 多 issuer 乱序完成。
- TMA：1–5D、tiled/im2col/wide、gather4/scatter4、interleave、swizzle、
  TF32/FTZ 与 packed 数据、OOB、格式转换后 completion 字节数、descriptor 更新与发布。
- copy/reduce/group：合法 type/op 矩阵、带类型的原子请求、竞争、mask、prefetch、
  多 issuer/多组、空组、`.read`、多目标部分完成、错误及资源背压。
- 排序检查使用可延迟确认、乱序响应和错误注入，检查 release/acquire、
  descriptor 重新读取、写完成、等待和错误排空不会提前完成。
- 统一接口集成测试保留实际 256B 搬运，并验证显式等待 TMA 后再进行 Tensor 计算，
  以及 Tensor COMMIT/WAIT 与 TMA 完成域独立。

参考后端验证接口协议。真实 LSU/cache 仍必须兑现确认所代表的内存可见性、
原子执行和全部 multimem 目标完成；本次没有实现物理多播网络或通用缓存系统。

PTX 的 shared→shared bulk copy 要求目标属于不同 CTA。因此本项目实现的同 CTA
shared copy 明确属于项目扩展，不计为 NVIDIA 单 CTA 指令能力。
跨 CTA SMEM、cluster multicast、`cta_group::2` 继续标记未实现。

## GPU 与独立 golden

RTX 5080 / SM120a、CUDA 13.3 生成的共同子集数据包括 16 个布局案例和
20 个格式案例；两份 JSON 中记录的生成器 SHA-256 均与当前源码一致。
测试直接比较预先保存的数据，未使用 RTL 输出生成期望值。

SM100a 专属项、map 操作和后端排序契约使用官方条款、独立模型及定向测试。
SM120a 实测结果不构成 SM100a 全功能硬件认证；项目内部 v3 descriptor
也不宣称兼容 CUDA opaque Tensor Map 的二进制布局。

## 静态检查与产物

- 三份递归 filelist 的源码引用、测试入口及修改文档的本地链接均可解析。
- Python 文件可解析；`git diff --check` 通过。
- 旧 TMA 控制协议、barrier-ID/phase 记分牌和兼容测试入口已移除，调用方改用统一接口。
- 对照开工快照，23 个受保护的算术/TMEM 源文件及 filelist 哈希不变。
- 删除清单为旧 `tma.md`、`mbarrier.md`、专利重复映射文档及旧兼容 testbench/Python；
  专利图片与有价值说明保留在权威 spec 附录，集成测试由统一接口版本接替。
- 生成物保持在被忽略的 `build/blackwell/`，没有加入嵌套 Git 或外部依赖副本。

本地验证材料在 `build/blackwell/sm100a_complete/`：

| 材料 | 文件 | SHA-256 |
| --- | --- | --- |
| 完整 86 项日志 | `final-regression.log` | `894cfd9b3e1a45c1960bdf8b6a1e76055eab4375529cbbc28b1524dc7014c4b0` |
| 最终边界 3 项日志 | `map-boundary.log` | `49a9f25032cbae27fa02630e4f3b87cb8db9ab9bd205abe413e85d2427693b07` |
| 最终 lint 日志 | `final-lint.log` | `2c351093a3f6a89f418ed50e1bd45ebd9f8e210beb338471a672b1dfd6522ec0` |

每份回归日志另有解析出的 `.log.json` 配置汇总。远端 `results.xml` 保留于
`build/blackwell/tests/`；TMA 三配置的 XML 被末次定向检查覆盖，完整回归结果以
上表的完整日志为准。生成日志不会作为源码提交。
