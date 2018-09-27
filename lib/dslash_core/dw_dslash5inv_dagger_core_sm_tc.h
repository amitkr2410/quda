// *** CUDA DSLASH DAGGER ***

#define DSLASH_SHARED_FLOATS_PER_THREAD 0

// This is for tensor core ONLY so assumming CUDA_VERSION >= 9000

// input spinor needs to be half
#define POW(a, b) __fast_pow(a, b)
#define i00_re I0.x
#define i00_im I0.y
#define i01_re I0.z
#define i01_im I0.w
#define i02_re I1.x
#define i02_im I1.y
#define i10_re I1.z
#define i10_im I1.w
#define i11_re I2.x
#define i11_im I2.y
#define i12_re I2.z
#define i12_im I2.w
#define i20_re I3.x
#define i20_im I3.y
#define i21_re I3.z
#define i21_im I3.w
#define i22_re I4.x
#define i22_im I4.y
#define i30_re I4.z
#define i30_im I4.w
#define i31_re I5.x
#define i31_im I5.y
#define i32_re I5.z
#define i32_im I5.w
#define m5 param.m5_f
#define mdwf_b5 param.mdwf_b5_f
#define mdwf_c5 param.mdwf_c5_f
#define mferm param.mferm_f
#define a param.a
#define b param.b

float scale = 1e4f;

MDWFSharedMemory<float4> sm_data;

// const int M = param.dc.Ls*4;
constexpr int M = 12*4;
const int N = 6*blockDim.x;
// const int K = param.dc.Ls*4;

constexpr int sm_m_pad_size = 0;
constexpr int sm_n_pad_size = 16;

const int N_sm = N + sm_n_pad_size;
constexpr int M_sm = M + sm_m_pad_size;

half2* sm_b = (half2*)( (void*)sm_data );
// half* sm_c = (half*)(sm_b + K*(N_sm));
half* sm_c = (half*)( sm_b );
half* sm_a = (half*)( sm_c + (M*(N_sm)) );

{ // Construct matrix A: TODO: should be careful about the idle threads.

  int offset_k = threadIdx.y*4;
  int one_or_zero = threadIdx.x >> 4; // Assumming blockDim.x = 32
  int xxx = threadIdx.x-one_or_zero*16;
  int offset_m = xxx*4;

  // threadIdx.x should not be idle(?).
  // With Ls=12 and blockDim.x=32 the following gives a 2-way bank conflict.  
  if(xxx < param.dc.Ls && threadIdx.x < 32){

#ifdef MDWF_mode   // Check whether MDWF option is enabled
    half kappa = -(static_cast<half>(mdwf_c5[ xxx ])*(static_cast<half>(4.0) + static_cast<half>(m5)) - static_cast<half>(1.0))/(static_cast<half>(mdwf_b5[ xxx ])*(static_cast<half>(4.0) + static_cast<half>(m5)) + static_cast<half>(1.0));
#else
    half kappa = static_cast<half>(2.0)*static_cast<half>(a);
#endif  // select MDWF mode

    half inv_d_n = static_cast<half>(0.5) / ( static_cast<half>(1.0) + static_cast<half>(POW(kappa,param.dc.Ls))*static_cast<half>(mferm) );
    half factorR;
    half factorL;

    int exponent = xxx  > threadIdx.y ? param.dc.Ls-xxx+threadIdx.y : threadIdx.y-xxx;
    factorR = inv_d_n * static_cast<half>(POW(kappa,exponent))  * ( xxx > threadIdx.y ? static_cast<half>(-mferm) : static_cast<half>(1.0) );
    int exponent2 = xxx < threadIdx.y ? param.dc.Ls-threadIdx.y+xxx : xxx-threadIdx.y;
    factorL = inv_d_n * static_cast<half>(POW(kappa,exponent2)) * ( xxx < threadIdx.y ? static_cast<half>(-mferm) : static_cast<half>(1.0) );
    // (mu, s) by (nu, t). column-major.

    sm_a[ (offset_k+0)*M_sm+(offset_m+0+one_or_zero*2) ] = factorR + static_cast<half>(-2*one_or_zero+1)*factorL;
    //    sm_a[ (offset_k+0)*M_sm+(offset_m+2) ] = factorR - factorL;

    sm_a[ (offset_k+1)*M_sm+(offset_m+1+one_or_zero*2) ] = factorR + static_cast<half>(-2*one_or_zero+1)*factorL;
    //    sm_a[ (offset_k+1)*M_sm+(offset_m+3) ] = factorR - factorL;

    sm_a[ (offset_k+2)*M_sm+(offset_m+0+one_or_zero*2) ] = factorR + static_cast<half>(+2*one_or_zero-1)*factorL;
    //    sm_a[ (offset_k+2)*M_sm+(offset_m+2) ] = factorR + factorL;

    sm_a[ (offset_k+3)*M_sm+(offset_m+1+one_or_zero*2) ] = factorR + static_cast<half>(+2*one_or_zero-1)*factorL;
    //    sm_a[ (offset_k+3)*M_sm+(offset_m+3) ] = factorR + factorL;

    sm_a[ (offset_k+0)*M_sm+(offset_m+1+one_or_zero*2) ] = static_cast<half>(0.);
    //    sm_a[ (offset_k+0)*M_sm+(offset_m+3) ] = static_cast<half>(0.0f);

    sm_a[ (offset_k+1)*M_sm+(offset_m+0+one_or_zero*2) ] = static_cast<half>(0.);
    //    sm_a[ (offset_k+1)*M_sm+(offset_m+2) ] = static_cast<half>(0.0f);

    sm_a[ (offset_k+2)*M_sm+(offset_m+1+one_or_zero*2) ] = static_cast<half>(0.);
    //    sm_a[ (offset_k+2)*M_sm+(offset_m+3) ] = static_cast<half>(0.0f);

    sm_a[ (offset_k+3)*M_sm+(offset_m+0+one_or_zero*2) ] = static_cast<half>(0.);
    //    sm_a[ (offset_k+3)*M_sm+(offset_m+2+one_or_zero*2) ] = static_cast<half>(0.0f);

  }

} // Construct matrix A

