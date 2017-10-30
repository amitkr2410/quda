#ifndef INTERFACE_QLUA_H__
#define INTERFACE_QLUA_H__

#ifdef __cplusplus

#define EXTRN_C extern "C"

#define delete_not_null(p) do { if (NULL != (p)) delete (p) ; } while(0)

#else /*!defined(__cplusplus)*/
#define EXTRN_C
#endif/*__cplusplus*/

#define QUDA_Nc 3
#define QUDA_Ns 4
#define QUDA_DIM 4
#define QUDA_MAX_RANK 6

typedef long long LONG_T;
typedef double QUDA_REAL;

typedef struct {
  int node;
  int rank;
  int net[QUDA_MAX_RANK];
  int net_coord[QUDA_MAX_RANK];
  /* local volume : lo[mu] <= x[mu] < hi[mu] */
  int site_coord_lo[QUDA_MAX_RANK];
  int site_coord_hi[QUDA_MAX_RANK];
  LONG_T locvol;
  LONG_T *ind_qdp2quda;
} qudaLattice;

EXTRN_C int
laplacianQuda(
	      QUDA_REAL *quda_v_out,
	      QUDA_REAL *quda_v_in,
	      QUDA_REAL *quda_u[],
	      const qudaLattice *qS,
	      int nColor, int nSpin,
	      QUDA_REAL *alpha, QUDA_REAL beta, int Nstep);


#endif/*INTERFACE_QLUA_H__*/


