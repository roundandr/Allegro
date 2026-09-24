// Identical handshake-driven stimulus for RTL, converted RTL and mapped cells.
// VCD covers only the 10,000-cycle steady-state measurement window.
#include "Vf16tf32_dot_prod.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

struct Vec { std::array<uint32_t,8> a, b; uint32_t expected; };
static void unpack(const std::string& s, std::array<uint32_t,8>& a) {
    for (unsigned i=0;i<8;++i) a[i]=std::stoul(s.substr(56-8*i,8),nullptr,16);
}
int main(int argc,char** argv) {
    if (argc!=7) { std::cerr<<"vectors results vcd-or-dash period_ps warmup cycles\n"; return 2; }
    Verilated::commandArgs(argc,argv);
    Verilated::traceEverOn(true);
    Vf16tf32_dot_prod d;
    VerilatedVcdC trace;
    const uint64_t period=std::stoull(argv[4]);
    const unsigned warmup=std::stoul(argv[5]), cycles=std::stoul(argv[6]);
    std::ifstream in(argv[1]); std::string a,b,e;
    std::vector<Vec> vec;
    while(in>>a>>b>>e) { Vec v; unpack(a,v.a); unpack(b,v.b); v.expected=std::stoul(e,nullptr,16); vec.push_back(v); }
    if (vec.size()!=warmup+cycles) throw std::runtime_error("vector count mismatch");
    std::ofstream out(argv[2]);
    d.clk=0; d.rst_n=0; d.in_vld_i=0; d.out_rdy_i=1;
    d.a_dtype_i=2; d.b_dtype_i=2; d.c_i=0; d.scale_input_d_i=0;
    for (unsigned j=0;j<8;j++) { d.a_vec_i[j]=0; d.b_vec_i[j]=0; }
    for (unsigned j=0;j<8;j++) { d.clk=0;d.eval();d.clk=1;d.eval(); }
    d.clk=0; d.rst_n=1; d.eval();
    unsigned issued=0,retired=0,measured=0,measured_in=0;
    bool tracing=false;
    const bool want_trace=std::string(argv[3])!="-";
    if(want_trace) d.trace(&trace,99);
    for (unsigned tick=0;tick<warmup+cycles+32;tick++) {
        // Begin with previous cycle's settled low state, then drive inputs.
        if(tick==warmup && want_trace) { trace.open(argv[3]);tracing=true;trace.dump(0); }
        const uint64_t t=tick>=warmup ? uint64_t(tick-warmup)*period : 0;
        d.in_vld_i=issued<vec.size();
        if(d.in_vld_i) for(unsigned j=0;j<8;j++) {d.a_vec_i[j]=vec[issued].a[j];d.b_vec_i[j]=vec[issued].b[j];}
        d.eval();
        if(tracing) trace.dump(t+1);
        const bool fire_in=d.in_vld_i && d.in_rdy_o;
        const bool fire_out=d.out_vld_o && d.out_rdy_i;
        if(fire_out) {
            if(retired>=issued || d.d_o!=vec[retired].expected) {
                std::cerr<<"mismatch result "<<retired<<" got "<<std::hex<<d.d_o
                         <<" expected "<<vec.at(retired).expected<<"\n";return 1;
            }
            out<<tick<<" "<<retired<<" "<<std::hex<<d.d_o<<std::dec<<"\n";
            retired++;
        }
        if(fire_in) issued++;
        if(tick>=warmup && tick<warmup+cycles) {measured+=fire_out;measured_in+=fire_in;}
        d.clk=1;d.eval();if(tracing)trace.dump(t+period/2);
        d.clk=0;d.eval();if(tracing)trace.dump(t+period);
        if(tick+1==warmup+cycles && tracing) {trace.close();tracing=false;}
        if(issued==vec.size() && retired==vec.size())break;
    }
    if(issued!=vec.size() || retired!=vec.size() || measured!=cycles || measured_in!=cycles)
        throw std::runtime_error("lost transactions or unexpected steady-state stalls");
    std::cout<<"{\"issued\":"<<issued<<",\"retired\":"<<retired
             <<",\"measurement_results\":"<<measured<<",\"measurement_cycles\":"<<cycles
             <<",\"period_ps\":"<<period<<"}\n";
    d.final();
}