__syncthreads();

// for(int offset = threadIdx.y*blockDim.x+threadIdx.x; offset*4 < M*M_sm*2; offset += blockDim.x*blockDim.y){
//   memset((void*)(sm_a)+offset*4, 0, 4);
// }

#define SHARED_STRIDE 32 // to avoid bank conflicts on Fermi

#include "io_spinor.h"

bool idle = false;
int s4_base = blockIdx.x * blockDim.x; // base.
int s5 = blockIdx.y * blockDim.y + threadIdx.y;

int s4, sid;
int X, coord[5], boundaryCrossing;


// #pragma unroll
// for(int k = 0; k < 3; k++){
//   const int a_row = warp_m*WMMA_M;
//   const int a_col = k*WMMA_K;
//   nvcuda::wmma::load_matrix_sync(a_frag[k], sm_a+a_row+a_col*M_sm, M_sm);
// }

while(s4_base < param.threads){
  
  s4 = s4_base + threadIdx.x;
  sid = s5 * param.threads + s4;
  
  if (s4 >= param.threads){
    idle = true;
  }

  if(!idle){

    if( param.partial_length ){
      coordsFromIndexShrinked<5,QUDA_4D_PC,EVEN_X>(X, coord, sid, param);
    }else{

      boundaryCrossing = sid/param.dc.Xh[0] + sid/(param.dc.X[1]*param.dc.Xh[0]) + sid/(param.dc.X[2]*param.dc.X[1]*param.dc.Xh[0]);

      X = 2*sid + (boundaryCrossing + param.parity) % 2;
      coord[4] = X/(param.dc.X[0]*param.dc.X[1]*param.dc.X[2]*param.dc.X[3]);

    }

    //  boundaryCrossing = sid/param.dc.Xh[0] + sid/(param.dc.X[1]*param.dc.Xh[0]) + sid/(param.dc.X[2]*param.dc.X[1]*param.dc.Xh[0]);
    //  
    //  X = 2*sid + (boundaryCrossing + param.parity) % 2;
    //  coord[4] = X/(param.dc.X[0]*param.dc.X[1]*param.dc.X[2]*param.dc.X[3]);

    READ_SPINOR( SPINORTEX, param.sp_stride, X/2, X/2 );

    int offset_pre_m;
    int offset_pre_n = threadIdx.x*6;

    // data layout for tensor core B and C: s, spin, spatial, color, complex; Lsx4 by Lsx4 @ Lsx4 by 6xblockDim.x.
    // lda = Lsx4, column-major
    // ldb = blockDim.x x 6, row-major
    // total number of halves = Ls*24*blockDim.x
//    offset_pre_m = (coord[4]*4+0)*N_sm;
//    sm_b[ offset_pre_m+offset_pre_n+0 ] = i00_re*scale;
//    sm_b[ offset_pre_m+offset_pre_n+1 ] = i00_im*scale;
//    sm_b[ offset_pre_m+offset_pre_n+2 ] = i01_re*scale;
//    sm_b[ offset_pre_m+offset_pre_n+3 ] = i01_im*scale;
//    sm_b[ offset_pre_m+offset_pre_n+4 ] = i02_re*scale;
//    sm_b[ offset_pre_m+offset_pre_n+5 ] = i02_im*scale;
//    offset_pre_m = (coord[4]*4+1)*N_sm;
//    sm_b[ offset_pre_m+offset_pre_n+0 ] = i10_re*scale;
//    sm_b[ offset_pre_m+offset_pre_n+1 ] = i10_im*scale;
//    sm_b[ offset_pre_m+offset_pre_n+2 ] = i11_re*scale;
//    sm_b[ offset_pre_m+offset_pre_n+3 ] = i11_im*scale;
//    sm_b[ offset_pre_m+offset_pre_n+4 ] = i12_re*scale;
//    sm_b[ offset_pre_m+offset_pre_n+5 ] = i12_im*scale;
//    offset_pre_m = (coord[4]*4+2)*N_sm;
//    sm_b[ offset_pre_m+offset_pre_n+0 ] = i20_re*scale;
//    sm_b[ offset_pre_m+offset_pre_n+1 ] = i20_im*scale;
//    sm_b[ offset_pre_m+offset_pre_n+2 ] = i21_re*scale;
//    sm_b[ offset_pre_m+offset_pre_n+3 ] = i21_im*scale;
//    sm_b[ offset_pre_m+offset_pre_n+4 ] = i22_re*scale;
//    sm_b[ offset_pre_m+offset_pre_n+5 ] = i22_im*scale;
//    offset_pre_m = (coord[4]*4+3)*N_sm;
//    sm_b[ offset_pre_m+offset_pre_n+0 ] = i30_re*scale;
//    sm_b[ offset_pre_m+offset_pre_n+1 ] = i30_im*scale;
//    sm_b[ offset_pre_m+offset_pre_n+2 ] = i31_re*scale;
//    sm_b[ offset_pre_m+offset_pre_n+3 ] = i31_im*scale;
//    sm_b[ offset_pre_m+offset_pre_n+4 ] = i32_re*scale;
//    sm_b[ offset_pre_m+offset_pre_n+5 ] = i32_im*scale;
    
    offset_pre_m = (coord[4]*4+0)*N_sm;
    sm_b[ (offset_pre_m+offset_pre_n)/2+0 ] = __floats2half2_rn(i00_re*scale, i00_im*scale);
    sm_b[ (offset_pre_m+offset_pre_n)/2+1 ] = __floats2half2_rn(i01_re*scale, i01_im*scale);
    sm_b[ (offset_pre_m+offset_pre_n)/2+2 ] = __floats2half2_rn(i02_re*scale, i02_im*scale);
    offset_pre_m = (coord[4]*4+1)*N_sm;
    sm_b[ (offset_pre_m+offset_pre_n)/2+0 ] = __floats2half2_rn(i10_re*scale, i10_im*scale);
    sm_b[ (offset_pre_m+offset_pre_n)/2+1 ] = __floats2half2_rn(i11_re*scale, i11_im*scale);
    sm_b[ (offset_pre_m+offset_pre_n)/2+2 ] = __floats2half2_rn(i12_re*scale, i12_im*scale);
    offset_pre_m = (coord[4]*4+2)*N_sm;
    sm_b[ (offset_pre_m+offset_pre_n)/2+0 ] = __floats2half2_rn(i20_re*scale, i20_im*scale);
    sm_b[ (offset_pre_m+offset_pre_n)/2+1 ] = __floats2half2_rn(i21_re*scale, i21_im*scale);
    sm_b[ (offset_pre_m+offset_pre_n)/2+2 ] = __floats2half2_rn(i22_re*scale, i22_im*scale);
    offset_pre_m = (coord[4]*4+3)*N_sm;
    sm_b[ (offset_pre_m+offset_pre_n)/2+0 ] = __floats2half2_rn(i30_re*scale, i30_im*scale);
    sm_b[ (offset_pre_m+offset_pre_n)/2+1 ] = __floats2half2_rn(i31_re*scale, i31_im*scale);
    sm_b[ (offset_pre_m+offset_pre_n)/2+2 ] = __floats2half2_rn(i32_re*scale, i32_im*scale);
  }

  __syncthreads();

  // wmma.h
  {
    using namespace nvcuda;

    constexpr int WMMA_M = 16;
    constexpr int WMMA_N = 16;
    constexpr int WMMA_K = 16;
    
    constexpr int tm_dim = M >> 4;
    const int tn_dim = N >> 4;
    // const int tk_dim = K >> 4;
    
    // The actual/physical warp assigned to each thread in this block
    // int phys_warp_n_dim = float(blockDim.x)/float(warpSize); // TODO: should make sure blockDim.x is AT LEAST 32.
    // int phys_warp_m_dim = blockDim.y;
    
    const int total_warp = (blockDim.x*blockDim.y) >> 5;
    const int this_warp = (threadIdx.y*blockDim.x+threadIdx.x) >> 5;
    
    // int phys_warp_n = float(threadIdx.x)/float(warpSize);
    // int phys_warp_m = threadIdx.y; 
    
    // int total_num_warp = phys_warp_n_dim*phys_warp_m_dim;
    const int total_tile = tm_dim*tn_dim;
    
    const int warp_cycle = float(total_tile)/total_warp;
    const int warp_m = float(this_warp)*warp_cycle/tn_dim;

    for(int c = 0; c < warp_cycle; c++){
      // Set up the wmma stuff
      nvcuda::wmma::fragment<nvcuda::wmma::matrix_a, WMMA_M, WMMA_N, WMMA_K, half, nvcuda::wmma::col_major> a_frag;
      nvcuda::wmma::fragment<nvcuda::wmma::matrix_b, WMMA_M, WMMA_N, WMMA_K, half, nvcuda::wmma::row_major> b_frag;
      nvcuda::wmma::fragment<nvcuda::wmma::accumulator, WMMA_M, WMMA_N, WMMA_K, half> c_frag;

      // The logical warp assigned to each part of the matrix.
      int phys_warp_index = this_warp*warp_cycle+c;
//      int warp_m = float(phys_warp_index)/tn_dim;
      const int warp_n = phys_warp_index-warp_m*tn_dim;
      // Zero the initial acc.
      wmma::fill_fragment(c_frag, (half)0.0f);
      #pragma unroll
      for( int k = 0; k < 3; k++ ){

        const int a_row = warp_m*WMMA_M;
        const int a_col = k*WMMA_K;
        const int b_row = k*WMMA_K;
        const int b_col = warp_n*WMMA_N;

        //    if( a_row < M && a_col < K && b_row < K && b_col < N ){    
        // Load Matrix
        wmma::load_matrix_sync(a_frag, sm_a+a_row+a_col*M_sm, M_sm);
        wmma::load_matrix_sync(b_frag, sm_c+b_col+b_row*N_sm, N_sm);
        // Perform the matrix multiplication
        wmma::mma_sync(c_frag, a_frag, b_frag, c_frag);
        //    }
        //    __syncthreads();
      } 

      __syncthreads();

      int c_row = warp_m*WMMA_M;
      int c_col = warp_n*WMMA_N;

      if(c_row < M && c_col < N){ 
        wmma::store_matrix_sync(sm_c+c_col+c_row*N_sm, c_frag, N_sm, wmma::mem_row_major);
      }
      //  __syncthreads();
    }
    __syncthreads();

    
  } // wmma.h

  if(!idle){
    float o00_re = __half2float(sm_c[ (coord[4]*4+0)*(N_sm)+threadIdx.x*6+0 ])/scale;
    float o00_im = __half2float(sm_c[ (coord[4]*4+0)*(N_sm)+threadIdx.x*6+1 ])/scale;
    float o01_re = __half2float(sm_c[ (coord[4]*4+0)*(N_sm)+threadIdx.x*6+2 ])/scale;
    float o01_im = __half2float(sm_c[ (coord[4]*4+0)*(N_sm)+threadIdx.x*6+3 ])/scale;
    float o02_re = __half2float(sm_c[ (coord[4]*4+0)*(N_sm)+threadIdx.x*6+4 ])/scale;
    float o02_im = __half2float(sm_c[ (coord[4]*4+0)*(N_sm)+threadIdx.x*6+5 ])/scale;
    float o10_re = __half2float(sm_c[ (coord[4]*4+1)*(N_sm)+threadIdx.x*6+0 ])/scale;
    float o10_im = __half2float(sm_c[ (coord[4]*4+1)*(N_sm)+threadIdx.x*6+1 ])/scale;
    float o11_re = __half2float(sm_c[ (coord[4]*4+1)*(N_sm)+threadIdx.x*6+2 ])/scale;
    float o11_im = __half2float(sm_c[ (coord[4]*4+1)*(N_sm)+threadIdx.x*6+3 ])/scale;
    float o12_re = __half2float(sm_c[ (coord[4]*4+1)*(N_sm)+threadIdx.x*6+4 ])/scale;
    float o12_im = __half2float(sm_c[ (coord[4]*4+1)*(N_sm)+threadIdx.x*6+5 ])/scale;
    float o20_re = __half2float(sm_c[ (coord[4]*4+2)*(N_sm)+threadIdx.x*6+0 ])/scale;
    float o20_im = __half2float(sm_c[ (coord[4]*4+2)*(N_sm)+threadIdx.x*6+1 ])/scale;
    float o21_re = __half2float(sm_c[ (coord[4]*4+2)*(N_sm)+threadIdx.x*6+2 ])/scale;
    float o21_im = __half2float(sm_c[ (coord[4]*4+2)*(N_sm)+threadIdx.x*6+3 ])/scale;
    float o22_re = __half2float(sm_c[ (coord[4]*4+2)*(N_sm)+threadIdx.x*6+4 ])/scale;
    float o22_im = __half2float(sm_c[ (coord[4]*4+2)*(N_sm)+threadIdx.x*6+5 ])/scale;
    float o30_re = __half2float(sm_c[ (coord[4]*4+3)*(N_sm)+threadIdx.x*6+0 ])/scale;
    float o30_im = __half2float(sm_c[ (coord[4]*4+3)*(N_sm)+threadIdx.x*6+1 ])/scale;
    float o31_re = __half2float(sm_c[ (coord[4]*4+3)*(N_sm)+threadIdx.x*6+2 ])/scale;
    float o31_im = __half2float(sm_c[ (coord[4]*4+3)*(N_sm)+threadIdx.x*6+3 ])/scale;
    float o32_re = __half2float(sm_c[ (coord[4]*4+3)*(N_sm)+threadIdx.x*6+4 ])/scale;
    float o32_im = __half2float(sm_c[ (coord[4]*4+3)*(N_sm)+threadIdx.x*6+5 ])/scale;
    // write spinor field back to device memory
    WRITE_SPINOR(param.sp_stride);
  }

  s4_base += gridDim.x*blockDim.x;

} // while

// undefine to prevent warning when precision is changed
#undef m5
#undef mdwf_b5
#undef mdwf_c5
#undef mferm
#undef a
#undef b
#undef POW
#undef SHARED_STRIDE

#undef i00_re
#undef i00_im
#undef i01_re
#undef i01_im
#undef i02_re
#undef i02_im
#undef i10_re
#undef i10_im
#undef i11_re
#undef i11_im
#undef i12_re
#undef i12_im
#undef i20_re
#undef i20_im
#undef i21_re
#undef i21_im
#undef i22_re
#undef i22_im
#undef i30_re
#undef i30_im
#undef i31_re
#undef i31_im
#undef i32_re
#undef i32_im
