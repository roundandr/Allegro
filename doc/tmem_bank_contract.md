# 单 CTA TMEM 物理后端合同

`blackwell_tmem_bank` 是可综合的 **128 lane × 512 column × 32 bit = 256 KiB**
TMEM 存储和列所有权后端。每个 lane bank 是深度 128 的 128-bit 1R1W SRAM；
一个请求至多对每个 lane 读/写一个四列对齐 word。byte mask 支持子字写，
存储内容在 reset、alloc、free 时均不清零。SM100a 指令层的 RF shape、CP、
MMA 布局仍须使用上层调度器和本模块物理访问接口连接，不由此接口单独完成。

管理接口有独立的 `ctx`、`alloc`、`free`、`relinquish` valid-ready 入口，
共享一条带 tag/status/base 的响应通道。管理响应阻塞时不接收新命令。
接受优先级是 `free → relinquish → ctx → alloc`；空间不足的 alloc 保持
`rdy=0`，不会阻塞 free。`ctx` 进入设置 epoch、allocation permit 和最大列数；
退出要求该 CTA 无 live 列、无未被消费者接收的数据响应。分配列数限
32/64/128/256/512，按所请求大小对齐并取最低可用列，单 CTA 后续申请
的列数不得增加。`free` 可释放任意由该 CTA 完全拥有的 32-column 对齐连续范围；
是否允许部分 dealloc 的 PTX 规则需要在指令译码层继续核对，物理层不把“精确匹配
原 allocation”写成 NVIDIA 限制。

数据接口使用每 lane 的完整 16-bit column、128-bit word 数据及 16-bit byte mask。
任何一个有效 lane 的地址越界、未按四列对齐、未由 `(ctx,epoch)` 拥有时，
整个请求返回错误，写入无副作用、读取不暴露数据。独立 read/write 同周期可并行；
同 lane 同 word 冲突时，轮换仲裁一次只接收一个。读写响应有独立背压，
free 等到该 CTA 的请求响应实际被消费者接收，防止早释放。
状态码沿用 `tmem_spec.md` 的项目诊断：OK=0、CONTEXT=3、ADDR=5、OWNER=6、
ALLOC_SIZE=7、PERMIT=8、CTX_BUSY=17；它们不是 PTX 指令编码。

`blackwell_tmem_rf_map` 提供 SM100a 普通 LD/ST 的 `.32x32b`、`.16x64b`、
`.16x128b`、`.16x256b`、`.16x32bx2` 寄存器坐标生成，覆盖合法的 2 的幂
repeat、pack16 对应的第二 cell、第二半区 column offset，以及 warp rank 的
lane 范围。输出是单个 thread/register 项的 cell 坐标；多线程 bank 冲突拆拍、
RF 收发握手和指令完成语义还未接入。

本合同只报告后端可用能力，不构成 P2 或整份异步子系统计划验收。
远端执行 `make synth-blackwell-tmem-bank` 会将完整 owner/storage 模块转换并
通过 Yosys 检查，随后从综合网表核对 128 个无初始化的 1R1W SRAM bank；
这不是完整 Tensor Core 子系统的技术宏映射或时序收敛证明。
