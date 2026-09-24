# Tensor Core and Implemented TMEM Specification v1.0

Status: frozen baseline contract. This is an open research model inspired by
public Blackwell concepts; it is not a cycle-accurate model of proprietary
NVIDIA hardware.

## Scope

This document specifies `tcgen05_tensor_wrapper`, `tmem_array`, and
`blackwell_tensor_subsystem`. The implemented tensor path performs one dense
`cta_group::1 kind::f16` operation: FP16 x FP16 -> FP32, tile `M64N8K16`.
It excludes sparse modes, dynamic precision, GPU/CTA scheduling, real SRAM
macros, and a software-visible instruction encoding.

The separate `tma_mbarrier_subsystem` implements data movement and barriers
through the unified command interfaces specified in [TMA](tma_spec.md) and
[mbarrier](mbarrier_spec.md). `blackwell_tma_mbarrier_top` exposes both control
paths. Callers explicitly wait for TMA data before submitting dependent Tensor
operations; Tensor COMMIT/WAIT tracks only Tensor work.

The [TMEM design target](tmem_spec.md) describes future, unimplemented
capabilities. The implemented TMEM contract is the one below.

## Numerical contract

- A contains 64 rows of 16 IEEE FP16 values, row-major.
- B contains 8 columns of 16 IEEE FP16 values, column-major.
- Each A row and B column is one 256-bit SMEM beat. Element 0 occupies bits
  `[15:0]`.
- Eight Allegro `tcgen05_dot_adapter` instances compute the eight output
  columns for one row in parallel.
- The Allegro FP16 path defines special-value, subnormal, and rounding
  behavior. This subsystem does not reinterpret arithmetic results.
- `accumulate=0` drives FP32 +0 as input D and overwrites TMEM.
- `accumulate=1` reads the existing TMEM row and supplies it as input D.

## Fixed baseline

| Item | Value |
| --- | --- |
| Tile | M64N8K16 |
| Arithmetic lanes | 8 |
| TMEM | 8 banks x 128 entries x 32 bits |
| TMEM baseline port | 1 read + 1 write per bank |
| Resident tiles | 2 |
| Mapping | bank = column[2:0], row = slot*64 + tile_row |
| SMEM A/B | independent 256-bit read channels |
| SMEM writeback | one 256-bit row per accepted beat |
| Staging | 8 resident B columns; A staging ring depth=2 |
| Clocking | one clock domain, asynchronous active-low reset |

Byte addresses are 32 bits. A and B read addresses advance by 32 bytes;
writeback advances by 32 bytes. Addresses must be 32-byte aligned.

## Command interface

The command channel is valid-ready. Payload remains stable while stalled.

| Opcode | Value | Meaning |
| --- | --- | --- |
| `MMA` | 1 | Fetch B, process 64 A rows, and update one TMEM slot |
| `COMMIT` | 2 | Capture accepted asynchronous-work watermark |
| `WAIT` | 3 | Complete after all work at or before a token retires |
| `STORE` | 4 | Read one TMEM slot and write 64 rows to SMEM |

Fields are: 16-bit transaction tag, 32-bit A/B/destination bases, one-bit
tile slot, one-bit accumulate, and 16-bit
wait token. Completion returns tag, opcode, 8-bit status, and 16-bit token.

Only one MMA or STORE is executed at a time. COMMIT captures the accepted
Tensor watermark and WAIT completes after the covered Tensor operations retire.
TMA operation completion is tracked separately by its mbarrier or bulk-group.
Opcode values 0 and 5 are invalid; no implicit TMA dependency scoreboard exists.

## Memory interfaces

- Each SMEM read request carries a 32-bit address and 4-bit source tag.
- Read response carries 256-bit data, source tag, and 2-bit status.
- The write channel carries address, 256-bit data, 32-bit byte mask, source
  tag, and receives a tagged 2-bit-status response.
- A and B use independent read channels.

## TMEM contract

TMEM exposes configurable scalar read ports plus an eight-lane row write.
Baseline 1R1W allows one read and one write per bank. The 1RW mode gives row
writes priority and backpressures reads during a write; 2R1W admits two reads
per bank. When requests exceed the selected bank capacity, lowest port index
wins and lower-priority requests are backpressured with `conflict=1`.
Responses are one-entry buffered and remain stable under backpressure. A bank
may accept one read and one row write in the same cycle (1R1W).

TMEM data cells are intentionally not reset. Control and response-valid state
are reset, and software/tests must initialize a row before reading it.

## Synchronization

- Work watermark increments when MMA or STORE work is accepted.
- `COMMIT` returns the current 16-bit issued watermark.
- `WAIT(token)` completes only when the retired watermark is at least token.
- Watermark comparison is non-wrapping in v1; reset before 16-bit wrap.

## Performance counters

Seven clearable saturating-free 32-bit counters report SMEM request/response
stall cycles, tensor-core busy cycles, TMEM read-conflict cycles, TMEM stall
cycles, writeback stall cycles, commands issued, and commands completed.
Counter wrap is permitted.

## Timing and backpressure

All channels transfer on `vld && rdy`. The sender holds valid and payload
stable until transfer. No combinational path crosses from a downstream valid
to an upstream valid. There is no CDC or RDC boundary in v1.
