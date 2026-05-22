| 接口名称 | 位宽 | 说明 |
|------|------|------|
| io.initiate.valid | 1 | Tensor Core 启动请求有效（Decoupled 输入） |
| io.initiate.bits.wid | log2Ceil(WarpMax) | Warp ID |
| io.initiate.bits.addressA | 32 | A 矩阵在 SMEM/TMEM 中的起始字节地址 |
| io.initiate.bits.addressB | 32 | B 矩阵在 SMEM 中的起始字节地址 |
| io.initiate.bits.addressC | 32 | 输出/累加 C 在 SMEM/TMEM 中的起始字节地址 |
| io.initiate.bits.mbarrierAddr | 32 | mbarrier 对象在 SMEM 中的地址（用于后续 arrive 许可操作） |
| io.respA.valid | 1 | A 读返回有效（Decoupled 输入） |
| io.respA.bits.data | memWidth | A 返回数据 |
| io.respB.valid | 1 | B 读返回有效（Decoupled 输入） |
| io.respB.bits.data | memWidth | B 返回数据 |
| io.respC.valid | 1 | A 读返回有效（Decoupled 输入） |
| io.respC.bits.data | memWidth | A 返回数据 |
| io.reqA.ready | 1 | A 请求 ready（来自下游，但属于该输出接口的握手返回） |
| io.reqB.ready | 1 | B 请求 ready（来自下游，但属于该输出接口的握手返回） |
| io.reqC.ready | 1 | C 请求 ready（来自下游，但属于该输出接口的握手返回） |
| io.mbarrier.ready | 1 | mbarrier 管理单元可接受 arrive |

#### 2.3.2 输出信号（Outputs）

| 接口名称 | 位宽 | 说明 |
|------|------|------|
| io.initiate.ready | 1 | 可接受启动请求（模块对上游施加 backpressure） |
| io.reqA.valid | 1 | A 读请求有效（Decoupled 输出） |
| io.reqA.bits.address | 32 | A 访问地址 |
| io.reqB.valid | 1 | B 读请求有效（Decoupled 输出） |
| io.reqB.bits.address | 32 | B 访问地址 |
| io.reqC.valid | 1 | C 读请求有效（Decoupled 输出） |
| io.reqC.bits.address | 32 | C 访问地址 |
| io.respA.ready | 1 | A 返回通道 ready（模块对上游施加 backpressure） |
| io.respB.ready | 1 | B 返回通道 ready（模块对上游施加 backpressure） |
| io.respC.ready | 1 | C 返回通道 ready（模块对上游施加 backpressure） |
| io.writeback.valid | 1 | 写回到 SMEM/TMEM 的写请求有效（Decoupled 输出） |
| io.writeback.bits.address | 32 | 本次写回到 SMEM/TMEM 的目标字节地址 |
| io.writeback.bits.data | numLanes × laneWidth | 写回数据（Vec(numLanes, UInt(laneWidth.W))|
| io.mbarrier.arrive | 1 | 向 mbarrier 管理单元发起 arrive 许可操作有效（通常仅在 last 写回完成时拉高） |
| io.mbarrier.bits.addr | 32 | mbarrier 对象地址（= initiate.bits.mbarrierAddr） |
| io.mbarrier.bits.wid | log2Ceil(WarpMax)  | 发起 arrive 的 warp ID |

---
