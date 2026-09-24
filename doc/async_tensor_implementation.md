# Single-CTA asynchronous Tensor Core implementation

Status: **in progress; the full SM100a implementation plan is not complete**.
The existing fixed FP16 `blackwell_tensor_subsystem` remains the product execution
path. The new completion controller and physical SRAM are migration components,
not evidence that all TMEM instructions, all MMA shapes or single-SM throughput
have been implemented.

## Implemented changes

| Component | Implemented behavior | Remaining boundary |
|---|---|---|
| `tcgen05_dot_adapter` | 32 outstanding requests by default, per-request core/type/error/tag metadata, mixed-latency pipelines, ordered retirement, simultaneous enqueue/dequeue | Scalar dot semantics; not a complete PTX MMA implementation or 256-dot array |
| `tcgen05_tensor_wrapper` | Tags travel with each lane result through all output-slice configurations | Still the legacy eight-lane FP16 wrapper |
| `blackwell_f16_dot_array` | Four partitions of 64 real arithmetic dots, tagged lockstep requests, FP16/BF16 K16 FP32 output, 4096-cycle steady issue/retire | Standalone arithmetic resource; collector, TMEM accumulator and MMA instruction scheduler not connected |
| `tcgen05_completion_tracker` | Accepted-work snapshots, out-of-order completion, empty/repeated commits, issuer/epoch separation, separate operation/commit credits, ready-issuer bypass, error tracking | Execution engines must register all queued work and signal real data completion |
| `tcgen05_commit_bridge` | One arrival per successful commit; execution errors use the existing barrier fault path; final event waits for barrier response | One outstanding barrier request; no claim of one arrival/cycle |
| `tcgen05_async_completion` | Connects tracker and bridge into an executable control path | Integration fixture connects it to TMA/mbarrier; legacy Tensor execution has not been migrated |
| `mbarrier_tc_arbiter` | Independent TC credit/response storage, registered TC payloads and full external tag preservation; state-unit three-way arbitration bypasses blocked software waits | Existing barrier state/backing throughput remains unchanged |
| `blackwell_banked_sram` | Real 1R1W byte-enabled bank arrays, no memory reset; tested 256 KiB TMEM and 228 KiB SMEM geometries | Physical primitive only: allocation, logical layouts, client arbitration, atomic and proxy-ordering frontends remain open |
| `blackwell_tmem_bank` | Full-size TMEM word store with 32-column allocation, CTA/epoch ownership, nonincreasing sizes, partial free, independent 1R1W responses and release after response acceptance | Raw aligned word interface only; pointer publication, RF/TC/CP scheduling and all instruction completion domains remain open |
| `blackwell_tmem_rf_map` | Five ordinary SM100a LD/ST RF shapes, legal repeat sizes, pack16 and second-half offset, warp-rank bounds, full-width column overflow check | Per thread/register address generator, not a multi-beat LD/ST executor or RF handshake |
| `blackwell_tmem_rf_subsystem` / `blackwell_tmem_rf_group` / `blackwell_tmem_rf_stage` / `blackwell_tmem_shift_engine` | Connects RF map and 256 KiB bank: whole-source ST capture, grouped bank-word footprint probe and writes, ordinary/packed LD/ST, RF destination confirmation, 16 KiB 32-bank SRAM stage; single-CTA SHIFT with full preflight, bank-acknowledged writes, and typed TC registration/completion events | One warp data instruction in flight; no CP/fence, product-top shared TC scheduling, hardware SHIFT golden or integrated throughput claim |
| `blackwell_tmem_wait_tracker` | Independent LD/ST wait snapshot and response credits, class/context/epoch/warp matching, error propagation, out-of-order operation completion; integrated with RF and bank completion points | One-data-command front end still limits instruction concurrency; no whole Tensor product migration |
| `blackwell_smem_system` / `blackwell_smem_backend` | One shared 228 KiB SRAM, independent read/write arbitration, per-client completion credits, byte splitting/reassembly, interval dependencies, real shared-memory reduction | Product-wide client migration and CTA allocation accounting remain open |
| `blackwell_tma_smem_bridge` | Connects legacy TMA/mbarrier memory requests and auxiliary clients to the actual shared SRAM | Existing TMA generator remains serial and uses 32-byte segments |
| `blackwell_order_tracker` | Admitted-work snapshots, issuer ordering, generation tokens, acknowledged scope/proxy maintenance, fault propagation | Not yet wired to every command-admission path; external cache/GMEM maintenance still requires a real endpoint |
| `blackwell_warp_collective` | Collects all 32 thread packets, checks uniformity, explicitly handshakes execution release and SIMT completion | RF and instruction execution engines remain to be connected |
| `blackwell_async_pkg` | Typed identity, commands, completion domains, commit and event records | Draft integration ABI; complete PTX 9.4 legality/operand mapping is not frozen |
| `blackwell_resource_model.py` | Independent arithmetic/port/window cycle bound and 85% efficiency comparison | Planned resources; not a claim that integrated RTL has those resources or throughput |

