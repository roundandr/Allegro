// Independent hardware observations for descriptor v3 layouts and conversions.
// Each invocation runs one case; finite mbarrier polling reports a byte-count
// mismatch instead of hanging the GPU. Build with nvcc -arch=sm_120a -lcuda.
#include <cuda.h>
#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <vector>
#define CUDA(x) do { auto e=(x);if(e!=cudaSuccess){fprintf(stderr,"CUDA %s\n",cudaGetErrorString(e));return 2;} }while(0)
struct Args {int rank,mode,bytes,c[5];};
__global__ void sample(const __grid_constant__ CUtensorMap map, Args a, unsigned *out) {
    __shared__ __align__(1024) unsigned char data[4096];
    __shared__ __align__(8) unsigned long long barrier;
    for (int i=threadIdx.x;i<4096;i+=blockDim.x)data[i]=0xcd;
    unsigned b=__cvta_generic_to_shared(&barrier);
    if(threadIdx.x==0) asm volatile("mbarrier.init.shared::cta.b64 [%0], 1;"::"r"(b):"memory");
    __syncthreads();
    if(threadIdx.x==0) {
        unsigned s=__cvta_generic_to_shared(data);
        asm volatile("fence.proxy.async.shared::cta;":::"memory");
        asm volatile("mbarrier.arrive.expect_tx.release.cta.shared::cta.b64 _, [%0], %1;"::"r"(b),"r"(a.bytes):"memory");
        if(a.mode==5) {
            asm volatile("cp.async.bulk.tensor.2d.tile::gather4.shared::cta.global.mbarrier::complete_tx::bytes [%0], [%1, {%2,%3,%4,%5,%6}], [%7];"::"r"(s),"l"(&map),"r"(a.c[0]),"r"(a.c[1]),"r"(a.c[2]),"r"(a.c[3]),"r"(a.c[4]),"r"(b):"memory");
        } else if(a.rank==3) {
            asm volatile("cp.async.bulk.tensor.3d.shared::cta.global.mbarrier::complete_tx::bytes [%0], [%1, {%2,%3,%4}], [%5];"::"r"(s),"l"(&map),"r"(a.c[0]),"r"(a.c[1]),"r"(a.c[2]),"r"(b):"memory");
        } else {
            asm volatile("cp.async.bulk.tensor.2d.shared::cta.global.mbarrier::complete_tx::bytes [%0], [%1, {%2,%3}], [%4];"::"r"(s),"l"(&map),"r"(a.c[0]),"r"(a.c[1]),"r"(b):"memory");
        }
        unsigned done=0;
        for(int i=0;i<10000 && !done;++i) asm volatile("{.reg .pred p; mbarrier.try_wait.parity.acquire.cta.shared::cta.b64 p, [%1], 0; selp.u32 %0, 1, 0, p;}" : "=r"(done):"r"(b):"memory");
        out[1024]=done;
    }
    __syncthreads();
    for(int i=threadIdx.x;i<1024;i+=blockDim.x)out[i]=reinterpret_cast<unsigned*>(data)[i];
}
int main(int argc,char**argv) {
    int test=argc>1?atoi(argv[1]):0, override_bytes=argc>2?atoi(argv[2]):0;
    cuInit(0);unsigned *g,*out;CUDA(cudaMalloc(&g,1<<20));CUDA(cudaMalloc(&out,4100));
    std::vector<unsigned> input((1<<20)/4),output(1025);
    for(unsigned i=0;i<input.size();++i)input[i]=i+1;
    int dtype=2,interleave=0,swizzle=0,fill=0;
    cuuint64_t sizes[5]={32,4,2,1,1},strides[4]={128,512,1024,1024};
    cuuint32_t box[5]={16,2,1,1,1},step[5]={1,1,1,1,1};
    Args a={};a.rank=3;a.bytes=128;
    if(test<4){interleave=1+test/2;swizzle=interleave==2?1:0;a.c[0]=(test%2)*4;}
    else if(test==4){a.rank=2;a.mode=5;box[0]=8;box[1]=1;a.c[0]=4;a.c[1]=2;a.c[2]=0;a.c[3]=3;a.c[4]=1;}
    else if(test<8){a.rank=2;dtype=13+test-5;sizes[0]=256;box[0]=128;box[1]=2;strides[0]=256;interleave=0;a.bytes=dtype==13?128:256;}
    else if(test<18){
        a.rank=2;dtype=(test-8)/2==0?7:(test-8)/2==1?8:(test-8)/2==2?10:(test-8)/2==3?11:12;
        fill=(test-8)%2; a.c[1]=fill?5:0;
        unsigned values[]={0x3f801001,0x3f803000,0x3f805000,0x80000001,0x00000001,0x007fffff,0x7f800001,0x7fc00001,0xff800001,0x7f800000,0xff800000,0xbf801000,0x3fffffff,0x00002000,0x80000000,0};
        for(unsigned i=0;i<input.size();++i)input[i]=values[i%16];
        a.bytes=128;
        if(dtype==10){box[0]=32;a.bytes=128;}
    } else if(test==18){a.rank=2;dtype=6;fill=1;a.c[1]=5;box[0]=32;a.bytes=128;}
    else if(test==19){a.rank=2;dtype=9;fill=1;a.c[1]=5;box[0]=8;sizes[0]=16;a.bytes=128;}
    else if(test<30){
        interleave=1;swizzle=0;a.rank=3;sizes[0]=4;sizes[1]=16;sizes[2]=2;
        strides[0]=64;strides[1]=256;box[0]=2;box[1]=8;box[2]=1;
        a.bytes=64;
        if(test==21)a.c[1]=1;
        if(test==22)a.c[1]=4;
        if(test==23)step[0]=2;
        if(test==24)step[1]=2;
        if(test==25){step[1]=2;box[1]=12;}
        if(test==26){box[1]=5;a.c[1]=4;}
        if(test==27){box[1]=4;box[2]=2;}
        if(test==28){a.c[1]=14;box[1]=8;}
        if(test==29){a.c[0]=3;box[0]=3;}
    } else if(test<40){
        interleave=1;swizzle=0;a.rank=3;sizes[0]=4;sizes[1]=128;sizes[2]=2;
        strides[0]=64;strides[1]=8192;box[0]=2;box[1]=1u << (test-30);box[2]=1;
        a.bytes=32*((box[1]+15)/16);
    } else {return 3;}
    if(override_bytes)a.bytes=override_bytes;
    CUDA(cudaMemcpy(g,input.data(),1<<20,cudaMemcpyHostToDevice));
    // CUDA enum differs from the PTX dtype numbering for f64/bf16/f32.ftz.
    int cuda_dtype=dtype==8?10:dtype==9?8:dtype==10?9:dtype;
    alignas(64) CUtensorMap map;
    CUresult e=cuTensorMapEncodeTiled(&map,(CUtensorMapDataType)cuda_dtype,a.rank,g,sizes,strides,box,step,(CUtensorMapInterleave)interleave,(CUtensorMapSwizzle)swizzle,CU_TENSOR_MAP_L2_PROMOTION_NONE,(CUtensorMapFloatOOBfill)fill);
    if(e!=CUDA_SUCCESS){const char*name;cuGetErrorName(e,&name);fprintf(stderr,"case %d encode: %s\n",test,name);return 4;}
    sample<<<1,128>>>(map,a,out);CUDA(cudaGetLastError());CUDA(cudaDeviceSynchronize());CUDA(cudaMemcpy(output.data(),out,4100,cudaMemcpyDeviceToHost));
    printf("{\"id\":%d,\"dtype\":%d,\"interleave\":%d,\"swizzle\":%d,\"fill\":%d,\"rank\":%d,\"mode\":%d,\"bytes\":%d,\"complete\":%u,\"sizes\":[",test,dtype,interleave,swizzle,fill,a.rank,a.mode,a.bytes,output[1024]);
    for(int i=0;i<a.rank;++i)printf("%s%llu",i?",":"",(unsigned long long)sizes[i]);
    printf("],\"strides\":[");for(int i=0;i<a.rank-1;++i)printf("%s%llu",i?",":"",(unsigned long long)strides[i]);
    printf("],\"box\":[");for(int i=0;i<a.rank;++i)printf("%s%u",i?",":"",box[i]);
    printf("],\"coords\":[");for(int i=0;i<5;++i)printf("%s%d",i?",":"",a.c[i]);
    printf("],\"words\":[");bool first=true;for(int i=0;i<1024;++i)if(output[i]!=0xcdcdcdcd){printf("%s[%d,%u]",first?"":",",i*4,output[i]);first=false;}puts("]}");
    CUDA(cudaFree(out));CUDA(cudaFree(g));
}
