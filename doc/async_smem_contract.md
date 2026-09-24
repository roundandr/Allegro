# Shared SMEM and asynchronous admission interfaces

These modules implement the memory/backend part of the single-CTA migration.
They do not constitute a complete SM100a Tensor Core subsystem. The final Tensor
executor, TMEM instruction engine and TMA multi-context/coalescing work remain
open in [the implementation record](async_tensor_implementation.md).

## Physical storage and client admission

`blackwell_smem_system` contains exactly one 228 KiB `blackwell_banked_sram`,
32 banks × 1824 words × 32 bits. All clients, including atomic requests, use
that same storage. Memory contents are not reset. Default configuration: eight
clients, eight transaction contexts per client, four reserved backend responses
per client and direction. Physical bandwidth is one 128-byte read and one
128-byte write each cycle, shared across all clients.

Each client supplies an unsigned 32-bit byte address, 128 byte enables, a
1024-bit little-endian payload, a 16-bit tag, kind (0 read, 1 write, 2 reduce),
and the existing TMA dtype/reduction fields. Tags are echoed without truncation;
the caller keeps them unique while outstanding. Unselected read bytes return
zero. A request crossing a 128-byte boundary generates two tagged backend
transactions and is complete only after both acknowledgements. Empty masks
produce no memory traffic. Any selected byte outside physical capacity rejects
the whole request before any write. High address bits cannot wrap into SRAM.

This is a physical single-CTA backend. Enforcing the SM100 user-visible 227 KiB
per-CTA allocation limit belongs to the still-pending CTA resource manager;
physical capacity must not be advertised as the user allocation limit.

Per-client dependencies preserve admission order for overlapping byte intervals
if either operation writes. Non-overlapping intervals and read/read requests
can proceed concurrently. Dependencies clear at actual data completion, not
when a response consumer eventually becomes ready. Reservations cover each
128-byte request interval, not the whole TMEM/SMEM allocation. Different clients
must establish publication/acquisition and other required dependencies through
the ordering frontend; racing ordinary accesses do not acquire atomicity.

Read and write arbitration are independent round-robin arbiters. Credit is
reserved when an SRAM request issues and released when its client consumes the
response. A blocked client cannot fill another client's response storage or
hold the physical SRAM response bus. Payloads and tags are stable under stalls.

## On-chip reduction

The reduction execution path performs real SRAM read/modify/write operations.
It reserves the affected 128-byte line before its read and prevents intervening
ordinary accesses to that line until write acknowledgement. Other lines may
continue using the shared physical ports. The internal reservation is stronger
than the required per-element atomicity; it does not make the public operation
a guaranteed 128-byte atomic transaction.

Supported shared-memory combinations follow `reduction_legal(..., shared_dst=1)`:

| Operation | Types |
|---|---|
| add | u32, s32, u64 |
| min/max | u32, s32 |
| inc/dec/and/or/xor | u32 |

Element alignment and complete element masks are checked before execution.
Signed comparisons, modular arithmetic and inc/dec boundary behavior execute
in RTL. Unsupported types/operators and partial element masks return errors
without modifying storage. GMEM floating reductions and multimem remain external
endpoint operations; this backend never replaces them with local RMW.

`blackwell_tma_smem_bridge` connects the existing 32-byte TMA/mbarrier request
port to client 0 of this shared backend, preserving ID, byte mask and typed
reduction metadata. Its auxiliary 128-byte clients access the same storage.
The bridge does not increase the legacy TMA generator's 32-byte segment size.

## Ordering and external visibility

`blackwell_order_tracker` has separate operation and fence capacities (64 and
16 by default). Register every operation at instruction/command admission,
including queued work. Admission must be in program sequence within an issuer;
enrolling earlier work after its fence has been captured violates this ABI.
Returned 16-bit tokens include an allocation generation and an operation slot.
Complete each token only after the operation reaches its required visibility
point. Unknown, duplicate or stale-generation acknowledgements set the protocol
error flag and cannot retire another operation.

A fence snapshots earlier operations of its issuer, including a prior operation
registered on the same edge. Later operations from that issuer are blocked
while the fence is live; other issuers continue. Same-issuer fences retain their
order. Once dependencies drain, the tracker forwards the complete scope/proxy
request to the maintenance endpoint. It returns success only after that endpoint
acknowledges. Thus a GMEM/cache scope or descriptor-cache invalidation must be
implemented by the connected endpoint; a timer or a constant-ready stub does
not satisfy the contract. Completion errors propagate to dependent fences and
poison subsequent fences of the issuer until the CTA is drained and reset.

This tracker is independently tested and is not yet wired into every product
command-admission path. The current real-SMEM TMA fixture still supplies the
external ordering endpoint separately. Its results do not prove full integrated
generic/async/tensormap ordering. The ordering reference test deliberately uses
separate generic, published and async views to distinguish command completion
from publication and acquisition.

## Thread rendezvous

`blackwell_warp_collective` accepts one operand packet per actual thread, with
warp, lane, instruction ticket and epoch. It keeps a 32-bit arrival set per warp,
checks every packet's uniform operands, and issues only after all 32 handshakes.
A missing thread cannot be replaced by a convergence flag. Repeated arrivals
backpressure; mismatched tickets, epochs or operands reject the collective.

An issue handshake does not itself resume the warp. The execution engine sends
a matching explicit release after the instruction's required boundary: for
example, after RF source capture for ST, pointer-write completion for ALLOC, or
dependency completion for WAIT. A separate valid/ready completion returns the
whole-warp acknowledgement to SIMT. A stale release cannot unlock a reused warp.
This is an admission interface, not an implementation of the RF or SIMT engine.

## Verification

Run lint/simulation on the configured remote CPU:

```sh
BLACKWELL_TEST_TOP=blackwell_smem_backend,blackwell_smem_system,blackwell_order_tracker,blackwell_warp_collective make test-blackwell
BLACKWELL_TEST_TOP=tma_mbarrier_tb make test-blackwell
```

The second command includes the `REAL_SMEM=1` integration configuration as well
as the retained behavioral-backend tests. New integration tests initialize and
inspect SMEM through an actual RTL generic client. Only GMEM and external order
acknowledgements are supplied by the Python endpoint.

The full regression enables Verilator runtime assertions. Independent byte
references cover crossing every byte offset, masks, range faults, alias ordering,
atomic contention, response isolation and non-power-of-two resource capacities.
Default SMEM byte endpoints achieve 128 B/cycle simultaneously in each direction
over 4096 steady cycles. The intentionally undersized three-context corner is
window-limited and measured separately. This is shared-memory throughput, not
an integrated TMA or GEMM throughput result.

`make synth-blackwell-sram` uses the retained remote Yosys image to inspect actual
memory cells after process/memory passes. Its checker verifies capacity, bank
count, synchronous 1R1W ports and unspecified initial contents. It is a memory
structure check, not a full-subsystem synthesis, technology macro mapping or PPA
result. Exact run results and source hashes are recorded with the validation
artifacts rather than inferred from these interface specifications.
