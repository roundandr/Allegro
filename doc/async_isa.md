# RISC-V Asynchronous Tensor Core Instruction Set (Ztmma proposal)

**Version:** 0.1-Draft  
**Status:** Experimental Research Proposal  
**Authors:** Liu Yuxuan 
**Inspired by:** NVIDIA Hopper WGMMA

This is an unimplemented arithmetic ISA proposal. For TMA and synchronization,
use the authoritative [TMA spec](tma_spec.md) and [mbarrier spec](mbarrier_spec.md).

---

## 1. Overview

This document defines a proposed **RISC-V custom extension** for high-throughput **asynchronous matrix multiply-accumulate (MMA)** operations, modeled after NVIDIA Hopper’s **WGMMA + TMA + mbarrier** execution style.

The extension enables:
- Warpgroup-level asynchronous tensor computation
- Commit / wait groups for overlapped pipeline scheduling

This ISA is suitable for SIMT GPUs, many-core accelerators, and experimental tensor engines.

---

## 2. Architectural Model

| Concept | Description |
|----------|--------------|
| **Warpgroup (WG)** | A group of 128 threads (4 warps × 32 threads) collaborating on one tensor operation. Configurable to 64 or 256 threads. |
| **Shared Memory (SMEM)** | Fast on-chip memory serving as the operand tile buffer. |
| **TMA Engine** | Tensor Memory Accelerator moving tiles asynchronously between GMEM and SMEM. |
| **Accumulator (C-RF)** | Dedicated register file holding MMA accumulators per WG. |
| **Barrier Unit** | Manages producer/consumer synchronization between TMA and TensorCore pipelines. |

---

## 3. Data Types and Tile Shapes

| Type | A/B Input | C Accumulator |
|------|------------|---------------|
| FP8 (e4m3 / e5m2) | ✓ | FP16 / BF16 / FP32 |
| FP16 / BF16 | ✓ | FP16 / FP32 |
| INT8 | ✓ | INT32 |

**Supported Shapes (examples):**
- m16n16k32
- m32n16k32
- m16n32k32
- m64n64k64

Shape encodings are implementation-specific and programmable through instruction fields.

---

## 4. Instruction Families

### 4.1 Descriptor Management

| Instruction | Syntax | Description |
|--------------|---------|--------------|
| `tc.sdesc.set` | `tc.sdesc.set sda, [smem_base], lda, layout, swizzle, bits, group` | Define SMEM operand descriptor (for A/B tiles). |
| `tc.acc.zero` | `tc.acc.zero cgrp` | Clear accumulator registers in the current WG. |
| `tc.acc.scale` | `tc.acc.scale cgrp, imm|freg` | Apply scale or quantization factor. |
| `tc.acc.cast` | `tc.acc.cast cgrp, dtype` | Convert accumulator datatype (for epilogue). |

---

### 4.2 Data movement and synchronization

See [TMA completion domains](tma_spec.md) and [barrier lifecycle](mbarrier_spec.md).
Loads account transaction bytes through mbarrier; stores use per-thread
bulk-groups. The old custom TMA/barrier instruction proposal has been retired.

---

### 4.3 Asynchronous Matrix Multiply-Accumulate (WGMMA-like)

| Instruction | Syntax | Description |
|--------------|---------|--------------|
| `tc.mma.async` | `tc.mma.async cgrp, [sda], [sdb], shape, acc_dtype, flags` | Perform asynchronous MMA for one WG; A×B + C. |
| `tc.commit.group` | `tc.commit.group` | Commit the current group of async MMAs to hardware queue. |
| `tc.wait.group` | `tc.wait.group imm` | Wait until (submitted groups − imm) are completed. |
| `tc.wait.all` | `tc.wait.all` | Wait for all pending groups to finish. |

**Flags:**
- `sat` – enable saturation arithmetic  
- `relu` – apply ReLU clamp  
- `transA/B` – transpose input operand  
- `negA/B` – negate operand  
- `scale_sel` – choose pre/post scaling source  

---

### 4.4 Accumulator Read / Write (Epilogue)

| Instruction | Syntax | Description |
|--------------|---------|--------------|
| `tc.c.store.smem` | `tc.c.store.smem [sdc], cgrp, ldc, cast_mode, pack` | Write accumulator to SMEM. |
| `tc.c.load.smem` | `tc.c.load.smem cgrp, [sdc], ldc, unpack` | Load accumulator from SMEM (for reuse). |

Example quantized epilogue:
```asm
tc.acc.scale    c0, scale
tc.acc.cast     c0, bf16
tc.c.store.smem [sdc], c0, ldc, pack_q
```
