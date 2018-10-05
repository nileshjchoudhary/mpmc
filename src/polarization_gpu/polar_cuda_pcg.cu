/*

@2018, Adam Hogan
@2010, Jonathan Belof
University of South Florida

*/

#include <cuda_runtime.h>
#include "cublas_v2.h"

#define MAXFVALUE	1.0e14f

__constant__ float basis[9];
__constant__ float recip_basis[9];

__global__ void precondition_z(int N, float *A, float *r, float *z)
{
    int i = blockIdx.x;
    if (i<N) z[i] = 1.0/A[N*i+i]*r[i];
    return;
}

__global__ void build_a(int N, float *A, float damp, float4 *pos, float *pols, int *ids)
{
    int i = blockIdx.x;

    if (i>=N) return;

    float r, r2, r3, r5;
    float damp2, damp3, expr, damping_term1, damping_term2;
    float4 dr, dri, img;

    int j;
    for(j=0;j<N;j++)
    {
        if (i==j)
        {
            // diagonal bit
            if (pols[i]!=0.0)
            {
                A[9*N*j+3*i] = 1.0/pols[i];
                A[9*N*j+3*i+3*N+1] = 1.0/pols[i];
                A[9*N*j+3*i+6*N+2] = 1.0/pols[i];
            }
            else
            {
                A[9*N*j+3*i] = MAXFVALUE;
                A[9*N*j+3*i+3*N+1] = MAXFVALUE;
                A[9*N*j+3*i+6*N+2] = MAXFVALUE;
            }
            A[9*N*j+3*i+1] = 0.0;
            A[9*N*j+3*i+2] = 0.0;
            A[9*N*j+3*i+3*N] = 0.0;
            A[9*N*j+3*i+3*N+2] = 0.0;
            A[9*N*j+3*i+6*N] = 0.0;
            A[9*N*j+3*i+6*N+1] = 0.0;
        }
        else
        {
            if (ids[i]==ids[j]) 
            {
                A[9*N*j+3*i] = 0.0;
                A[9*N*j+3*i+1] = 0.0;
                A[9*N*j+3*i+2] = 0.0;
                A[9*N*j+3*i+3*N] = 0.0;
                A[9*N*j+3*i+3*N+1] = 0.0;
                A[9*N*j+3*i+3*N+2] = 0.0;
                A[9*N*j+3*i+6*N] = 0.0;
                A[9*N*j+3*i+6*N+1] = 0.0;
                A[9*N*j+3*i+6*N+2] = 0.0;
                continue;
            }

            // START MINIMUM IMAGE
            // get the particle displacement
            dr.x = pos[i].x - pos[j].x;
            dr.y = pos[i].y - pos[j].y;
            dr.z = pos[i].z - pos[j].z;

            // matrix multiply with the inverse basis and round
            img.x = recip_basis[0]*dr.x + recip_basis[1]*dr.y + recip_basis[2]*dr.z;
            img.y = recip_basis[3]*dr.x + recip_basis[4]*dr.y + recip_basis[5]*dr.z;
            img.z = recip_basis[6]*dr.x + recip_basis[7]*dr.y + recip_basis[8]*dr.z;
            img.x = rintf(img.x);
            img.y = rintf(img.y);
            img.z = rintf(img.z);

            // matrix multiply to project back into our basis
            dri.x = basis[0]*img.x + basis[1]*img.y + basis[2]*img.z;
            dri.y = basis[3]*img.x + basis[4]*img.y + basis[5]*img.z;
            dri.z = basis[6]*img.x + basis[7]*img.y + basis[8]*img.z;

            // now correct the displacement
            dri.x = dr.x - dri.x;
            dri.y = dr.y - dri.y;
            dri.z = dr.z - dri.z;
            r2 = dri.x*dri.x + dri.y*dri.y + dri.z*dri.z;

            // various powers of r that we need
            r = sqrtf(r2);
            r3 = r2*r;
            r5 = r3*r2;
            r3 = 1.0f/r3;
            r5 = 1.0f/r5;
            // END MINIMUM IMAGE

            // damping terms
            damp2 = damp*damp;
            damp3 = damp2*damp;
            expr =  __expf(-damp*r);
            damping_term1 = 1.0f - expr*(0.5f*damp2*r2 + damp*r + 1.0f);
            damping_term2 = 1.0f - expr*(damp3*r*r2/6.0f + 0.5f*damp2*r2 + damp*r + 1.0f);

            // construct the Tij tensor field, unrolled by hand to avoid conditional on the diagonal terms
            damping_term1 *= r3;
            damping_term2 *= -3.0f*r5;

            // exploit symmetry
            A[9*N*j+3*i] = dri.x*dri.x*damping_term2 + damping_term1;
            A[9*N*j+3*i+1] = dri.x*dri.y*damping_term2;
            A[9*N*j+3*i+2] = dri.x*dri.z*damping_term2;
            A[9*N*j+3*i+3*N] = A[9*N*j+3*i+1];
            A[9*N*j+3*i+3*N+1] = dri.y*dri.y*damping_term2 + damping_term1;
            A[9*N*j+3*i+3*N+2] = dri.y*dri.z*damping_term2;
            A[9*N*j+3*i+6*N] = A[9*N*j+3*i+2];
            A[9*N*j+3*i+6*N+1] = A[9*N*j+3*i+3*N+2];
            A[9*N*j+3*i+6*N+2] = dri.z*dri.z*damping_term2 + damping_term1;
        }
    }
    return;
}

