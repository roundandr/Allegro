#!/usr/bin/env python3
"""Reproducible single-dot synthesis/activity/power flow. Run on remote Linux CPU.

all uses an existing pinned ORFS image and an isolated sv2v installation.
Individual stages: prepare, synth (in ORFS), simulate, power (in ORFS), summarize.
Only generated files under build/blackwell/dot_efficiency are modified.
"""
from __future__ import annotations
import argparse
import csv
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tarfile
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
OUT = ROOT / "build/blackwell/dot_efficiency"
CFG = json.loads((HERE / "config.json").read_text())
TOP = CFG["top"]
SOURCES = [ROOT / p for p in (HERE / "filelist.f").read_text().splitlines() if p]
PLATFORM = Path("/OpenROAD-flow-scripts/flow/platforms/asap7")
OPENROAD = "/OpenROAD-flow-scripts/tools/install/OpenROAD/bin/openroad"
YOSYS = "/usr/local/bin/yosys"

def save(path, data):
    Path(path).write_text(json.dumps(data, indent=2, ensure_ascii=False)+"\n")

def sha(path):
    h=hashlib.sha256()
    with Path(path).open("rb") as f:
        for b in iter(lambda:f.read(1024*1024),b""): h.update(b)
    return h.hexdigest()

def run(argv, log, env=None, cwd=ROOT):
    print("RUN", " ".join(map(str,argv)), flush=True)
    t=time.monotonic()
    with Path(log).open("w") as f:
        p=subprocess.run(list(map(str,argv)),cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT)
    print(f"DONE {Path(log).name}: rc={p.returncode}, {time.monotonic()-t:.2f}s",flush=True)
    if p.returncode:
        print(Path(log).read_text(errors="replace")[-6000:],flush=True)
        raise RuntimeError(f"command failed, see {log}")

def prepare():
    tool=Path(os.environ.get("SV2V",str(Path.home()/".local/share/remote-rtx5080/envs/sv2v-0.0.13/sv2v")))
    if not tool.exists():
        tool.parent.mkdir(parents=True,exist_ok=True)
        url="https://github.com/zachjs/sv2v/releases/download/v0.0.13/sv2v-Linux.zip"
        archive=tool.parent/"release.zip"
        urllib.request.urlretrieve(url,archive)
        with zipfile.ZipFile(archive) as z:
            names=[n for n in z.namelist() if Path(n).name=="sv2v"]
            assert len(names)==1,names
            tool.write_bytes(z.read(names[0]))
        tool.chmod(0o755)
        save(tool.parent/"provenance.json",{"url":url,"archive_sha256":sha(archive),"binary_sha256":sha(tool)})
    identity={"run_id":ROOT.parent.name if ROOT.name=="work" else None,
              "sv2v_version":subprocess.check_output([tool,"--version"],text=True).strip(),
              "sv2v_sha256":sha(tool),"image":CFG["image"],"python":sys.version,
              "verilator":subprocess.check_output(["verilator","--version"],text=True).strip()}
    assert "v0.0.13" in identity["sv2v_version"] or "0.0.13" in identity["sv2v_version"]
    prov=tool.parent/"provenance.json"
    if prov.exists():identity["sv2v_download"]=json.loads(prov.read_text())
    save(OUT/"environment.json",identity)
    snapshot=list(SOURCES)+list(HERE.glob("*"))+[
        ROOT/"verification/cocotb/test_f16tf32_dot.py",ROOT/"verification/cocotb/mma_sim_fp16_ref.py",
        ROOT/"verification/cocotb/mma_sim_tf32_ref.py"]+list((ROOT/"MMA-Sim/mmasim").rglob("*.py"))
    snapshot=[p for p in snapshot if p.is_file()]
    save(OUT/"source_sha256.json",{str(p.relative_to(ROOT)):sha(p) for p in snapshot})
    with tarfile.open(OUT/"source_snapshot.tar.gz","w:gz") as t:
        for p in snapshot:t.add(p,arcname=str(p.relative_to(ROOT)))
    # stdout is the converted Verilog, diagnostics are archived separately.
    with (OUT/"converted.v").open("w") as f,(OUT/"sv2v.log").open("w") as err:
        subprocess.run([str(tool),"--top="+TOP,*map(str,SOURCES)],stdout=f,stderr=err,check=True)
    print("SystemVerilog conversion complete",flush=True)

