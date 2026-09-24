# TMEM warp RF execution path

`blackwell_tmem_rf_subsystem` connects the five `tcgen05.ld/st` RF shapes and
single-CTA `tcgen05.shift.down` to the full 256 KiB `blackwell_tmem_bank`.
This is an incremental single-CTA
execution path, not a complete TMEM or Tensor Core product top.

The command carries context/epoch, warp rank, shape, repeat count, base TMEM
address, optional pack16/half-offset, operation direction and tag. Each RF
beat is a 1024-bit vector of 32 thread values at one register index. An ST
accepts every source beat before using TMEM. The final source beat must assert
`rf_src_last_i`; an early or missing last beat fails without a bank write.
The engine then issues permission/address probes for **every** referenced
cell. Only after all probes succeed does it write the captured values. It
blocks allocation/free/relinquish/context changes throughout the command,
so no ownership change can invalidate that preflight. An LD buffers all
results and offers them in increasing register index. Its DONE response is
held until the RF sink has acknowledged every beat. An ST DONE follows the
last acknowledged bank write. Error responses carry the original tag and
direction. Releasing a context while a command or its completion response is
live is stalled.

`wait_vld_i` accepts a separate `wait::ld` (`wait_store_i=0`) or `wait::st`
(`wait_store_i=1`) request even while the data engine or its DONE response is
blocked. It captures prior accepted operations with the same context, epoch,
warp and direction. A later LD/ST does not extend that snapshot. The wait
tracker has independent operation and waiter slots and keeps its response
stable under backpressure. LD completion enters the tracker only after the
final RF destination handshake; ST completion enters it after the final bank
write acknowledgment. A failed operation yields status 16 (`ERR_DEPENDENCY`)
for same-class waits in its epoch; a different class or epoch is unaffected.
Successful context recreation clears that context's old failure history even
if the 16-bit epoch value is reused.
Wait responses do not depend on the ordinary DONE response being consumed.
The command front end must preserve warp instruction order when submitting
a data operation and a wait on the same cycle: a wait snapshot excludes
operations accepted on its own edge.
PTX 9.4 defines `tcgen05.wait` for prior operations issued by the executing
thread and requires `.sync.aligned` warp participation. This project ABI
represents a collectively issued warp command; the standalone RF executor
does not yet connect `blackwell_warp_collective` to enforce that PTX boundary.
See the [official PTX 9.4 instruction](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html).

Each ordinary ST writes four bytes; unpack16 ST writes only the low two bytes
of each adjacent cell, preserving the upper half. Pack16 LD forms one RF
register from the low halves of those cells. The bank's physical 1R1W SRAM
retains its full allocation and ownership checks, backpressure and collision
arbitration. Storage contents are not reset.

The scheduler issues a vector of warp cells per bank beat. At most one aligned
128-bit word is selected in each lane bank; cells in that word can share a
request. Reads fan out a shared cell to every requesting thread. Writes with
overlapping byte masks serialize in thread order. A response clears only the
threads actually issued, so a bank conflict takes another beat without
dropping work. The full-footprint ST probe uses the same grouped requests.

`shift_cmd_*` addresses a 32-lane × 8-column footprint. The lane base must
be a multiple of 32 and the last column must be at most 511. The SHIFT engine
probes all eight columns through the actual bank ownership interface before
writing any of them. For each column it captures all 32 original cells, then
writes original lane `r+1` to lane `r` for `r=0..30`; lane 31 remains unchanged.
Its completion response is held until accepted and appears only after the
last physical bank write is acknowledged. SHIFT owns the bank exclusively
against RF commands and allocation changes while active. It is separate from
the `wait::ld/st` tracker: SHIFT belongs to `tcgen05.commit`'s completion
domain. Acceptance into the one-entry SHIFT queue emits a typed
`shift_register` event before bank dispatch. After the final bank write
acknowledgment, a typed `shift_complete` event remains valid until the shared
TC controller accepts it; only then is the ordinary SHIFT DONE exposed.
The one-entry queue can register a SHIFT while an earlier RF instruction is
still executing, but dispatch waits for that instruction's DONE response.
The command front end must preserve instruction order for an issuer:
a commit accepted on the same edge as SHIFT registration excludes that SHIFT
from its snapshot.
The integration fixture connects these ports to `tcgen05_async_completion`
and checks commit snapshots and mbarrier arrival/fault handshakes. Its
`REAL_BACKING=1` configuration also exercises the real mbarrier frontend and
shared SMEM: completion waits for the backing write acknowledgment, then a
cache-evicted phase wait reloads the object from SRAM. The final-row preservation
and row direction follow the project's mapping in `tmem_spec.md`; the public
PTX wording does not establish a bit-exact SM100 hardware golden for that
mapping, so this part remains hardware-unverified.

The RF stage is **32 banks × 128 registers × 32 bits = 16 KiB**, with
synchronous 1R1W and byte enables. A warp source beat writes all thread banks;
a TMEM load updates just the selected thread banks and two bytes for a packed
half. One fetched 1024-bit vector register holds a beat during ST issue or RF
destination backpressure. The independent Yosys structural check requires 32
uninitialized SRAM-like RF memories as well as the 128 physical TMEM banks.

The engine still admits one warp instruction at a time. Its ST probe is an
extra pass and its request/response loop does not pipeline successive bank
beats. It therefore cannot approach the physical 2048 B/cycle aggregate bank
bandwidth or satisfy the P2/P3 performance gates. It does not implement CP,
thread fences, pointer publication, LD reduction, or shared scheduling with
the product TC/TMA top. The default integration fixture's mbarrier acknowledgment
is a controlled endpoint; the `REAL_BACKING=1` test covers physical backing,
while product top migration remains open. The legacy product Tensor top still uses its 4 KiB
dual-tile TMEM implementation.

The dedicated Cocotb fixture runs the real mapper and bank together: all
five shape families with ordinary and packed examples, source snapshot,
RF destination stall, nonzero warp partition and base, an out-of-range ST
whose earlier address is prefilled, and completion/control backpressure.
An independent grouping oracle exercises 205 bank-word and byte-conflict
cases. A 4096-plus-cycle single-warp ST benchmark reports the actual
payload rate of this front end separately from the 2048 B/cycle physical
bank port; it is not an integrated Tensor Core throughput result.
See `async_tensor_validation.md` for remote run IDs and results.