extern "C" {

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <structs.h>

void thole_field(system_t*);

int getSPcores(cudaDeviceProp devProp)
{  
    int cores = 0;
    int mp = devProp.multiProcessorCount;
    switch (devProp.major){
        case 2: // Fermi
            if (devProp.minor == 1) cores = mp * 48;
            else cores = mp * 32;
            break;
        case 3: // Kepler
            cores = mp * 192;
        break;
        case 5: // Maxwell
            cores = mp * 128;
            break;
        case 6: // Pascal
            if (devProp.minor == 1) cores = mp * 128;
            else if (devProp.minor == 0) cores = mp * 64;
            else printf("Unknown device type\n");
            break;
        case 7: // Volta
            if (devProp.minor == 0) cores = mp * 64;
            else printf("Unknown device type\n");
            break;
        default:
            printf("Unknown device type\n"); 
            break;
    }
    return cores;
}

static const char * cublasGetErrorEnum(cublasStatus_t error)
{
    switch (error)
    {
        case CUBLAS_STATUS_SUCCESS:
            return "CUBLAS_STATUS_SUCCESS";

        case CUBLAS_STATUS_NOT_INITIALIZED:
            return "CUBLAS_STATUS_NOT_INITIALIZED";

        case CUBLAS_STATUS_ALLOC_FAILED:
            return "CUBLAS_STATUS_ALLOC_FAILED";

        case CUBLAS_STATUS_INVALID_VALUE:
            return "CUBLAS_STATUS_INVALID_VALUE";

        case CUBLAS_STATUS_ARCH_MISMATCH:
            return "CUBLAS_STATUS_ARCH_MISMATCH";

        case CUBLAS_STATUS_MAPPING_ERROR:
            return "CUBLAS_STATUS_MAPPING_ERROR";

        case CUBLAS_STATUS_EXECUTION_FAILED:
            return "CUBLAS_STATUS_EXECUTION_FAILED";

        case CUBLAS_STATUS_INTERNAL_ERROR:
            return "CUBLAS_STATUS_INTERNAL_ERROR";

        case CUBLAS_STATUS_NOT_SUPPORTED:
            return "CUBLAS_STATUS_NOT_SUPPORTED";

        case CUBLAS_STATUS_LICENSE_ERROR:
            return "CUBLAS_STATUS_LICENSE_ERROR";
    }

    return "<unknown>";
}

void cudaErrorHandler(cudaError_t error, int line)
{
    if (error != cudaSuccess)
    {
        printf("POLAR_CUDA: GPU is reporting an error: %s %s:%d\n", cudaGetErrorString(error),__FILE__,line);
    }
}

void cublasErrorHandler(cublasStatus_t error, int line)
{
    if (error != CUBLAS_STATUS_SUCCESS)
    {
        printf("POLAR_CUDA: CUBLAS is reporting an error: %s %s:%d\n", cublasGetErrorEnum(error),__FILE__,line);
    }
}

float polar_cuda(system_t *system)
{
    molecule_t *molecule_ptr;
    atom_t *atom_ptr;
    int i,j,iterations;
    float potential = 0.0;
    float alpha, beta, result;
    int N = system->natoms;
    float *host_x, *host_b, *host_basis, *host_recip_basis, *host_pols; // host vectors
    float4 *host_pos;
    int *host_ids;
    float *A; // GPU matrix
    float *x, *r, *z, *p, *tmp, *r_prev, *z_prev, *pols; // GPU vectors
    float4 *pos;
    int *ids;
    const float one = 1.0; // these are for some CUBLAS calls
    const float zero = 0.0;
    const float neg_one = -1.0;

    cudaError_t error; // GetDevice and cudaMalloc errors
    cudaDeviceProp prop; // GetDevice properties
    cublasHandle_t handle; // CUBLAS handle
    error = cudaGetDeviceProperties(&prop, 0);
    if(error != cudaSuccess)
    {
        cudaErrorHandler(error,__LINE__);
        return(-1);
    }
    else
    {
        printf("POLAR_CUDA: Found %s with id %d, %d MB and %d cuda cores\n", prop.name, prop.pciBusID, (int)prop.totalGlobalMem/1000000, getSPcores(prop));
    }

    cublasErrorHandler(cublasCreate(&handle),__LINE__); // initialize CUBLAS context

    host_b = (float*)calloc(3*N, sizeof(float)); // allocate all our arrays
    host_x = (float*)calloc(3*N, sizeof(float));
    host_basis = (float*)calloc(9, sizeof(float));
    host_recip_basis = (float*)calloc(9, sizeof(float));
    host_pos = (float4*)calloc(N, sizeof(float4));
    host_pols = (float*)calloc(N, sizeof(float));
    host_ids = (int*)calloc(N, sizeof(int));

    cudaErrorHandler(cudaMalloc((void**)&x, 3*N*sizeof(float)),__LINE__);
    cudaErrorHandler(cudaMalloc((void**)&A, 3*N*3*N*sizeof(float)),__LINE__);
    cudaErrorHandler(cudaMalloc((void**)&r, 3*N*sizeof(float)),__LINE__);
    cudaErrorHandler(cudaMalloc((void**)&z, 3*N*sizeof(float)),__LINE__);
    cudaErrorHandler(cudaMalloc((void**)&p, 3*N*sizeof(float)),__LINE__);
    cudaErrorHandler(cudaMalloc((void**)&tmp, 3*N*sizeof(float)),__LINE__);
    cudaErrorHandler(cudaMalloc((void**)&r_prev, 3*N*sizeof(float)),__LINE__);
    cudaErrorHandler(cudaMalloc((void**)&z_prev, 3*N*sizeof(float)),__LINE__);
    cudaErrorHandler(cudaMalloc((void**)&pos, N*sizeof(float4)),__LINE__);
    cudaErrorHandler(cudaMalloc((void**)&basis, 9*sizeof(float)),__LINE__);
    cudaErrorHandler(cudaMalloc((void**)&recip_basis, 9*sizeof(float)),__LINE__);
    cudaErrorHandler(cudaMalloc((void**)&pols, N*sizeof(float)),__LINE__);
    cudaErrorHandler(cudaMalloc((void**)&ids, N*sizeof(int)),__LINE__);

    // copy over the basis matrix
    for(i = 0; i<3; i++)
    {
        for(j = 0; j<3; j++)
        {
            host_basis[i*3+j] = (float)system->pbc->basis[i][j];
            host_recip_basis[i*3+j] = (float)system->pbc->reciprocal_basis[i][j];
        }
    }

    cudaErrorHandler(cudaMemcpyToSymbol(basis, host_basis, 9*sizeof(float), 0, cudaMemcpyHostToDevice),__LINE__);
    cudaErrorHandler(cudaMemcpyToSymbol(recip_basis, host_recip_basis, 9*sizeof(float), 0, cudaMemcpyHostToDevice),__LINE__);

    thole_field(system); // calc static e-field

    for(molecule_ptr = system->molecules, i = 0; molecule_ptr; molecule_ptr = molecule_ptr->next)
    {
        for(atom_ptr = molecule_ptr->atoms; atom_ptr; atom_ptr = atom_ptr->next, i++)
        {
            host_pos[i].x = (float)atom_ptr->pos[0];
            host_pos[i].y = (float)atom_ptr->pos[1];
            host_pos[i].z = (float)atom_ptr->pos[2];
            host_pols[i] = (float)atom_ptr->polarizability;
            host_ids[i] = molecule_ptr->id;
            for (j=0; j<3; j++)
            {
                host_b[3*i+j] = (float)(atom_ptr->ef_static[j]+atom_ptr->ef_static_self[j]);
                host_x[3*i+j] = (float)system->polar_gamma*atom_ptr->polarizability*host_b[3*i+j];
            }
        }
    }

    cudaErrorHandler(cudaMemcpy(pos, host_pos, N*sizeof(float4), cudaMemcpyHostToDevice),__LINE__); // copy over pos (to pos), b (to r), x (to x) and pols (to pols)
    cudaErrorHandler(cudaMemcpy(r, host_b, 3*N*sizeof(float), cudaMemcpyHostToDevice),__LINE__);
    cudaErrorHandler(cudaMemcpy(x, host_x, 3*N*sizeof(float), cudaMemcpyHostToDevice),__LINE__);
    cudaErrorHandler(cudaMemcpy(pols, host_pols, N*sizeof(float), cudaMemcpyHostToDevice),__LINE__);
    cudaErrorHandler(cudaMemcpy(ids, host_ids, N*sizeof(int), cudaMemcpyHostToDevice),__LINE__);

    // make A matrix on GPU
    build_a<<<N,1>>>(N, A, system->polar_damp, pos, pols, ids);
    cudaErrorHandler(cudaGetLastError(),__LINE__-1);

    // R = B - A*X0
    // note r is initially set to b a couple lines above
    cublasErrorHandler(cublasSgemv(handle, CUBLAS_OP_N, 3*N, 3*N, &neg_one, A, 3*N, x, 1, &one, r, 1),__LINE__);

    // Z = M^-1*R
    precondition_z<<<3*N,1>>>(3*N, A, r, z);
    cudaErrorHandler(cudaGetLastError(),__LINE__-1);

    // P = Z
    cublasErrorHandler(cublasScopy(handle, 3*N, z, 1, p, 1),__LINE__);

    for(iterations=0;iterations<system->polar_max_iter;iterations++)
    {
        // alpha = R^tZ/P^tAP
        cublasErrorHandler(cublasSdot(handle,3*N,r,1,z,1,&alpha),__LINE__);
        cublasErrorHandler(cublasSgemv(handle, CUBLAS_OP_N, 3*N, 3*N, &one, A, 3*N, p, 1, &zero, tmp, 1),__LINE__);
        cublasErrorHandler(cublasSdot(handle,3*N,p,1,tmp,1,&result),__LINE__);
        alpha /= result;

        //printf("%f %f\n",alpha,result);

        // X = X + alpha*P
        cublasErrorHandler(cublasSaxpy(handle,3*N,&alpha,p,1,x,1),__LINE__);

        // save old R, Z
        cublasErrorHandler(cublasScopy(handle,3*N,r,1,r_prev,1),__LINE__);
        cublasErrorHandler(cublasScopy(handle,3*N,z,1,z_prev,1),__LINE__);

        // R = R - alpha*AP
        alpha *= -1;
        cublasErrorHandler(cublasSaxpy(handle,3*N,&alpha,tmp,1,r,1),__LINE__);

        // Z = M^-1*R
        precondition_z<<<3*N,1>>>(3*N, A, r, z);
        cudaErrorHandler(cudaGetLastError(),__LINE__-1);

        // beta = Z^tR/Z_prev^tR_prev
        cublasErrorHandler(cublasSdot(handle,3*N,z,1,r,1,&beta),__LINE__);
        cublasErrorHandler(cublasSdot(handle,3*N,z_prev,1,r_prev,1,&result),__LINE__);
        beta /= result;

        printf("%f %f\n",alpha,beta);

        // P = Z + beta*P
        cublasErrorHandler(cublasScopy(handle,3*N,z,1,tmp,1),__LINE__);
        cublasErrorHandler(cublasSaxpy(handle,3*N,&beta,p,1,tmp,1),__LINE__);
        cublasErrorHandler(cublasScopy(handle,3*N,tmp,1,p,1),__LINE__);
    }

    cudaErrorHandler(cudaMemcpy(host_x, x, 3*N*sizeof(float), cudaMemcpyDeviceToHost),__LINE__);

    // debug
    
    /*float *test_A;
    int *test_vec;
    test_A = (float*)calloc(3*N*3*N, sizeof(float));
    test_vec = (int*)calloc(N, sizeof(int));
    cudaErrorHandler(cudaMemcpy(test_A, A, 3*N*3*N*sizeof(float), cudaMemcpyDeviceToHost),__LINE__);
    cudaErrorHandler(cudaMemcpy(test_vec, ids, N*sizeof(int), cudaMemcpyDeviceToHost),__LINE__);

    for (i=0;i<N;i++)
    {
        printf("%d ",host_ids[i]);
    }
    printf("\n");*/

    /*for (i=0;i<3*N;i++)
    {
        for (j=0;j<3*N;j++)
        {
            printf("%f ",test_A[3*N*i+j]);
        }
        printf("\n");
    }*/
    
    // end debug

    for(molecule_ptr = system->molecules, i = 0; molecule_ptr; molecule_ptr = molecule_ptr->next)
    {
        for(atom_ptr = molecule_ptr->atoms; atom_ptr; atom_ptr = atom_ptr->next, i++)
        {

            atom_ptr->mu[0] = (double)host_x[3*i];
            atom_ptr->mu[1] = (double)host_x[3*i+1];
            atom_ptr->mu[2] = (double)host_x[3*i+2];

            potential += atom_ptr->mu[0]*atom_ptr->ef_static[0];
            potential += atom_ptr->mu[1]*atom_ptr->ef_static[1];
            potential += atom_ptr->mu[2]*atom_ptr->ef_static[2];
        }
    }

    potential *= -0.5;

    free(host_x);
    free(host_b);
    free(host_basis);
    free(host_recip_basis);
    free(host_pos);
    free(host_pols);
    free(host_ids);
    cudaFree(x);
    cudaFree(A);
    cudaFree(r);
    cudaFree(z);
    cudaFree(p);
    cudaFree(tmp);
    cudaFree(r_prev);
    cudaFree(z_prev);
    cudaFree(pos);
    cudaFree(basis);
    cudaFree(recip_basis);
    cudaFree(pols);
    cudaFree(ids);
    cublasDestroy(handle);

    return potential;
}

}