def liberty_files():
    # ORFS also carries FAKE multi-bit flop libraries; exclude them explicitly.
    return [next(PLATFORM.glob(f"lib/NLDM/asap7sc7p5t_{family}_RVT_TT_nldm_*.lib*"))
            for family in ["AO","INVBUF","OA","SEQ","SIMPLE"]]

def sta_base(period):
    libs="\n".join(f"read_liberty {{{p}}}" for p in sorted((OUT/"lib").glob("*.lib")))
    return f"read_lef {PLATFORM}/lef/asap7_tech_1x_201209.lef\nread_lef {PLATFORM}/lef/asap7sc7p5t_28_R_1x_220121a.lef\n"+libs+f"""
read_verilog {OUT}/mapped.v
link_design {TOP}
report_units
create_clock -name core_clk -period {period} [get_ports clk]
set_input_transition {CFG['input_slew_ps']} [all_inputs]
set_input_delay {CFG['io_delay_ps']} -clock core_clk [get_ports {{a_dtype_i* b_dtype_i* a_vec_i* b_vec_i* c_i* scale_input_d_i* in_vld_i out_rdy_i}}]
set_output_delay {CFG['io_delay_ps']} -clock core_clk [all_outputs]
set_load {CFG['output_load_ff']} [all_outputs]
set_false_path -from [get_ports rst_n]
set_clock_transition {CFG['input_slew_ps']} [get_clocks core_clk]
check_setup -verbose
"""

def timing(period,label):
    tcl=OUT/(label+".tcl")
    tcl.write_text(sta_base(period)+"""
report_checks -path_delay max -group_path_count 5 -digits 6
report_worst_slack -max -digits 6
report_design_area
report_check_types -max_slew -max_capacitance -max_fanout -violators
""")
    log=OUT/(label+".log")
    run([OPENROAD,"-exit",tcl],log)
    s=re.search(r"worst slack(?: max)?\s+([-+\d.eE]+)",log.read_text())
    assert s,"STA failed to report slack"
    return float(s[1])

def synth():
    (OUT/"lib").mkdir(exist_ok=True)
    libmeta=[]
    for p in liberty_files():
        dest=OUT/"lib"/p.name.removesuffix(".gz")
        content=gzip.decompress(p.read_bytes()) if p.suffix==".gz" else p.read_bytes()
        dest.write_bytes(content)
        txt=content.decode()
        meta={k:re.search(r"\b"+k+r"\s*:\s*([^;]+)",txt)[1].strip() for k in
              ("time_unit","leakage_power_unit","nom_voltage","nom_temperature")}
        assert float(meta["nom_voltage"])==0.7 and float(meta["nom_temperature"])==25
        assert meta["time_unit"]=='"1ps"'
        libmeta.append({"file":dest.name,"sha256":sha(dest),**meta})
    assert len(libmeta)==5,libmeta
    save(OUT/"library.json",libmeta)
    libs=sorted((OUT/"lib").glob("*.lib"))
    libargs=" ".join(f"-liberty {p}" for p in libs)
    seq=next(p for p in libs if "_SEQ_" in p.name)
    (OUT/"abc.constr").write_text(f"set_driving_cell BUFx2_ASAP7_75t_R\nset_load {CFG['output_load_ff']}\n")
    # ABC uses the complete RVT TT library; asynchronous reset remains functional.
    ys=OUT/"synth.ys"
    ys.write_text("\n".join(f"read_liberty -lib {p}" for p in libs)+f"""
read_verilog {OUT}/converted.v
hierarchy -check -top {TOP}
synth -top {TOP} -flatten -noabc
dfflibmap -liberty {seq}
abc {libargs} -constr {OUT}/abc.constr -D {CFG['period_ps']}
clean
delete t:$scopeinfo
check -assert
tee -o {OUT}/synth_stat.json stat -json {libargs}
write_verilog -noattr -noexpr -nodec {OUT}/mapped.v
write_json {OUT}/mapped.json
""")
    run([YOSYS,"-Q","-T","-s",ys],OUT/"synthesis.log")
    net=json.loads((OUT/"mapped.json").read_text())
    cells=net["modules"][TOP]["cells"]
    assert cells and all(not c["type"].startswith("$") for c in cells.values())
    assert all(c["type"] in net["modules"] for c in cells.values())
    assert all(p in net["modules"][TOP]["ports"] for p in
               ["a_dtype_i","b_dtype_i","scale_input_d_i","c_i","in_vld_i","out_rdy_i"])
    # Build zero-delay functional cell models directly from the same Liberty logic.
    ys=OUT/"cell_models.ys"
    ys.write_text("\n".join(f"read_liberty -ignore_miss_func -ignore_miss_dir {p}" for p in libs)+
                  f"\nwrite_verilog -noattr {OUT}/cells.v\n")
    run([YOSYS,"-Q","-T","-s",ys],OUT/"cell_models.log")
    period=CFG["period_ps"]
    slack=timing(period,"timing_initial")
    if slack<0:
        period=math.ceil((period-slack)*1.1/10)*10
        slack=timing(period,"timing_selected")
    assert slack>=0,slack
    save(OUT/"timing.json",{"period_ps":period,"frequency_hz":1e12/period,"worst_slack_ps":slack,
                            "cell_count":len(cells),"synthesis_level":"no interconnect parasitics; ideal clock"})
    run([YOSYS,"-V"],OUT/"yosys_version.txt")
    run([OPENROAD,"-version"],OUT/"openroad_version.txt")

