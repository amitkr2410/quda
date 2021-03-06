#include <blas_quda.h>
#include <tune_quda.h>
#include <float_vector.h>
#include <color_spinor_field_order.h>

//#define QUAD_SUM
#ifdef QUAD_SUM
#include <dbldbl.h>
#endif

#include <cub_helper.cuh>

template<typename> struct ScalarType { };
template<> struct ScalarType<double> { typedef double type; };
template<> struct ScalarType<double2> { typedef double type; };
template<> struct ScalarType<double3> { typedef double type; };
template<> struct ScalarType<double4> { typedef double type; };

template<typename> struct Vec2Type { };
template<> struct Vec2Type<double> { typedef double2 type; };

#ifdef QUAD_SUM
#define QudaSumFloat doubledouble
#define QudaSumFloat2 doubledouble2
#define QudaSumFloat3 doubledouble3
template<> struct ScalarType<doubledouble> { typedef doubledouble type; };
template<> struct ScalarType<doubledouble2> { typedef doubledouble type; };
template<> struct ScalarType<doubledouble3> { typedef doubledouble type; };
template<> struct ScalarType<doubledouble4> { typedef doubledouble type; };
template<> struct Vec2Type<doubledouble> { typedef doubledouble2 type; };
#else
#define QudaSumFloat double
#define QudaSumFloat2 double2
#define QudaSumFloat3 double3
#define QudaSumFloat4 double4
#endif


void checkSpinor(const ColorSpinorField &a, const ColorSpinorField &b) {
  if (a.Precision() != b.Precision())
    errorQuda("precisions do not match: %d %d", a.Precision(), b.Precision());
  if (a.Length() != b.Length())
    errorQuda("lengths do not match: %lu %lu", a.Length(), b.Length());
  if (a.Stride() != b.Stride())
    errorQuda("strides do not match: %d %d", a.Stride(), b.Stride());
}

void checkLength(const ColorSpinorField &a, ColorSpinorField &b) {									\
  if (a.Length() != b.Length())
    errorQuda("lengths do not match: %lu %lu", a.Length(), b.Length());
  if (a.Stride() != b.Stride())
    errorQuda("strides do not match: %d %d", a.Stride(), b.Stride());
}

static struct {
  const char *vol_str;
  const char *aux_str;
  char aux_tmp[quda::TuneKey::aux_n];
} blasStrings;

// These are used for reduction kernels
static QudaSumFloat *d_reduce=0;
static QudaSumFloat *h_reduce=0;
static QudaSumFloat *hd_reduce=0;
static cudaEvent_t reduceEnd;
static bool fast_reduce_enabled = false;

namespace quda {
  namespace blas {

    cudaStream_t* getStream();

    void* getDeviceReduceBuffer() { return d_reduce; }
    void* getMappedHostReduceBuffer() { return hd_reduce; }
    void* getHostReduceBuffer() { return h_reduce; }
    cudaEvent_t* getReduceEvent() { return &reduceEnd; }
    bool getFastReduce() { return fast_reduce_enabled; }

    void initReduce()
    {
      /* we have these different reductions to cater for:

	 - regular reductions (reduce_quda.cu) where are reducing to a
           single vector type (max length 4 presently), with possibly
           parity dimension, and a grid-stride loop with max number of
           blocks = 2 x SM count

	 - multi-reductions where we are reducing to a matrix of size
	   of size MAX_MULTI_BLAS_N^2 of vectors (max length 4), with
	   possible parity dimension, and a grid-stride loop with
	   maximum number of blocks = 2 x SM count
      */

      const int reduce_size = 4 * sizeof(QudaSumFloat);
      const int max_reduce_blocks = 2*deviceProp.multiProcessorCount;

      const int max_reduce = 2 * max_reduce_blocks * reduce_size;
      const int max_multi_reduce = 2 * MAX_MULTI_BLAS_N * MAX_MULTI_BLAS_N * max_reduce_blocks * reduce_size;

      // reduction buffer size
      size_t bytes = max_reduce > max_multi_reduce ? max_reduce : max_multi_reduce;

      if (!d_reduce) d_reduce = (QudaSumFloat *) device_malloc(bytes);

      // these arrays are actually oversized currently (only needs to be QudaSumFloat3)

      // if the device supports host-mapped memory then use a host-mapped array for the reduction
      if (!h_reduce) {
	// only use zero copy reductions when using 64-bit
#if (defined(_MSC_VER) && defined(_WIN64)) || defined(__LP64__)
	if(deviceProp.canMapHostMemory) {
	  h_reduce = (QudaSumFloat *) mapped_malloc(bytes);
	  cudaHostGetDevicePointer(&hd_reduce, h_reduce, 0); // set the matching device pointer
	} else
#endif
	  {
	    h_reduce = (QudaSumFloat *) pinned_malloc(bytes);
	    hd_reduce = d_reduce;
	  }
	memset(h_reduce, 0, bytes); // added to ensure that valgrind doesn't report h_reduce is unitialised
      }

      cudaEventCreateWithFlags(&reduceEnd, cudaEventDisableTiming);

      // enable fast reductions with CPU spin waiting as opposed to using CUDA events
      char *fast_reduce_env = getenv("QUDA_ENABLE_FAST_REDUCE");
      if (fast_reduce_env && strcmp(fast_reduce_env,"1") == 0) {
        warningQuda("Experimental fast reductions enabled");
        fast_reduce_enabled = true;
      }

      checkCudaError();
    }

