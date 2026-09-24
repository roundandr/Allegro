# Single-dot energy efficiency

Run on the configured remote Linux CPU in an isolated copy of Allegro:

```sh
make dot-efficiency
```

The flow measures **one complete `f16tf32_dot_prod`**, including its five-stage
pipeline and ready/valid control. Precision, scaling and C remain runtime input
ports during synthesis. FP16 is selected only by the activity stimulus.

Requirements: the existing pinned ORFS Docker image in `config.json`, host
Verilator, Python, cocotb, PyTorch and the vendored MMA-Sim. The first run downloads
the official sv2v v0.0.13 Ubuntu binary to the isolated user tool directory
`~/.local/share/remote-rtx5080/envs/sv2v-0.0.13/`, records its SHA256, and reuses it
on subsequent runs. Set `SV2V` to use an existing v0.0.13 binary. No driver or
shared Python package is changed. Set `JOBS` for compiler parallelism (default 8).

The stages can also be run independently using
`python3 verification/benchmarks/dot_efficiency/run.py STAGE`: `prepare`, `synth`, `simulate`,
`power`, and `summarize`. `synth` and `power` execute inside the pinned ORFS image;
`all` handles its owned temporary containers automatically.

All artifacts go to `build/blackwell/dot_efficiency/`. With the managed remote
runner declare that directory as an output and use a CPU-only run. Preserve the
remote run record alongside fetched artifacts.

## Measurement contract

- ASAP7 RVT TT NLDM, 0.7 V, 25 C; five original cell libraries, excluding the
  optional FAKE multi-bit-flop libraries. Library metadata and hashes are saved.
- Initial period 1,000 ps. If setup timing fails, select 110% of the required
  period, rounded upward to 10 ps. Input slew 50 ps; IO delay 100 ps; output load
  3.898 fF. Reset is excluded from functional setup timing. Clock is ideal.
- Seeds 917/918/919; each contains 256 warmup cycles and 10,000 measured cycles.
  Independent uniform [-1,1] values are converted to FP16. C and scale are zero.
  The producer holds data under backpressure; the consumer is always ready.
- A result represents 32 algorithmic FLOP by the conventional `2K` definition.
  Actual output handshakes, not pipeline depth or declared peak, determine work.
- Mapped functional cell models are generated from the same Liberty functions.
  VCD includes only the steady-state window and all traced cell signals.
- Full-model multiclass arithmetic/backpressure regression and all measurement
  vectors must pass for RTL, converted RTL and mapped netlist before publishing.
  MMA-Sim F=25/RZ is the numeric reference.

`results.csv` / `results.json` contain the per-seed power components, throughput,
GFLOP/s/W and pJ/FLOP. Power totals include internal, switching and leakage power.
This is a **synthesis-level estimate**, without routed interconnect, clock-tree
buffers or delay-induced glitch activity; it is not measured silicon power.