def generate_vectors():
    import random
    import struct
    sys.path.insert(0,str(ROOT/"verification/cocotb"))
    from mma_sim_fp16_ref import FP16DotMmaSimGolden,FP16
    golden=FP16DotMmaSimGolden()
    for seed in CFG["seeds"]:
        rng=random.Random(seed)
        with (OUT/f"vectors_{seed}.txt").open("w") as f:
            for i in range(CFG["warmup_cycles"]+CFG["measure_cycles"]):
                a=sum(int.from_bytes(struct.pack("<e",rng.uniform(-1,1)),"little")<<(16*j) for j in range(16))
                b=sum(int.from_bytes(struct.pack("<e",rng.uniform(-1,1)),"little")<<(16*j) for j in range(16))
                e=golden(a,b,0,FP16)
                f.write(f"{a:064x} {b:064x} {e:08x}\n")
        print(f"Golden vectors ready: seed {seed}",flush=True)

def regression(kind,sources):
    import xml.etree.ElementTree as ET
    work=OUT/("regression_"+kind);work.mkdir(exist_ok=True)
    env=os.environ.copy()
    env.update(PYTHONPATH=str(ROOT/"verification/cocotb")+os.pathsep+str(ROOT/"MMA-Sim"),
               NUM_CASES=str(CFG["regression_cases"]),RANDOM_SEED="20260429")
    bindir=OUT/"bin";bindir.mkdir(exist_ok=True)
    helper=bindir/"cocotb-config"
    helper.write_text("#!/bin/sh\nexec python3 -m cocotb.config \"$@\"\n");helper.chmod(0o755)
    env["PATH"]=str(bindir)+os.pathsep+env["PATH"]
    makefiles=subprocess.check_output([sys.executable,"-m","cocotb.config","--makefiles"],text=True).strip()
    run(["make","-j",os.environ.get("JOBS","8"),"-f",makefiles+"/Makefile.sim","SIM=verilator",
         "TOPLEVEL_LANG=verilog","TOPLEVEL="+TOP,"MODULE=test_f16tf32_dot",
         "VERILOG_SOURCES="+" ".join(map(str,sources)),"SIM_BUILD="+str(work/"sim"),
         "COCOTB_RESULTS_FILE="+str(work/"results.xml"),
         "EXTRA_ARGS=--timing --gate-stmts 0 -Wno-fatal"],OUT/("regression_"+kind+".log"),env,work)
    xml=ET.parse(work/"results.xml").getroot()
    assert xml.findall(".//testcase") and not xml.findall(".//failure") and not xml.findall(".//error")