    void endReduce(void)
    {
      if (d_reduce) {
	device_free(d_reduce);
	d_reduce = 0;
      }
      if (h_reduce) {
	host_free(h_reduce);
	h_reduce = 0;
      }
      hd_reduce = 0;

      cudaEventDestroy(reduceEnd);
    }

    namespace reduce {

#include <texture.h>
#include <reduce_core.cuh>
#include <reduce_core.h>
#include <reduce_mixed_core.h>

    } // namespace reduce

    /**
       Base class from which all reduction functors should derive.
    */
    template <typename ReduceType, typename Float2, typename FloatN>
    struct ReduceFunctor {

      //! pre-computation routine called before the "M-loop"
      virtual __device__ __host__ void pre() { ; }

      //! where the reduction is usually computed and any auxiliary operations
      virtual __device__ __host__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y,
							   FloatN &z, FloatN &w, FloatN &v) = 0;

      //! post-computation routine called after the "M-loop"
      virtual __device__ __host__ void post(ReduceType &sum) { ; }

    };

    /**
       Return the L1 norm of x
    */
    template<typename ReduceType> __device__ __host__ ReduceType norm1_(const double2 &a) {
      return (ReduceType)fabs(a.x) + (ReduceType)fabs(a.y);
    }

    template<typename ReduceType> __device__ __host__ ReduceType norm1_(const float2 &a) {
      return (ReduceType)fabs(a.x) + (ReduceType)fabs(a.y);
    }

    template<typename ReduceType> __device__ __host__ ReduceType norm1_(const float4 &a) {
      return (ReduceType)fabs(a.x) + (ReduceType)fabs(a.y) + (ReduceType)fabs(a.z) + (ReduceType)fabs(a.w);
    }

