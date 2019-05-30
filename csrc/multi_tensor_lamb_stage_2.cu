#include <ATen/ATen.h>
#include <ATen/AccumulateType.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/cuda/Exceptions.h>
// Another possibility:
// #include <torch/all.h>

#include <assert.h>

#include "type_shim.h"
#include "multi_tensor_apply.cuh"

#define BLOCK_SIZE 512
#define ILP 4

// Step 2 reads in 'update' value and per-tensor grad_norm and update_norm.
// It computes new parameter value.
template<T>
struct LAMBStage2Functor
{
   __device__ __forceinline__ void operator()(
    int chunk_size,
    volatile int* noop_gmem,
    TensorListMetadata<2>& tl,
    const float* per_tensor_grad_norm,
    const float* per_tensor_update_norm,
    const float step_size)
  {
    // I'd like this kernel to propagate infs/nans.
    // if(*noop_gmem == 1)
    //   return;

    int tensor_loc = tl.block_to_tensor[blockIdx.x];
    int tensor_num = tl.start_tensor_this_launch + tensor_loc;
    int chunk_idx = tl.block_to_chunk[blockIdx.x];
    int n = tl.sizes[tensor_loc];

    float grad_norm = per_tensor_grad_norm[tensor_num];
    float update_norm = per_tensor_decay[tensor_num];
    T ratio = step_size * (grad_norm / update_norm);

    T* p = (T*)tl.addresses[0][tensor_loc];
    p += chunk_idx*chunk_size;

    T* update = (T*)tl.addresses[1][tensor_loc];
    update += chunk_idx*chunk_size;

    n -= chunk_idx*chunk_size;

    // see note in multi_tensor_scale_kernel.cu
#pragma unroll
    for(int ii = 0; ii < ILP; ii++)
    {
      int i = i_start + threadIdx.x + ii*blockDim.x;
      if(i < n && i < chunk_size)
      {
        p[i] = p[i] - (ratio*update[i]);
      }
    }
  }
};

void multi_tensor_lamb_stage2_cuda(
  int chunk_size,
  at::Tensor noop_flag,
  std::vector<std::vector<at::Tensor>> tensor_lists,
  at::Tensor per_tensor_grad_norm,
  at::Tensor per_tensor_update_norm,
  const float step_size)
{
  using namespace at;

  AT_DISPATCH_FLOATING_TYPES(tensor_lists[0][0].scalar_type(), "lamb_stage_2", [&] {
      multi_tensor_apply<2>(
        BLOCK_SIZE,
        chunk_size,
        noop_flag,
        tensor_lists,
        LAMBStage2Functor<scalar_t_0>(),
        per_tensor_grad_norm.data<float>(),
        per_tensor_decay.data<float>(),
        step_size); )

  AT_CUDA_CHECK(cudaGetLastError());

  // AT_CUDA_CHECK(cudaDeviceSynchronize());
}