def simulate(measure_only=False):
    if not measure_only:generate_vectors()
    period=json.loads((OUT/"timing.json").read_text())["period_ps"]
    for kind,sources in [("rtl",SOURCES),("converted",[OUT/"converted.v"]),("gate",[OUT/"cells.v",OUT/"mapped.v"])]:
        if measure_only and kind!="gate":continue
        if not measure_only:regression(kind,sources)
        obj=OUT/("obj_"+kind)
        run(["verilator","--cc","--exe","--trace","--trace-depth","99",
             "--trace-structs","--trace-underscore","--timescale","1ps/1ps","--top-module",TOP,"--Mdir",obj,
             "-j","1","--gate-stmts","0","-Wno-fatal",
             *sources,HERE/"bench.cpp"],OUT/("compile_"+kind+".log"))
        run(["make","-C",obj,"-f","V"+TOP+".mk","-j",os.environ.get("JOBS","8")],
            OUT/("build_"+kind+".log"))
        for seed in CFG["seeds"]:
            run([obj/("V"+TOP),OUT/f"vectors_{seed}.txt",OUT/f"results_{kind}_{seed}.txt",
                 OUT/f"activity_{seed}.vcd" if kind=="gate" else "-",str(period),
                 str(CFG["warmup_cycles"]),str(CFG["measure_cycles"])],OUT/f"bench_{kind}_{seed}.log")
            if kind!="rtl":
                assert (OUT/f"results_{kind}_{seed}.txt").read_bytes()==(OUT/f"results_rtl_{seed}.txt").read_bytes()
            if kind=="gate":
                vcd=OUT/f"activity_{seed}.vcd"
                with vcd.open("rb") as src,gzip.open(str(vcd)+".gz","wb",compresslevel=1) as dest:
                    shutil.copyfileobj(src,dest)
                vcd.unlink()
        # Keep source, logs, vectors and XML; transient object files are reproducible.
        shutil.rmtree(obj)
        shutil.rmtree(OUT/("regression_"+kind)/"sim",ignore_errors=True)
    save(OUT/"validation.json",{"status":"passed","models":["rtl","converted","gate"],
          "golden":"MMA-Sim FP16DotMmaSimGolden F=25 RZ","measured_vectors_per_seed":CFG["measure_cycles"],
          "regression_random_cases_per_model":CFG["regression_cases"],"seeds":CFG["seeds"]})

def power():
    period=json.loads((OUT/"timing.json").read_text())["period_ps"]
    for seed in CFG["seeds"]:
        tcl=OUT/f"power_{seed}.tcl"
        tcl.write_text(sta_base(period)+f"""
read_vcd -scope TOP/{TOP} {OUT}/activity_{seed}.vcd.gz
report_activity_annotation
report_activity_annotation -report_unannotated > {OUT}/unannotated_{seed}.txt
report_power -digits 10
report_design_area
""")
        run([OPENROAD,"-exit",tcl],OUT/f"power_{seed}.log")

