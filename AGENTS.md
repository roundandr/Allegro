# Blackwell subsystem development

These instructions apply to the Blackwell TMA, Tensor Core, mbarrier, and TMEM
subsystem and its dedicated test targets. Existing arithmetic test entry points
remain documented in the repository README and `verification/cocotb/README.md`.

- Edit on the local workstation. Run Blackwell RTL lint and simulation only
  on the configured RTX 5080 host, using its CPU. Static file checks and
  `make help` are allowed locally.
- Use `make lint-blackwell` or `make test-blackwell` from the repository root.
  These targets do not perform SSH, install tools, or download dependencies.
- Validate in a separate remote temporary directory containing the necessary
  sources. Do not modify existing remote projects or their generated results.
- Arithmetic sources are part of this repository under `rtl/`; the
  Blackwell subsystem does not require an external Allegro checkout.
- Keep all Blackwell generated files under gitignored `build/blackwell/`.
- Preserve the distinction between the implemented `tmem_array` and the
  unimplemented design target in `doc/tmem_spec.md`.
- Preserve explicit compilation filelists and stable valid-ready payloads.
  SystemVerilog uses explicit widths, `_i/_o`, `vld/rdy`, explicit fire
  conditions, and `always_ff/always_comb`.
- Never store SSH keys, passwords, tokens, or other secrets in this repository.
