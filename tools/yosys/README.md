# Dot Cluster Yosys Proxy Flow

This flow is for relative RTL timing exploration. It is not signoff.

```bash
tools/yosys/install_check.sh
TARGET_NS=0.667 TOP=dot_cluster_top tools/yosys/run_dot_cluster_proxy.sh
TARGET_NS=1.000 TOP=fp4_dot_prod tools/yosys/run_dot_cluster_proxy.sh
PROXY_LIB=nangate45 TARGET_NS=0.667 TOP=fp4_dot_prod tools/yosys/run_dot_cluster_proxy.sh
```

`run_dot_cluster_proxy.sh` uses `sv2v` before Yosys because the RTL uses
SystemVerilog structs and typed functions that Yosys does not parse directly.

Library selection:

- `LIBERTY_PATH=/path/to/cell.lib` overrides everything.
- `LIBERTY_PATH=generic` or `LIBERTY_PATH=none` runs a generic Yosys/ABC
  smoke flow without cell-library timing. Use this only for structural checks.
- `PROXY_LIB=auto` is the default. It tries ASAP7 first, runs a small
  Yosys/ABC sanity probe, and falls back to Nangate45 if the ASAP7 liberty is
  not ABC-compatible on the local toolchain.
- `PROXY_LIB=asap7` forces ASAP7 and fails early if the ABC sanity probe fails.
- `PROXY_LIB=nangate45` forces the stable 45nm fallback. Treat its timing as a
  relative logic-optimization proxy, not a GPU-frequency proxy.
- Without `LIBERTY_PATH`, the script tries to build an ASAP7 TT merged liberty
  from the SiliconCompiler `lambdapdk` archive under `~/.cache/allegro-pdk`.
- If ASAP7 is unavailable, it falls back to the Nangate45 typical liberty.

On the Homebrew Yosys 0.65 / ABC build used here, the public ASAP7 NLDM liberty
is converted to an ABC SCL cache that does not expose base supergates such as
INV/BUF/AND2/NAND2 reliably. The probe catches that condition before a full
run; otherwise ABC can abort or segfault inside `map`/`&nf`.

Targets used in this project:

- `TARGET_NS=1.000`: 1.0 GHz sanity target.
- `TARGET_NS=0.667`: 1.5 GHz primary proxy target.
- `TARGET_NS=0.500`: 2.0 GHz stretch proxy target.