def summarize():
    assert json.loads((OUT/"validation.json").read_text())["status"]=="passed"
    timing_data=json.loads((OUT/"timing.json").read_text())
    rows=[]
    for seed in CFG["seeds"]:
        text=(OUT/f"power_{seed}.log").read_text()
        annotated=int(re.search(r"^vcd\s+(\d+)",text,re.M)[1])
        missing=int(re.search(r"^unannotated\s+(\d+)",text,re.M)[1])
        assert annotated>0 and missing==0,f"Incomplete activity coverage: {annotated} VCD, {missing} unannotated"
        assert "Power (Watts)" in text,"Unknown power report unit"
        with gzip.open(OUT/f"activity_{seed}.vcd.gz","rt") as vcd:
            timescale=False;first_time=last_time=None
            for line in vcd:
                if line.startswith("$timescale"):timescale=line.strip()=="$timescale 1ps $end"
                if line.startswith("#"):
                    last_time=int(line[1:])
                    if first_time is None:first_time=last_time
        assert timescale and first_time==0
        assert last_time==CFG["measure_cycles"]*timing_data["period_ps"],"VCD duration differs from throughput window"
        total=re.search(r"^Total\s+([\d.eE+-]+)\s+([\d.eE+-]+)\s+([\d.eE+-]+)\s+([\d.eE+-]+)",text,re.M)
        assert total,"Missing power totals"
        internal,switching,leakage,power_w=map(float,total.groups())
        stats=json.loads((OUT/f"bench_gate_{seed}.log").read_text().strip())
        seconds=stats["measurement_cycles"]*stats["period_ps"]*1e-12
        flops=stats["measurement_results"]*CFG["flops_per_result"]
        assert power_w>0 and abs(power_w-internal-switching-leakage)<power_w*1e-6
        rows.append({"seed":seed,"period_ps":timing_data["period_ps"],"completed":stats["measurement_results"],
                     "vcd_annotated_pins":annotated,"unannotated_pins":missing,
                     "window_s":seconds,"internal_w":internal,"switching_w":switching,"leakage_w":leakage,
                     "total_w":power_w,"gflops":flops/seconds/1e9,"gflops_per_w":flops/seconds/1e9/power_w,
                     "pj_per_flop":power_w*seconds/flops*1e12})
    with (OUT/"results.csv").open("w") as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    stat=json.loads((OUT/"synth_stat.json").read_text())
    area=stat["design"]["area"]
    result={"config":CFG,"timing":timing_data,"cell_area_um2":area,"rows":rows,
            "median":{key:statistics.median(r[key] for r in rows) for key in rows[0] if key!="seed"}}
    save(OUT/"results.json",result)
    med=result["median"]
    environment=json.loads((OUT/"environment.json").read_text())
    table="\n".join(f"| {r['seed']} | {r['internal_w']*1e3:.6f} | {r['switching_w']*1e3:.6f} | {r['leakage_w']*1e6:.6f} | {r['total_w']*1e3:.6f} | {r['gflops_per_w']:.3f} | {r['pj_per_flop']:.6f} |" for r in rows)
    report=f"""# Allegro 单点积单元能效报告

对象：一个完整的 `f16tf32_dot_prod`，保留 TF32/BF16/FP16 运行时选择硬件、五级流水及握手控制。
测试模式：FP16×FP16→FP32，K=16，C=0，scale=0，连续满载，无输出背压。

## 结果

三组种子的中位能效为 **{med['gflops_per_w']:.3f} GFLOP/s/W**，即 **{med['pj_per_flop']:.6f} pJ/FLOP**。
对应吞吐为 **{med['gflops']:.6f} GFLOP/s**，总功耗 **{med['total_w']*1e3:.6f} mW**。

| 种子 | Internal (mW) | Switching (mW) | Leakage (µW) | Total (mW) | GFLOP/s/W | pJ/FLOP |
|---|---:|---:|---:|---:|---:|---:|
{table}

## 条件与算法

- ASAP7 RVT TT NLDM，0.7 V，25°C；库文件和哈希见 `library.json`，排除 FAKE 单元库。
- 周期 {timing_data['period_ps']} ps，频率 {timing_data['frequency_hz']/1e6:.6f} MHz，最差 setup slack {timing_data['worst_slack_ps']:.6f} ps。
- 标准单元数 {timing_data['cell_count']}，Liberty 单元面积总和 {area:.6f} µm²；这是单元面积，不是布局后核心面积。
- 初始 1 GHz 约束经过综合后，按所需周期加 10% 裕量、向上取整至 10 ps 选定工作周期。
- 输入 slew 50 ps，IO 延迟各 100 ps，输出负载每端口 3.898 fF；理想时钟；复位不参与功能 setup 路径。
- ABC 使用 BUFx2 输入驱动及 3.898 fF 输出负载进行门级缓冲和尺寸选择；无布局布线。
- 每种子预热 256 周期，功耗与吞吐均覆盖随后 10,000 周期（{med['window_s']*1e6:.3f} µs）。
- 每组窗口完成 10,000 个点积，即 320,000 FLOP。按常用 2K 口径计数；功耗使用 internal + switching + leakage 总和。
- A/B 独立均匀取样于 [-1,1] 后转换为 FP16。功耗值依赖这组输入分布与固定 C=0 条件。

## 验证

- RTL、sv2v 转换后模型和映射网表均通过现有三精度数值及背压回归：每模型 1,000 个随机样例及定向样例。
- 每模型对三组各 10,256 个输入逐项匹配 MMA-Sim F=25/RZ 参考，输出时序也逐行一致。
- 稳态实际吞吐为 1 点积/周期；未以流水深度推算峰值。
- 门级波形显式启用下划线信号跟踪；每组 VCD 直接标注 {int(med['vcd_annotated_pins'])} 个引脚，未标注引脚为 0。
- VCD 的 1 ps 时间单位、起止时间及功率表的 Watts 单位均经过程序断言检查。

## 适用边界

这是基于 Liberty 与零延迟门级活动的综合级估算，不是硅片实测。时钟树缓冲、布线寄生、时延毛刺、TMEM/SMEM 和系统供电开销均不在边界内。
不能将结果直接当作 NVIDIA Tensor Core 或整卡能效。ASAP7 属于预测性工艺库，结果用于当前 RTL 的研究基线。

## 复现与证据

运行 ID：`{environment.get('run_id')}`。入口：`make dot-efficiency`，须在远端 Linux CPU 执行。
源码快照及哈希见 `source_snapshot.tar.gz` / `source_sha256.json`，环境见 `environment.json`。
数值结果见 `results.json` / `results.csv`；网表见 `mapped.v`；波形见 `activity_*.vcd.gz`；时序、功耗与回归日志保存在同目录。
若复用了先前已通过的验证，来源与证据哈希保存在 `reuse.json`、`reused_artifact_sha256.json` 和 `verification_source_*`。
"""
    (OUT/"REPORT.md").write_text(report)
    print(json.dumps(result["median"],indent=2),flush=True)