    template <typename ReduceType, typename Float2, typename FloatN>
    struct Norm1 : public ReduceFunctor<ReduceType, Float2, FloatN> {
      Norm1(const Float2 &a, const Float2 &b) { ; }
      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z,FloatN  &w, FloatN &v)
      { sum += norm1_<ReduceType>(x); }
      static int streams() { return 1; } //! total number of input and output streams
      static int flops() { return 2; } //! flops per element
    };

    double norm1(const ColorSpinorField &x) {
      ColorSpinorField &y = const_cast<ColorSpinorField&>(x); // FIXME
      return reduce::reduceCuda<double,QudaSumFloat,Norm1,0,0,0,0,0,false>
	(make_double2(0.0, 0.0), make_double2(0.0, 0.0), y, y, y, y, y);
    }

    /**
       Return the L2 norm of x
    */
    template<typename ReduceType> __device__ __host__ void norm2_(ReduceType &sum, const double2 &a) {
      sum += (ReduceType)a.x*(ReduceType)a.x;
      sum += (ReduceType)a.y*(ReduceType)a.y;
    }

    template<typename ReduceType> __device__ __host__ void norm2_(ReduceType &sum, const float2 &a) {
      sum += (ReduceType)a.x*(ReduceType)a.x;
      sum += (ReduceType)a.y*(ReduceType)a.y;
    }

    template<typename ReduceType> __device__ __host__ void norm2_(ReduceType &sum, const float4 &a) {
      sum += (ReduceType)a.x*(ReduceType)a.x;
      sum += (ReduceType)a.y*(ReduceType)a.y;
      sum += (ReduceType)a.z*(ReduceType)a.z;
      sum += (ReduceType)a.w*(ReduceType)a.w;
    }


    template <typename ReduceType, typename Float2, typename FloatN>
      struct Norm2 : public ReduceFunctor<ReduceType, Float2, FloatN> {
      Norm2(const Float2 &a, const Float2 &b) { ; }
      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z,FloatN  &w, FloatN &v)
      { norm2_<ReduceType>(sum,x); }
      static int streams() { return 1; } //! total number of input and output streams
      static int flops() { return 2; } //! flops per element
    };

    double norm2(const ColorSpinorField &x) {
      ColorSpinorField &y = const_cast<ColorSpinorField&>(x);
      return reduce::reduceCuda<double,QudaSumFloat,Norm2,0,0,0,0,0,false>
	(make_double2(0.0, 0.0), make_double2(0.0, 0.0), y, y, y, y, y);
    }


    /**
       Return the real dot product of x and y
    */
    template<typename ReduceType> __device__ __host__ void dot_(ReduceType &sum, const double2 &a, const double2 &b) {
      sum += (ReduceType)a.x*(ReduceType)b.x;
      sum += (ReduceType)a.y*(ReduceType)b.y;
    }

    template<typename ReduceType> __device__ __host__ void dot_(ReduceType &sum, const float2 &a, const float2 &b) {
      sum += (ReduceType)a.x*(ReduceType)b.x;
      sum += (ReduceType)a.y*(ReduceType)b.y;
    }

    template<typename ReduceType> __device__ __host__ void dot_(ReduceType &sum, const float4 &a, const float4 &b) {
      sum += (ReduceType)a.x*(ReduceType)b.x;
      sum += (ReduceType)a.y*(ReduceType)b.y;
      sum += (ReduceType)a.z*(ReduceType)b.z;
      sum += (ReduceType)a.w*(ReduceType)b.w;
    }

   template <typename ReduceType, typename Float2, typename FloatN>
    struct Dot : public ReduceFunctor<ReduceType, Float2, FloatN> {
      Dot(const Float2 &a, const Float2 &b) { ; }
      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v)
     { dot_<ReduceType>(sum,x,y); }
      static int streams() { return 2; } //! total number of input and output streams
      static int flops() { return 2; } //! flops per element
    };

    double reDotProduct(ColorSpinorField &x, ColorSpinorField &y) {
      return reduce::reduceCuda<double,QudaSumFloat,Dot,0,0,0,0,0,false>
	(make_double2(0.0, 0.0), make_double2(0.0, 0.0), x, y, x, x, x);
    }


    /**
       First performs the operation z[i] = a*x[i] + b*y[i]
       Return the norm of y
    */
    template <typename ReduceType, typename Float2, typename FloatN>
    struct axpbyzNorm2 : public ReduceFunctor<ReduceType, Float2, FloatN> {
      Float2 a;
      Float2 b;
      axpbyzNorm2(const Float2 &a, const Float2 &b) : a(a), b(b) { ; }
      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) {
	z = a.x*x + b.x*y; norm2_<ReduceType>(sum,z); }
      static int streams() { return 3; } //! total number of input and output streams
      static int flops() { return 4; } //! flops per element
    };

    double axpbyzNorm(double a, ColorSpinorField &x, double b, ColorSpinorField &y,
                      ColorSpinorField &z) {
      return reduce::reduceCuda<double,QudaSumFloat,axpbyzNorm2,0,0,1,0,0,false>
	(make_double2(a, 0.0), make_double2(b, 0.0), x, y, z, x, x);
    }


    /**
       First performs the operation y[i] += a*x[i]
       Return real dot product (x,y)
    */
    template <typename ReduceType, typename Float2, typename FloatN>
    struct AxpyReDot : public ReduceFunctor<ReduceType, Float2, FloatN> {
      Float2 a;
      AxpyReDot(const Float2 &a, const Float2 &b) : a(a) { ; }
      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) {
	y += a.x*x; dot_<ReduceType>(sum,x,y); }
      static int streams() { return 3; } //! total number of input and output streams
      static int flops() { return 4; } //! flops per element
    };

    double axpyReDot(double a, ColorSpinorField &x, ColorSpinorField &y) {
      return reduce::reduceCuda<double,QudaSumFloat,AxpyReDot,0,1,0,0,0,false>
	(make_double2(a, 0.0), make_double2(0.0, 0.0), x, y, x, x, x);
    }


    /**
       Functor to perform the operation y += a * x  (complex-valued)
    */
    __device__ __host__ void Caxpy_(const double2 &a, const double2 &x, double2 &y) {
      y.x += a.x*x.x; y.x -= a.y*x.y;
      y.y += a.y*x.x; y.y += a.x*x.y;
    }
    __device__ __host__ void Caxpy_(const float2 &a, const float2 &x, float2 &y) {
      y.x += a.x*x.x; y.x -= a.y*x.y;
      y.y += a.y*x.x; y.y += a.x*x.y;
    }
    __device__ __host__ void Caxpy_(const float2 &a, const float4 &x, float4 &y) {
      y.x += a.x*x.x; y.x -= a.y*x.y;
      y.y += a.y*x.x; y.y += a.x*x.y;
      y.z += a.x*x.z; y.z -= a.y*x.w;
      y.w += a.y*x.z; y.w += a.x*x.w;
    }

    /**
       First performs the operation y[i] = a*x[i] + y[i] (complex-valued)
       Second returns the norm of y
    */
    template <typename ReduceType, typename Float2, typename FloatN>
    struct caxpyNorm2 : public ReduceFunctor<ReduceType, Float2, FloatN> {
      Float2 a;
      caxpyNorm2(const Float2 &a, const Float2 &b) : a(a) { ; }
      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) {
	Caxpy_(a, x, y); norm2_<ReduceType>(sum,y); }
      static int streams() { return 3; } //! total number of input and output streams
      static int flops() { return 6; } //! flops per element
    };

    double caxpyNorm(const Complex &a, ColorSpinorField &x, ColorSpinorField &y) {
      return reduce::reduceCuda<double,QudaSumFloat,caxpyNorm2,0,1,0,0,0,false>
	(make_double2(REAL(a), IMAG(a)), make_double2(0.0, 0.0), x, y, x, x, x);
    }


    /**
       double caxpyXmayNormCuda(float a, float *x, float *y, n){}
       First performs the operation y[i] = a*x[i] + y[i]
       Second performs the operator x[i] -= a*z[i]
       Third returns the norm of x
    */
    template <typename ReduceType, typename Float2, typename FloatN>
    struct caxpyxmaznormx : public ReduceFunctor<ReduceType, Float2, FloatN> {
      Float2 a;
      caxpyxmaznormx(const Float2 &a, const Float2 &b) : a(a) { ; }
      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v)
      { Caxpy_(a, x, y); Caxpy_(-a,z,x); norm2_<ReduceType>(sum,x); }
      static int streams() { return 5; } //! total number of input and output streams
      static int flops() { return 10; } //! flops per element
    };

    double caxpyXmazNormX(const Complex &a, ColorSpinorField &x,
			  ColorSpinorField &y, ColorSpinorField &z) {
      return reduce::reduceCuda<double,QudaSumFloat,caxpyxmaznormx,1,1,0,0,0,false>
	(make_double2(REAL(a), IMAG(a)), make_double2(0.0, 0.0), x, y, z, x, x);
    }


    /**
       double cabxpyzAxNorm(float a, complex b, float *x, float *y, float *z){}
       First performs the operation z[i] = y[i] + a*b*x[i]
       Second performs x[i] *= a
       Third returns the norm of x
    */
    template <typename ReduceType, typename Float2, typename FloatN>
    struct cabxpyzaxnorm : public ReduceFunctor<ReduceType, Float2, FloatN> {
      Float2 a;
      Float2 b;
      cabxpyzaxnorm(const Float2 &a, const Float2 &b) : a(a), b(b) { ; }
      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v)
      { x *= a.x; Caxpy_(b, x, y); z = y; norm2_<ReduceType>(sum,z); }
      static int streams() { return 4; } //! total number of input and output streams
      static int flops() { return 10; } //! flops per element
    };


    double cabxpyzAxNorm(double a, const Complex &b,
			ColorSpinorField &x, ColorSpinorField &y, ColorSpinorField &z) {
      return reduce::reduceCuda<double,QudaSumFloat,cabxpyzaxnorm,1,0,1,0,0,false>
	(make_double2(a, 0.0), make_double2(REAL(b), IMAG(b)), x, y, z, x, x);
    }


    /**
       Returns complex-valued dot product of x and y
    */
    template<typename ReduceType>
    __device__ __host__ void cdot_(ReduceType &sum, const double2 &a, const double2 &b) {
      typedef typename ScalarType<ReduceType>::type scalar;
      sum.x += (scalar)a.x*(scalar)b.x;
      sum.x += (scalar)a.y*(scalar)b.y;
      sum.y += (scalar)a.x*(scalar)b.y;
      sum.y -= (scalar)a.y*(scalar)b.x;
    }

    template<typename ReduceType>
    __device__ __host__ void cdot_(ReduceType &sum, const float2 &a, const float2 &b) {
      typedef typename ScalarType<ReduceType>::type scalar;
      sum.x += (scalar)a.x*(scalar)b.x;
      sum.x += (scalar)a.y*(scalar)b.y;
      sum.y += (scalar)a.x*(scalar)b.y;
      sum.y -= (scalar)a.y*(scalar)b.x;
    }

    template<typename ReduceType>
    __device__ __host__ void cdot_(ReduceType &sum, const float4 &a, const float4 &b) {
      typedef typename ScalarType<ReduceType>::type scalar;
      sum.x += (scalar)a.x*(scalar)b.x;
      sum.x += (scalar)a.y*(scalar)b.y;
      sum.x += (scalar)a.z*(scalar)b.z;
      sum.x += (scalar)a.w*(scalar)b.w;
      sum.y += (scalar)a.x*(scalar)b.y;
      sum.y -= (scalar)a.y*(scalar)b.x;
      sum.y += (scalar)a.z*(scalar)b.w;
      sum.y -= (scalar)a.w*(scalar)b.z;
    }

    template <typename ReduceType, typename Float2, typename FloatN>
    struct Cdot : public ReduceFunctor<ReduceType, Float2, FloatN> {
      Cdot(const Float2 &a, const Float2 &b) { ; }
      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v)
      { cdot_<ReduceType>(sum,x,y); }
      static int streams() { return 2; } //! total number of input and output streams
      static int flops() { return 4; } //! flops per element
    };

    Complex cDotProduct(ColorSpinorField &x, ColorSpinorField &y) {
      double2 cdot = reduce::reduceCuda<double2,QudaSumFloat2,Cdot,0,0,0,0,0,false>
	(make_double2(0.0, 0.0), make_double2(0.0, 0.0), x, y, x, x, x);
      return Complex(cdot.x, cdot.y);
    }


    /**
       double caxpyDotzyCuda(float a, float *x, float *y, float *z, n){}
       First performs the operation y[i] = a*x[i] + y[i]
       Second returns the dot product (z,y)
    */
    template <typename ReduceType, typename Float2, typename FloatN>
    struct caxpydotzy : public ReduceFunctor<ReduceType, Float2, FloatN> {
      Float2 a;
      caxpydotzy(const Float2 &a, const Float2 &b) : a(a) { ; }
      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v)
      { Caxpy_(a, x, y); cdot_<ReduceType>(sum,z,y); }
      static int streams() { return 4; } //! total number of input and output streams
      static int flops() { return 8; } //! flops per element
    };

    Complex caxpyDotzy(const Complex &a, ColorSpinorField &x, ColorSpinorField &y, ColorSpinorField &z) {
      double2 cdot = reduce::reduceCuda<double2,QudaSumFloat2,caxpydotzy,0,1,0,0,0,false>
	(make_double2(REAL(a), IMAG(a)), make_double2(0.0, 0.0), x, y, z, x, x);
      return Complex(cdot.x, cdot.y);
    }


    /**
       First returns the dot product (x,y)
       Returns the norm of x
    */
    template<typename ReduceType, typename InputType>
    __device__ __host__ void cdotNormA_(ReduceType &sum, const InputType &a, const InputType &b) {
      typedef typename ScalarType<ReduceType>::type scalar;
      typedef typename Vec2Type<scalar>::type vec2;
      cdot_<ReduceType>(sum,a,b);
      norm2_<scalar>(sum.z,a);
    }

    /**
       First returns the dot product (x,y)
       Returns the norm of y
    */
    template<typename ReduceType, typename InputType>
    __device__ __host__ void cdotNormB_(ReduceType &sum, const InputType &a, const InputType &b) {
      typedef typename ScalarType<ReduceType>::type scalar;
      typedef typename Vec2Type<scalar>::type vec2;
      cdot_<ReduceType>(sum,a,b);
      norm2_<scalar>(sum.z,b);
    }

    template <typename ReduceType, typename Float2, typename FloatN>
    struct CdotNormA : public ReduceFunctor<ReduceType, Float2, FloatN> {
      CdotNormA(const Float2 &a, const Float2 &b) { ; }
      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v)
      { cdotNormA_<ReduceType>(sum,x,y); }
      static int streams() { return 2; } //! total number of input and output streams
      static int flops() { return 6; } //! flops per element
    };

    double3 cDotProductNormA(ColorSpinorField &x, ColorSpinorField &y) {
      return reduce::reduceCuda<double3,QudaSumFloat3,CdotNormA,0,0,0,0,0,false>
	(make_double2(0.0, 0.0), make_double2(0.0, 0.0), x, y, x, x, x);
    }


    /**
       This convoluted kernel does the following:
       z += a*x + b*y, y -= b*w, norm = (y,y), dot = (u, y)
    */
    template <typename ReduceType, typename Float2, typename FloatN>
    struct caxpbypzYmbwcDotProductUYNormY_ : public ReduceFunctor<ReduceType, Float2, FloatN> {
      Float2 a;
      Float2 b;
      caxpbypzYmbwcDotProductUYNormY_(const Float2 &a, const Float2 &b) : a(a), b(b) { ; }
      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v)
      { Caxpy_(a, x, z); Caxpy_(b, y, z); Caxpy_(-b, w, y); cdotNormB_<ReduceType>(sum,v,y); }
      static int streams() { return 7; } //! total number of input and output streams
      static int flops() { return 18; } //! flops per element
    };

    double3 caxpbypzYmbwcDotProductUYNormY(const Complex &a, ColorSpinorField &x,
					   const Complex &b, ColorSpinorField &y,
					   ColorSpinorField &z, ColorSpinorField &w,
					   ColorSpinorField &u) {
      if (x.Precision() != z.Precision()) {
	return reduce::mixed::reduceCuda<double3,QudaSumFloat3,caxpbypzYmbwcDotProductUYNormY_,0,1,1,0,0,false>
	  (make_double2(REAL(a), IMAG(a)), make_double2(REAL(b), IMAG(b)), x, y, z, w, u);
      } else {
	return reduce::reduceCuda<double3,QudaSumFloat3,caxpbypzYmbwcDotProductUYNormY_,0,1,1,0,0,false>
	  (make_double2(REAL(a), IMAG(a)), make_double2(REAL(b), IMAG(b)), x, y, z, w, u);
      }
    }


    /**
       Specialized kernel for the modified CG norm computation for
       computing beta.  Computes y = y + a*x and returns norm(y) and
       dot(y, delta(y)) where delta(y) is the difference between the
       input and out y vector.
    */
    template <typename ReduceType, typename Float2, typename FloatN>
    struct axpyCGNorm2 : public ReduceFunctor<ReduceType, Float2, FloatN> {
      Float2 a;
      axpyCGNorm2(const Float2 &a, const Float2 &b) : a(a) { ; }
      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) {
	typedef typename ScalarType<ReduceType>::type scalar;
	FloatN z_new = z + a.x*x;
	norm2_<scalar>(sum.x,z_new);
	dot_<scalar>(sum.y,z_new,z_new-z);
	z = z_new;
      }
      static int streams() { return 3; } //! total number of input and output streams
      static int flops() { return 6; } //! flops per real element
    };

    Complex axpyCGNorm(double a, ColorSpinorField &x, ColorSpinorField &y) {
      // swizzle since mixed is on z
      double2 cg_norm ;
      if (x.Precision() != y.Precision()) {
	cg_norm = reduce::mixed::reduceCuda<double2,QudaSumFloat2,axpyCGNorm2,0,0,1,0,0,false>
	  (make_double2(a, 0.0), make_double2(0.0, 0.0), x, x, y, x, x);
      } else {
	cg_norm = reduce::reduceCuda<double2,QudaSumFloat2,axpyCGNorm2,0,0,1,0,0,false>
	  (make_double2(a, 0.0), make_double2(0.0, 0.0), x, x, y, x, x);
      }
      return Complex(cg_norm.x, cg_norm.y);
    }


    /**
       This kernel returns (x, x) and (r,r) and also returns the so-called
       heavy quark norm as used by MILC: 1 / N * \sum_i (r, r)_i / (x, x)_i, where
       i is site index and N is the number of sites.
       When this kernel is launched, we must enforce that the parameter M
       in the launcher corresponds to the number of FloatN fields used to
       represent the spinor, e.g., M=6 for Wilson and M=3 for staggered.
       This is only the case for half-precision kernels by default.  To
       enable this, the siteUnroll template parameter must be set true
       when reduceCuda is instantiated.
    */
    template <typename ReduceType, typename Float2, typename FloatN>
    struct HeavyQuarkResidualNorm_ : public ReduceFunctor<ReduceType, Float2, FloatN> {
      typedef typename scalar<ReduceType>::type real;
      Float2 a;
      Float2 b;
      ReduceType aux;
      HeavyQuarkResidualNorm_(const Float2 &a, const Float2 &b) : a(a), b(b), aux{ } { ; }

      __device__ __host__ void pre() { aux.x = 0; aux.y = 0; }

      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) {
	norm2_<real>(aux.x,x); norm2_<real>(aux.y,y);
      }

      //! sum the solution and residual norms, and compute the heavy-quark norm
      __device__ __host__ void post(ReduceType &sum)
      {
	sum.x += aux.x; sum.y += aux.y; sum.z += (aux.x > 0.0) ? (aux.y / aux.x) : static_cast<real>(1.0);
      }

      static int streams() { return 2; } //! total number of input and output streams
      static int flops() { return 4; } //! undercounts since it excludes the per-site division
    };

    double3 HeavyQuarkResidualNorm(ColorSpinorField &x, ColorSpinorField &r) {
      // in case of x.Ncolor()!=3 (MG mainly) reduce_core do not support this function.
      if (x.Ncolor()!=3) return make_double3(0.0, 0.0, 0.0);
      double3 rtn = reduce::reduceCuda<double3,QudaSumFloat3,HeavyQuarkResidualNorm_,0,0,0,0,0,true>
	(make_double2(0.0, 0.0), make_double2(0.0, 0.0), x, r, r, r, r);
      rtn.z /= (x.Volume()*comm_size());
      return rtn;
    }


    /**
      Variant of the HeavyQuarkResidualNorm kernel: this takes three
      arguments, the first two are summed together to form the
      solution, with the third being the residual vector.  This removes
      the need an additional xpy call in the solvers, impriving
      performance.
    */
    template <typename ReduceType, typename Float2, typename FloatN>
    struct xpyHeavyQuarkResidualNorm_ : public ReduceFunctor<ReduceType, Float2, FloatN> {
	typedef typename scalar<ReduceType>::type real;
      Float2 a;
      Float2 b;
      ReduceType aux;
      xpyHeavyQuarkResidualNorm_(const Float2 &a, const Float2 &b) : a(a), b(b), aux{ } { ; }

      __device__ __host__ void pre() { aux.x = 0; aux.y = 0; }

      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) {
	norm2_<real>(aux.x,x + y); norm2_<real>(aux.y,z);
      }

      //! sum the solution and residual norms, and compute the heavy-quark norm
      __device__ __host__ void post(ReduceType &sum)
      {
	sum.x += aux.x; sum.y += aux.y; sum.z += (aux.x > 0.0) ? (aux.y / aux.x) : static_cast<real>(1.0);
      }

      static int streams() { return 3; } //! total number of input and output streams
      static int flops() { return 5; }
    };

    double3 xpyHeavyQuarkResidualNorm(ColorSpinorField &x, ColorSpinorField &y,
				      ColorSpinorField &r) {
      // in case of x.Ncolor()!=3 (MG mainly) reduce_core do not support this function.
      if (x.Ncolor()!=3) return make_double3(0.0, 0.0, 0.0);
      double3 rtn = reduce::reduceCuda<double3,QudaSumFloat3,xpyHeavyQuarkResidualNorm_,0,0,0,0,0,true>
	(make_double2(0.0, 0.0), make_double2(0.0, 0.0), x, y, r, r, r);
      rtn.z /= (x.Volume()*comm_size());
      return rtn;
    }

    /**
       double3 tripleCGReduction(V x, V y, V z){}
       First performs the operation norm2(x)
       Second performs the operatio norm2(y)
       Third performs the operation dotPropduct(y,z)
    */
    template <typename ReduceType, typename Float2, typename FloatN>
    struct tripleCGReduction_ : public ReduceFunctor<ReduceType, Float2, FloatN> {
      tripleCGReduction_(const Float2 &a, const Float2 &b) { ; }
      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) {
	typedef typename ScalarType<ReduceType>::type scalar;
	norm2_<scalar>(sum.x,x); norm2_<scalar>(sum.y,y); dot_<scalar>(sum.z,y,z);
      }
      static int streams() { return 3; } //! total number of input and output streams
      static int flops() { return 6; } //! flops per element
    };

    double3 tripleCGReduction(ColorSpinorField &x, ColorSpinorField &y, ColorSpinorField &z) {
      return reduce::reduceCuda<double3,QudaSumFloat3,tripleCGReduction_,0,0,0,0,0,false>
	(make_double2(0.0, 0.0), make_double2(0.0, 0.0), x, y, z, x, x);
    }

    /**
       double4 quadrupleCGReduction(V x, V y, V z){}
       First performs the operation norm2(x)
       Second performs the operatio norm2(y)
       Third performs the operation dotPropduct(y,z)
       Fourth performs the operation norm(z)
    */
    template <typename ReduceType, typename Float2, typename FloatN>
    struct quadrupleCGReduction_ : public ReduceFunctor<ReduceType, Float2, FloatN> {
      quadrupleCGReduction_(const Float2 &a, const Float2 &b) { ; }
      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) {
        typedef typename ScalarType<ReduceType>::type scalar;
        norm2_<scalar>(sum.x,x); norm2_<scalar>(sum.y,y); dot_<scalar>(sum.z,y,z); norm2_<scalar>(sum.w,w);
      }
      static int streams() { return 3; } //! total number of input and output streams
      static int flops() { return 8; } //! flops per element
    };

    double4 quadrupleCGReduction(ColorSpinorField &x, ColorSpinorField &y, ColorSpinorField &z) {
      return reduce::reduceCuda<double4,QudaSumFloat4,quadrupleCGReduction_,0,0,0,0,0,false>
        (make_double2(0.0, 0.0), make_double2(0.0, 0.0), x, y, z, x, x);
    }

    /**
       double quadrupleCG3InitNorm(d a, d b, V x, V y, V z, V w, V v){}
        z = x;
        w = y;
        x += a*y;
        y -= a*v;
        norm2(y);
    */
    template <typename ReduceType, typename Float2, typename FloatN>
    struct quadrupleCG3InitNorm_ : public ReduceFunctor<ReduceType, Float2, FloatN> {
      Float2 a;
      quadrupleCG3InitNorm_(const Float2 &a, const Float2 &b) : a(a) { ; }
      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) {
        z = x;
        w = y;
        x += a.x*y;
        y -= a.x*v;
        norm2_<ReduceType>(sum,y);
      }
      static int streams() { return 6; } //! total number of input and output streams
      static int flops() { return 6; } //! flops per element check if it's right
    };

    double quadrupleCG3InitNorm(double a, ColorSpinorField &x, ColorSpinorField &y, ColorSpinorField &z, ColorSpinorField &w, ColorSpinorField &v) {
      return reduce::reduceCuda<double,QudaSumFloat,quadrupleCG3InitNorm_,1,1,1,1,0,false>
	(make_double2(a, 0.0), make_double2(0.0, 0.0), x, y, z, w, v);
    }


    /**
       double quadrupleCG3UpdateNorm(d gamma, d rho, V x, V y, V z, V w, V v){}
        tmpx = x;
        tmpy = y;
        x = b*(x + a*y) + (1-b)*z;
        y = b*(y + a*v) + (1-b)*w;
        z = tmpx;
        w = tmpy;
        norm2(y);
    */
    template <typename ReduceType, typename Float2, typename FloatN>
    struct quadrupleCG3UpdateNorm_ : public ReduceFunctor<ReduceType, Float2, FloatN> {
      Float2 a,b;
      quadrupleCG3UpdateNorm_(const Float2 &a, const Float2 &b) : a(a), b(b) { ; }
      FloatN tmpx{}, tmpy{};
      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) {
        tmpx = x;
        tmpy = y;
        x = b.x*(x + a.x*y) + b.y*z;
        y = b.x*(y - a.x*v) + b.y*w;
        z = tmpx;
        w = tmpy;
        norm2_<ReduceType>(sum,y);
      }
      static int streams() { return 7; } //! total number of input and output streams
      static int flops() { return 16; } //! flops per element check if it's right
    };

    double quadrupleCG3UpdateNorm(double a, double b, ColorSpinorField &x, ColorSpinorField &y, ColorSpinorField &z, ColorSpinorField &w, ColorSpinorField &v) {
      return reduce::reduceCuda<double,QudaSumFloat,quadrupleCG3UpdateNorm_,1,1,1,1,0,false>
	(make_double2(a, 0.0), make_double2(b, 1.-b), x, y, z, w, v);
    }

    /**
       void doubleCG3InitNorm(d a, V x, V y, V z){}
        y = x;
        x -= a*z;
        norm2(x);
    */
    template <typename ReduceType, typename Float2, typename FloatN>
    struct doubleCG3InitNorm_ : public ReduceFunctor<ReduceType, Float2, FloatN> {
      Float2 a;
      doubleCG3InitNorm_(const Float2 &a, const Float2 &b) : a(a) { ; }
      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) {
        y = x;
        x -= a.x*z;
        norm2_<ReduceType>(sum,x);
      }
      static int streams() { return 3; } //! total number of input and output streams
      static int flops() { return 5; } //! flops per element
    };

    double doubleCG3InitNorm(double a, ColorSpinorField &x, ColorSpinorField &y, ColorSpinorField &z) {
      return reduce::reduceCuda<double,QudaSumFloat,doubleCG3InitNorm_,1,1,0,0,0,false>
        (make_double2(a, 0.0), make_double2(0.0, 0.0), x, y, z, z, z);
    }

    /**
       void doubleCG3UpdateNorm(d a, d b, V x, V y, V z){}
        tmp = x;
        x = b*(x-a*z) + (1-b)*y;
        y = tmp;
        norm2(x);
    */
    template <typename ReduceType, typename Float2, typename FloatN>
    struct doubleCG3UpdateNorm_ : public ReduceFunctor<ReduceType, Float2, FloatN> {
      Float2 a, b;
      doubleCG3UpdateNorm_(const Float2 &a, const Float2 &b) : a(a), b(b) { ; }
      FloatN tmp{};
      __device__ __host__ void operator()(ReduceType &sum,FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) { 
        tmp = x;
        x = b.x*(x-a.x*z) + b.y*y;
        y = tmp;
        norm2_<ReduceType>(sum,x);
      }
      static int streams() { return 4; } //! total number of input and output streams
      static int flops() { return 9; } //! flops per element
    };

    double doubleCG3UpdateNorm(double a, double b, ColorSpinorField &x, ColorSpinorField &y, ColorSpinorField &z) {
      return reduce::reduceCuda<double,QudaSumFloat,doubleCG3UpdateNorm_,1,1,0,0,0,false>
        (make_double2(a, 0.0), make_double2(b, 1.0-b), x, y, z, z, z);
    }

   } // namespace blas

} // namespace quda
