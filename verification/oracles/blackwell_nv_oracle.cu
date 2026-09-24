// Optional hardware oracle for SM100a/SM120 common TMA modes.
// Build on an NVIDIA host: nvcc -std=c++17 -arch=sm_120a blackwell_nv_oracle.cu -lcuda -o oracle
// Emits sparse shared-memory words as JSON Lines. Not a normal regression dependency.
#include <cuda.h>
#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <vector>
#define CUDA(call) do { auto e=(call); if(e!=cudaSuccess) { fprintf(stderr,"%s: %s\n",#call,cudaGetErrorString(e)); exit(1); } } while(0)
#define DRIVER(call) do { auto e=(call); if(e!=CUDA_SUCCESS) { const char* s; cuGetErrorName(e,&s); fprintf(stderr,"%s: %s\n",#call,s); exit(1); } } while(0)
struct Args { int rank,mode,base,bytes,c[5],off[3],halo,wo; };
__global__ void run(const __grid_constant__ CUtensorMap map, Args a, unsigned* out) {
    __shared__ __align__(1024) unsigned char data[16384];
    __shared__ __align__(8) unsigned long long bar;
    for(int i=threadIdx.x;i<16384;i+=blockDim.x) data[i]=0xcd;
    if(threadIdx.x==0) {
        unsigned b=__cvta_generic_to_shared(&bar);
        asm volatile("mbarrier.init.shared::cta.b64 [%0], 1;"::"r"(b):"memory");
    }
    __syncthreads();
    if(threadIdx.x==0) {
        unsigned b=__cvta_generic_to_shared(&bar), s=__cvta_generic_to_shared(data+a.base);
        asm volatile("fence.proxy.async.shared::cta;":::"memory");
        asm volatile("mbarrier.arrive.expect_tx.release.cta.shared::cta.b64 _, [%0], %1;"::"r"(b),"r"(a.bytes):"memory");
        if(a.mode==0) {
            asm volatile("cp.async.bulk.tensor.2d.shared::cta.global.mbarrier::complete_tx::bytes [%0], [%1, {%2,%3}], [%4];"::"r"(s),"l"(&map),"r"(a.c[0]),"r"(a.c[1]),"r"(b):"memory");
        } else if(a.mode==1 && a.rank==3) {
            unsigned short off=a.off[0];
            asm volatile("cp.async.bulk.tensor.3d.shared::cta.global.im2col.mbarrier::complete_tx::bytes [%0], [%1, {%2,%3,%4}], [%5], {%6};"::"r"(s),"l"(&map),"r"(a.c[0]),"r"(a.c[1]),"r"(a.c[2]),"r"(b),"h"(off):"memory");
        } else if(a.mode==1 && a.rank==4) {
            unsigned short x=a.off[0], y=a.off[1];
            asm volatile("cp.async.bulk.tensor.4d.shared::cta.global.im2col.mbarrier::complete_tx::bytes [%0], [%1, {%2,%3,%4,%5}], [%6], {%7,%8};"::"r"(s),"l"(&map),"r"(a.c[0]),"r"(a.c[1]),"r"(a.c[2]),"r"(a.c[3]),"r"(b),"h"(x),"h"(y):"memory");
        } else if(a.mode==1 && a.rank==5) {
            unsigned short x=a.off[0], y=a.off[1], z=a.off[2];
            asm volatile("cp.async.bulk.tensor.5d.shared::cta.global.im2col.mbarrier::complete_tx::bytes [%0], [%1, {%2,%3,%4,%5,%6}], [%7], {%8,%9,%10};"::"r"(s),"l"(&map),"r"(a.c[0]),"r"(a.c[1]),"r"(a.c[2]),"r"(a.c[3]),"r"(a.c[4]),"r"(b),"h"(x),"h"(y),"h"(z):"memory");
        } else if(a.mode==2 && a.rank==5) {
            unsigned short halo=a.halo, off=a.wo;
            asm volatile("cp.async.bulk.tensor.5d.shared::cta.global.im2col::w.mbarrier::complete_tx::bytes [%0], [%1, {%2,%3,%4,%5,%6}], [%7], {%8,%9};"::"r"(s),"l"(&map),"r"(a.c[0]),"r"(a.c[1]),"r"(a.c[2]),"r"(a.c[3]),"r"(a.c[4]),"r"(b),"h"(halo),"h"(off):"memory");
        } else if(a.mode==2) {
            unsigned short halo=a.halo, off=a.wo;
            asm volatile("cp.async.bulk.tensor.4d.shared::cta.global.im2col::w.mbarrier::complete_tx::bytes [%0], [%1, {%2,%3,%4,%5}], [%6], {%7,%8};"::"r"(s),"l"(&map),"r"(a.c[0]),"r"(a.c[1]),"r"(a.c[2]),"r"(a.c[3]),"r"(b),"h"(halo),"h"(off):"memory");
        }
        unsigned done=0;
        do { asm volatile("{.reg .pred p; mbarrier.try_wait.parity.acquire.cta.shared::cta.b64 p, [%1], 0; selp.u32 %0, 1, 0, p;}" : "=r"(done) : "r"(b) : "memory"); } while(!done);
    }
    __syncthreads();
    for(int i=threadIdx.x;i<4096;i+=blockDim.x) out[i]=reinterpret_cast<unsigned*>(data)[i];
}
int main() {
    DRIVER(cuInit(0));
    unsigned *g,*out; CUDA(cudaMalloc(&g,1<<20)); CUDA(cudaMalloc(&out,16384));
    std::vector<unsigned> input((1<<20)/4), output(4096);
    for(unsigned i=0;i<input.size();++i) input[i]=i+1;
    CUDA(cudaMemcpy(g,input.data(),1<<20,cudaMemcpyHostToDevice));
    // Atom64 is checked against the PTX tables in the RTL suite. This SM120a
    // oracle deliberately covers only modes executed successfully on this GPU.
    for(int test=0;test<16;++test) {
        Args a={}; a.rank=2; a.base=(test%2)*128; a.c[0]=0; a.c[1]=0;
        cuuint64_t dims[5]={32,8,16,16,1}, stride[4]={128,1024,16384,262144};
        cuuint32_t box[5]={8,8,1,1,1}, step[5]={1,1,1,1,1};
        int lower[3]={0,0,0}, upper[3]={0,0,0}, channels=8,pixels=13;
        int swizzle=(test<6)?(test/2+1):((test>=10 && test<14)?(4+(test-10)/2):3);
        CUtensorMapSwizzle sw=static_cast<CUtensorMapSwizzle>(swizzle);
        if(test<6) { box[0]=8u<<(test/2); a.bytes=box[0]*box[1]*4; }
        if(test==6) { box[0]=8; box[1]=5;step[1]=2; a.bytes=8*3*4; }
        if(test>=10 && test<14) { box[0]=32; a.bytes=32*8*4; }
        if((test>=7 && test<=9) || test>=14) {
            a.rank=test==7?3:((test==14 || test==15)?5:4);
            a.mode=(test==9 || test==15)?2:1; a.base=128;
            dims[0]=16; dims[1]=5; dims[2]=8;dims[3]=8;
            stride[0]=64;stride[1]=320;stride[2]=2560;
            a.c[1]=1; a.c[2]=0; a.c[3]=0;
            step[1]=2; lower[0]=-1;upper[0]=-1;
            a.off[0]=1; a.off[1]=1; a.halo=test==9?2:0; a.wo=test==9?1:0;
            a.bytes=channels*(pixels+a.halo)*4;
            if(test>=14) {
                dims[4]=8;stride[3]=20480;a.off[2]=1;
                a.halo=a.mode>=2?2:0;a.wo=a.mode>=2?1:0;
                a.bytes=channels*(pixels+a.halo)*4;
            }
        }
        alignas(64) CUtensorMap map;
        if(a.mode==0) DRIVER(cuTensorMapEncodeTiled(&map,CU_TENSOR_MAP_DATA_TYPE_UINT32,a.rank,g,dims,stride,box,step,CU_TENSOR_MAP_INTERLEAVE_NONE,sw,CU_TENSOR_MAP_L2_PROMOTION_NONE,CU_TENSOR_MAP_FLOAT_OOB_FILL_NONE));
        else if(a.mode==1) DRIVER(cuTensorMapEncodeIm2col(&map,CU_TENSOR_MAP_DATA_TYPE_UINT32,a.rank,g,dims,stride,lower,upper,channels,pixels,step,CU_TENSOR_MAP_INTERLEAVE_NONE,sw,CU_TENSOR_MAP_L2_PROMOTION_NONE,CU_TENSOR_MAP_FLOAT_OOB_FILL_NONE));
        else DRIVER(cuTensorMapEncodeIm2colWide(&map,CU_TENSOR_MAP_DATA_TYPE_UINT32,a.rank,g,dims,stride,lower[0],upper[0],channels,pixels,step,CU_TENSOR_MAP_INTERLEAVE_NONE,CU_TENSOR_MAP_IM2COL_WIDE_MODE_W,sw,CU_TENSOR_MAP_L2_PROMOTION_NONE,CU_TENSOR_MAP_FLOAT_OOB_FILL_NONE));
        run<<<1,128>>>(map,a,out); CUDA(cudaGetLastError()); CUDA(cudaDeviceSynchronize());
        CUDA(cudaMemcpy(output.data(),out,16384,cudaMemcpyDeviceToHost));
        printf("{\"id\":%d,\"rank\":%d,\"mode\":%d,\"base\":%d,\"bytes\":%d,\"swizzle\":%d,\"dims\":[",test,a.rank,a.mode,a.base,a.bytes,swizzle);
        for(int i=0;i<a.rank;++i)printf("%s%llu",i?",":"",(unsigned long long)dims[i]);
        printf("],\"strides\":[4");for(int i=0;i<a.rank-1;++i)printf(",%llu",(unsigned long long)stride[i]);
        printf("],\"box\":[");for(int i=0;i<a.rank;++i)printf("%s%u",i?",":"",box[i]);
        printf("],\"step\":[");for(int i=0;i<a.rank;++i)printf("%s%u",i?",":"",step[i]);
        printf("],\"coords\":[");for(int i=0;i<a.rank;++i)printf("%s%d",i?",":"",a.c[i]);
        printf("],\"channels\":%d,\"pixels\":%d,\"lower\":[%d,%d,%d],\"upper\":[%d,%d,%d],\"offsets\":[%d,%d,%d],\"halo\":%d,\"woffset\":%d,\"words\":[",channels,pixels,lower[0],lower[1],lower[2],upper[0],upper[1],upper[2],a.off[0],a.off[1],a.off[2],a.halo,a.wo);
        bool first=true;
        for(int i=0;i<4096;++i) if(output[i]!=0xcdcdcdcd) { printf("%s[%d,%u]",first?"":",",i*4,output[i]);first=false; }
        printf("]}\n");
    }
    CUDA(cudaFree(g)); CUDA(cudaFree(out));
}