def remeasure():
    """Reuse verified arithmetic; recompile traced gate model and recompute power.

    Intended for trace-only changes. The prior run's artifacts must already be
    copied into OUT, with provenance in reuse.json. No prior run is modified.
    """
    import xml.etree.ElementTree as ET
    assert json.loads((OUT/"validation.json").read_text())["status"]=="passed"
    assert (OUT/"reuse.json").exists(),"Record the source run ID before reuse"
    manifest=json.loads((OUT/"source_sha256.json").read_text())
    critical=[*SOURCES,HERE/"bench.cpp",HERE/"config.json",HERE/"filelist.f",
              ROOT/"verification/cocotb/test_f16tf32_dot.py",ROOT/"verification/cocotb/mma_sim_fp16_ref.py",
              ROOT/"verification/cocotb/mma_sim_tf32_ref.py"]
    for path in critical:
        assert manifest[str(path.relative_to(ROOT))]==sha(path),f"Changed verification input: {path}"
    for kind in ["rtl","converted","gate"]:
        xml=ET.parse(OUT/("regression_"+kind)/"results.xml").getroot()
        assert xml.findall(".//testcase") and not xml.findall(".//failure") and not xml.findall(".//error")
    evidence=[OUT/"mapped.v",OUT/"cells.v",OUT/"timing.json",OUT/"validation.json"]
    evidence+=list(OUT.glob("vectors_*.txt"))+list(OUT.glob("results_rtl_*.txt"))
    save(OUT/"reused_artifact_sha256.json",{p.name:sha(p) for p in evidence})
    shutil.copy2(OUT/"source_snapshot.tar.gz",OUT/"verification_source_snapshot.tar.gz")
    shutil.copy2(OUT/"source_sha256.json",OUT/"verification_source_sha256.json")
    converted_hash=sha(OUT/"converted.v")
    prepare()
    assert sha(OUT/"converted.v")==converted_hash,"Conversion changed"
    simulate(measure_only=True)
    container_stage("power")
    summarize()

def container_stage(stage):
    name="dot-eff-"+str(os.getpid())+"-"+stage
    command=["docker","run","--rm","--name",name,"--network","none","--user",f"{os.getuid()}:{os.getgid()}",
             "--label","codex.task=dot-efficiency","--label","codex.work="+str(ROOT),
             "--cpuset-cpus",",".join(map(str,sorted(os.sched_getaffinity(0)))),
             "-v",str(ROOT)+":/work","-w","/work",CFG["image"],"python3","verification/benchmarks/dot_efficiency/run.py",stage]
    try:run(command,OUT/("stage_"+stage+".log"))
    finally:subprocess.run(["docker","rm","-f",name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage",choices=["all","prepare","synth","simulate","power","summarize","remeasure"])
    args=parser.parse_args()
    if sys.platform!="linux":raise SystemExit("Run this flow on the configured remote Linux CPU.")
    os.chdir(ROOT);OUT.mkdir(parents=True,exist_ok=True)
    signal.signal(signal.SIGTERM,lambda *_:sys.exit(143))
    if args.stage=="all":
        prepare();container_stage("synth");simulate();container_stage("power");summarize()
    else:globals()[args.stage]()

if __name__=="__main__":main()