## Completion contract

Each accepted MMA/CP/SHIFT must register `async_id_t` before execution dispatch,
including commands waiting in an execution queue. The identity contains a
10-bit thread issuer, 5-bit warp, 16-bit tag, 64-bit sequence and 16-bit epoch.
The producer must not reuse the same full identity during a live CTA. The
sequence and epoch are not interpreted as a wrapping completion watermark.

A commit captures all live registered work from that issuer and epoch. Work
registered on the same edge is defined to follow the commit and is excluded;
the instruction frontend must serialize same-thread commands accordingly.
Every repeated or empty commit still generates its own arrival. Operations
registered later cannot extend an earlier snapshot. A completion accepted on
the commit edge is removed from that snapshot immediately.

Commit entries store sets of operation slots, which are cleared before slot
reuse. Ready commits from another issuer may bypass a blocked commit. Within
one issuer/epoch, predecessor masks preserve commit order. A registered output
preserves the entire arrival payload under arbitrary backpressure.

`complete_i.domain` must be `CPL_TC`. Unknown, stale-epoch or wrong-domain
completions assert `protocol_error_o` and cannot retire a live operation. A
matching execution error clears work for draining, marks dependent snapshots
failed and poisons future commits of that issuer until CTA reset. The caller
must drain/reset the controller between CTAs; changing only an epoch is not a
fault-recovery operation. This poison/error policy is a project contract,
not a NVIDIA report-payload encoding.

The execution engine sends completion only after its final data write is
acknowledged and visible. The tracker itself does not infer memory visibility.
The bridge sends `MBAR_OP_ARRIVE`, count **1**, with transaction bytes **0**.
On execution failure it sends `MBAR_OP_FAULT` instead. The final event retains
the full commit identity and is emitted after the memory-backed barrier response.

TMA byte completion, ordinary `cp.async` tracking, TMEM LD/ST waits and bulk-group
completion remain different domains. The new TC controller cannot be used to
substitute for any of them.

### Connection

Connect `tcgen05_async_completion.bar_*` to
`tma_mbarrier_subsystem.tc_arrive_*` (or the equivalent ports of
`blackwell_tma_mbarrier_top`). The existing TMA `tx_cpl_*` path is unchanged.
All unused TC inputs in a legacy instantiation must be explicitly tied off.
`tma_mbarrier_tb` contains the exercised connection and a fixture-only selector
between direct arrivals and the tracked path; select it only while idle.
`blackwell_tmem_shift_commit_tb` with `REAL_BACKING=1` also connects a physical
TMEM SHIFT producer and the shared TC controller to `mbarrier_frontend`, then
to `blackwell_tma_smem_bridge` and the 228 KiB shared SRAM. Its regression holds
the SRAM write acknowledgment to check that the commit event cannot retire
early, then evicts the barrier cache entry and reads its phase back from SRAM.
This is an end-to-end fixture; the legacy Tensor product top has not yet
adopted the new SHIFT producer.

Software, TMA transaction completions and TC arrivals have independent inputs
all the way to `mbarrier_unit`, which performs round-robin arbitration while
excluding a software TRY_WAIT blocked by full waiter storage. A shared input
skid register before this arbitration would reintroduce deadlock.

The independent producer adapter reserves internal response-tag bit 15 for TC. Software
frontend table indices must therefore be below 32768. Externally visible
software and TC tags still have all 16 bits. TC has separate admission/response
credit so filling the software wait table does not consume its admission slot.

## Physical SRAM contract

The default geometry is 128 banks × 128 words × 128 bits = 256 KiB. Each bank
corresponds to one TMEM lane; word address selects four consecutive 32-bit
columns. Banks 0–31, 32–63, 64–95 and 96–127 form the four intended partitions.
The standalone TMEM bank manager, RF shape mapper and conservative warp LD/ST
executor are implemented, but the legacy Tensor product path is not yet
connected to them. See [the RF execution contract](tmem_rf_execution_contract.md).

The SMEM configuration is 32 banks × 1824 words × 32 bits = 228 KiB. Its bank
mapping, arbitration and reduction frontend are implemented by `blackwell_smem_system`.
The SM100 maximum user allocation of 227 KiB per CTA still needs resource-manager
enforcement; physical capacity alone does not implement that rule. See
[the shared-backend contract](async_smem_contract.md) for the new interfaces.

Each cycle accepts at most one vector read and one vector write, with independent
elastic response registers. Each bank has one read address and one write address.
Byte enables implement subword writes. Simultaneous same-word reads return the
pre-write value. Invalid active-bank addresses reject the whole transaction;
inactive read banks return zero. Unwritten SRAM contents are unspecified and
are not reset. The byte-enabled memory declaration is the macro replacement
boundary. Technology SRAM inference/PPA is not yet verified.

Verilator 5.020's default VPI string buffer truncates the 16384-bit TMEM read
port. Dedicated simulation builds use `VL_VALUE_STRING_MAX_WORDS=4096`; this
changes only testbench transport capacity, not RTL geometry or data width.

## Evidence and reproduction

All RTL lint and simulation run on the configured RTX 5080 host's **CPU**, in
separate managed copies. No B200/SM100 hardware measurements are available.
Generated source baselines, logs and XML results are under
`build/blackwell/async_subsystem/`. See `async_tensor_validation.md` for verified
run identities and results. Existing dirty-worktree changes were preserved.

From a complete separate remote checkout:

```sh
make lint-blackwell
JOBS=16 make test-blackwell
BLACKWELL_TEST_TOP=tcgen05_completion_tracker make test-blackwell
BLACKWELL_TEST_TOP=blackwell_banked_sram make test-blackwell
BLACKWELL_TEST_TOP=blackwell_tmem_bank,blackwell_tmem_rf_map make test-blackwell
BLACKWELL_TEST_TOP=blackwell_tmem_rf_subsystem make test-blackwell
BLACKWELL_TEST_TOP=blackwell_f16_dot_array make test-blackwell
make synth-blackwell-tmem-bank
make synth-blackwell-f16-array
BLACKWELL_TEST_TOP=tma_mbarrier_tb TESTCASE=tc_commit_snapshot_to_backed_barrier make test-blackwell
BLACKWELL_TEST_TOP=tcgen05_dot_adapter BLACKWELL_DOT_TEST_MODULES=test_tc_pipeline,test_tcgen05_mma NUM_RANDOM_PER_COMBO=16 make test-blackwell
```

The final optional command requires the existing `MMA-Sim/mmasim` sources and
`doc/Blackwell_TCGen05_MMA.json`; that old inventory checks scalar arithmetic
compatibility, not completeness of the PTX 9.4 SM100a subsystem.

The SRAM test exercises every physical word, byte enables, read/write collisions,
independent response stalls, out-of-range accesses and control reset. Throughput
tests count 4096 steady cycles. These are primitive measurements; they must not
be reported as TMA bandwidth or integrated GEMM performance.

## Remaining plan gates

No P0–P5 phase is marked fully complete by this change.

1. **P0:** complete the PTX 9.4 SM100a legality matrix, all instruction descriptors,
   numerical contracts, and exact operand/modifier encodings. Source hashes are
   recorded in `async_sources.json`; the old PTX 9.2 inventory remains a seed.
2. **P1:** finish product-wide integration of the implemented shared SMEM arbiter,
   atomic backend, ordering tracker and warp rendezvous. Generic/async/tensormap
   maintenance, execution queues, cross-engine footprint dependencies and RF
   synchronization still need to be connected and tested end to end.
3. **P2:** extend the now-connected bank-word grouped LD/ST scheduler to multiple
   concurrent commands, then complete CP/decompression,
   SHIFT, waits/fences, allocation-result SMEM writes, scale and sparse storage.
4. **P3:** connect the now-instantiated FP16/BF16 four-partition 256-dot array
   to operand reuse/collector, TMEM accumulator forwarding and scheduling;
   replace the legacy serial executor and connect the complete
   TMA→MMA→TMEM→RF→SMEM→TMA-store pipeline.
5. **P4:** complete matrix instruction semantics across all seven kinds and legal
   shapes, sparse/block scaling, collector/WS/ASHIFT/output masks and rounding.
   Scalar arithmetic support is not equivalent to instruction support.
6. **P5:** TMA multi-context issue, 256 MSHRs, coalescing/wider SMEM path, descriptor
   dependency versions, integrated performance, synthesis structure and migration.

Acceptance remains ≥95% compute peak, ≥90% configured effective transfer
bandwidth and ≥85% independently bounded end-to-end throughput. Those integrated
gates have **not** been demonstrated. Public semantic conformance, achieved
throughput and SM100 hardware equivalence must be reported separately.
