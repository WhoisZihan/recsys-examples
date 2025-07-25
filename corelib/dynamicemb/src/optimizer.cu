/******************************************************************************
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
******************************************************************************/

#include "check.h"
#include "optimizer.h"
#include "optimizer_kernel.cuh"
#include "torch_utils.h"
#include "utils.h"

void find_pointers(
  std::shared_ptr<dyn_emb::DynamicVariableBase> table,
  const size_t n,
  const at::Tensor keys,
  at::Tensor values,
  at::Tensor founds);

void find_or_insert_pointers(
  std::shared_ptr<dyn_emb::DynamicVariableBase> table,
  const size_t n,
  const at::Tensor keys,
  at::Tensor values,
  at::Tensor founds,
  const std::optional<uint64_t> score = std::nullopt,
  bool unique_key = true,
  bool ignore_evict_strategy = false);

namespace dyn_emb {

constexpr int MULTIPLIER = 4;
constexpr int WARPSIZE = 32;
constexpr int OPTIMIZER_BLOCKSIZE_VEC = 64;
constexpr int OPTIMIZER_BLOCKSIZE = 1024;

void dynamic_emb_sgd_with_table(
    std::shared_ptr<dyn_emb::DynamicVariableBase> table, const uint64_t n, 
    const at::Tensor indices, const at::Tensor grads, const float lr, DataType weight_type, 
    const std::optional<uint64_t> score, const c10::optional<at::Tensor>& embs) {

  if (n == 0) return;
  TORCH_CHECK(indices.is_cuda(), "indices must be a CUDA tensor");
  TORCH_CHECK(grads.is_cuda(), "grads must be a CUDA tensor");

  at::Tensor founds = at::empty({static_cast<int64_t>(n)}, 
                                at::TensorOptions().dtype(at::kBool).device(indices.device()));
  at::Tensor weight_ptrs = at::empty({static_cast<int64_t>(n)}, 
                                     at::TensorOptions().dtype(at::kLong).device(indices.device()));

  auto stream = at::cuda::getCurrentCUDAStream().stream();
  if (embs.has_value()) {
    find_or_insert_pointers(table, n, indices, weight_ptrs, founds, score);
  } else {
    find_pointers(table, n, indices, weight_ptrs, founds);
  }

  auto &device_prop = DeviceProp::getDeviceProp(grads.device().index());

  int64_t dim = grads.size(1);
  int64_t ev_nums = weight_ptrs.size(0);

  auto grad_type =
      scalartype_to_datatype(convertTypeMetaToScalarType(grads.dtype()));

  if (embs.has_value()) {
    DISPATCH_FLOAT_DATATYPE_FUNCTION(grad_type, g_t, [&] {
      DISPATCH_FLOAT_DATATYPE_FUNCTION(weight_type, w_t, [&] {
        
        SgdVecOptimizerV2<g_t, w_t> opt{lr};
        if (dim % 4 == 0) {
          const int max_grid_size =
              device_prop.num_sms *
              (device_prop.max_thread_per_sm / OPTIMIZER_BLOCKSIZE_VEC);
          const int warp_per_block = OPTIMIZER_BLOCKSIZE_VEC / WARPSIZE;

          int grid_size = 0;
          if (ev_nums / warp_per_block < max_grid_size) {
            grid_size = (ev_nums - 1) / warp_per_block + 1;
          } else if (ev_nums / warp_per_block > max_grid_size * MULTIPLIER) {
            grid_size = max_grid_size * MULTIPLIER;
          } else {
            grid_size = max_grid_size;
          }

          auto kernel = update4_kernel_v2<g_t, w_t, decltype(opt)>;
          kernel<<<grid_size, OPTIMIZER_BLOCKSIZE_VEC, 0, stream>>>(
            ev_nums, dim, reinterpret_cast<const g_t *>(grads.data_ptr()),
            reinterpret_cast<w_t **>(weight_ptrs.data_ptr()), reinterpret_cast<w_t *>(embs.value().data_ptr()), founds.data_ptr<bool>(), opt);
          DEMB_CUDA_KERNEL_LAUNCH_CHECK();
        } else {
          int block_size = dim > OPTIMIZER_BLOCKSIZE ? OPTIMIZER_BLOCKSIZE : dim;
          int grid_size = ev_nums;

          auto kernel = update_kernel_v2<g_t, w_t, decltype(opt)>;
          kernel<<<grid_size, block_size, 0, stream>>>(
            ev_nums, dim, reinterpret_cast<const g_t *>(grads.data_ptr()),
            reinterpret_cast<w_t **>(weight_ptrs.data_ptr()), reinterpret_cast<w_t *>(embs.value().data_ptr()), founds.data_ptr<bool>(), opt);
          DEMB_CUDA_KERNEL_LAUNCH_CHECK();
        }
      });
    });
    DEMB_CUDA_KERNEL_LAUNCH_CHECK();
    return;
  }

  DISPATCH_FLOAT_DATATYPE_FUNCTION(grad_type, g_t, [&] {
    DISPATCH_FLOAT_DATATYPE_FUNCTION(weight_type, w_t, [&] {
      
      SgdVecOptimizer<g_t, w_t> opt{lr};
      if (dim % 4 == 0) {
        const int max_grid_size =
            device_prop.num_sms *
            (device_prop.max_thread_per_sm / OPTIMIZER_BLOCKSIZE_VEC);
        const int warp_per_block = OPTIMIZER_BLOCKSIZE_VEC / WARPSIZE;

        int grid_size = 0;
        if (ev_nums / warp_per_block < max_grid_size) {
          grid_size = (ev_nums - 1) / warp_per_block + 1;
        } else if (ev_nums / warp_per_block > max_grid_size * MULTIPLIER) {
          grid_size = max_grid_size * MULTIPLIER;
        } else {
          grid_size = max_grid_size;
        }

        auto kernel = update4_kernel<g_t, w_t, decltype(opt)>;
        kernel<<<grid_size, OPTIMIZER_BLOCKSIZE_VEC, 0, stream>>>(
          ev_nums, dim, reinterpret_cast<const g_t *>(grads.data_ptr()),
          reinterpret_cast<w_t **>(weight_ptrs.data_ptr()), founds.data_ptr<bool>(), opt);
        DEMB_CUDA_KERNEL_LAUNCH_CHECK();
      } else {
        int block_size = dim > OPTIMIZER_BLOCKSIZE ? OPTIMIZER_BLOCKSIZE : dim;
        int grid_size = ev_nums;

        auto kernel = update_kernel<g_t, w_t, decltype(opt)>;
        kernel<<<grid_size, block_size, 0, stream>>>(
          ev_nums, dim, reinterpret_cast<const g_t *>(grads.data_ptr()),
          reinterpret_cast<w_t **>(weight_ptrs.data_ptr()), founds.data_ptr<bool>(), opt);
        DEMB_CUDA_KERNEL_LAUNCH_CHECK();
      }
    });
  });
  DEMB_CUDA_KERNEL_LAUNCH_CHECK();
}

void dynamic_emb_adam_with_table(
  std::shared_ptr<dyn_emb::DynamicVariableBase> ht,
  const uint64_t n, const at::Tensor indices, const at::Tensor grads, 
  const float lr, const float beta1, const float beta2, const float eps,
  const float weight_decay,
  const uint32_t iter_num, DataType weight_type, 
  const std::optional<uint64_t> score,
  const c10::optional<at::Tensor>& embs) {

  if (n == 0) return;
  TORCH_CHECK(indices.is_cuda(), "indices must be a CUDA tensor");
  TORCH_CHECK(grads.is_cuda(), "grads must be a CUDA tensor");

  at::Tensor founds = at::empty({static_cast<int64_t>(n)}, 
                                at::TensorOptions().dtype(at::kBool).device(indices.device()));
  at::Tensor vector_ptrs = at::empty({static_cast<int64_t>(n)}, 
                                     at::TensorOptions().dtype(at::kLong).device(indices.device()));

  auto stream = at::cuda::getCurrentCUDAStream().stream();
  if (embs.has_value()) {
    find_or_insert_pointers(ht, n, indices, vector_ptrs, founds, score);
  } else {
    find_pointers(ht, n, indices, vector_ptrs, founds);
  }
  

  auto &device_prop = DeviceProp::getDeviceProp(grads.device().index());

  int64_t dim = grads.size(1);
  int64_t ev_nums = n;

  auto grad_type =
      scalartype_to_datatype(convertTypeMetaToScalarType(grads.dtype()));

  if (embs.has_value()) {
    DISPATCH_FLOAT_DATATYPE_FUNCTION(grad_type, g_t, [&] {
      DISPATCH_FLOAT_DATATYPE_FUNCTION(weight_type, w_t, [&] {
        AdamVecOptimizerV2<g_t, w_t> opt{lr,
                                      beta1,
                                      beta2,
                                      eps,
                                      weight_decay,
                                      iter_num};
        if (dim % 4 == 0) {
          const int max_grid_size =
              device_prop.num_sms *
              (device_prop.max_thread_per_sm / OPTIMIZER_BLOCKSIZE_VEC);
          const int warp_per_block = OPTIMIZER_BLOCKSIZE_VEC / WARPSIZE;

          int grid_size = 0;
          if (ev_nums / warp_per_block < max_grid_size) {
            grid_size = (ev_nums - 1) / warp_per_block + 1;
          } else if (ev_nums / warp_per_block > max_grid_size * MULTIPLIER) {
            grid_size = max_grid_size * MULTIPLIER;
          } else {
            grid_size = max_grid_size;
          }

          auto kernel = update4_kernel_v2<g_t, w_t, decltype(opt)>;
          kernel<<<grid_size, OPTIMIZER_BLOCKSIZE_VEC, 0, stream>>>(
            ev_nums, dim, reinterpret_cast<const g_t *>(grads.data_ptr()),
            reinterpret_cast<w_t **>(vector_ptrs.data_ptr()), reinterpret_cast<w_t *>(embs.value().data_ptr()), founds.data_ptr<bool>(), opt);
          DEMB_CUDA_KERNEL_LAUNCH_CHECK();
        } else {
          int block_size = dim > OPTIMIZER_BLOCKSIZE ? OPTIMIZER_BLOCKSIZE : dim;
          int grid_size = ev_nums;

          auto kernel = update_kernel_v2<g_t, w_t, decltype(opt)>;
          kernel<<<grid_size, block_size, 0, stream>>>(
            ev_nums, dim, reinterpret_cast<const g_t *>(grads.data_ptr()),
            reinterpret_cast<w_t **>(vector_ptrs.data_ptr()), reinterpret_cast<w_t *>(embs.value().data_ptr()), founds.data_ptr<bool>(), opt);
          DEMB_CUDA_KERNEL_LAUNCH_CHECK();
        }
      });
    });
    DEMB_CUDA_KERNEL_LAUNCH_CHECK();
    return;
  }

  DISPATCH_FLOAT_DATATYPE_FUNCTION(grad_type, g_t, [&] {
    DISPATCH_FLOAT_DATATYPE_FUNCTION(weight_type, w_t, [&] {
      AdamVecOptimizer<g_t, w_t> opt{lr,
                                     beta1,
                                     beta2,
                                     eps,
                                     weight_decay,
                                     iter_num};
      if (dim % 4 == 0) {
        const int max_grid_size =
            device_prop.num_sms *
            (device_prop.max_thread_per_sm / OPTIMIZER_BLOCKSIZE_VEC);
        const int warp_per_block = OPTIMIZER_BLOCKSIZE_VEC / WARPSIZE;

        int grid_size = 0;
        if (ev_nums / warp_per_block < max_grid_size) {
          grid_size = (ev_nums - 1) / warp_per_block + 1;
        } else if (ev_nums / warp_per_block > max_grid_size * MULTIPLIER) {
          grid_size = max_grid_size * MULTIPLIER;
        } else {
          grid_size = max_grid_size;
        }

        auto kernel = update4_kernel<g_t, w_t, decltype(opt)>;
        kernel<<<grid_size, OPTIMIZER_BLOCKSIZE_VEC, 0, stream>>>(
          ev_nums, dim, reinterpret_cast<const g_t *>(grads.data_ptr()),
          reinterpret_cast<w_t **>(vector_ptrs.data_ptr()), founds.data_ptr<bool>(), opt);
        DEMB_CUDA_KERNEL_LAUNCH_CHECK();
      } else {
        int block_size = dim > OPTIMIZER_BLOCKSIZE ? OPTIMIZER_BLOCKSIZE : dim;
        int grid_size = ev_nums;

        auto kernel = update_kernel<g_t, w_t, decltype(opt)>;
        kernel<<<grid_size, block_size, 0, stream>>>(
          ev_nums, dim, reinterpret_cast<const g_t *>(grads.data_ptr()),
          reinterpret_cast<w_t **>(vector_ptrs.data_ptr()), founds.data_ptr<bool>(), opt);
        DEMB_CUDA_KERNEL_LAUNCH_CHECK();
      }
    });
  });
  DEMB_CUDA_KERNEL_LAUNCH_CHECK();
}

void dynamic_emb_adagrad_with_table(
  std::shared_ptr<dyn_emb::DynamicVariableBase> ht,
  const uint64_t n, const at::Tensor indices,
  const at::Tensor grads,
  const float lr,
  const float eps,
  DataType weight_type,const std::optional<uint64_t> score,
  const c10::optional<at::Tensor>& embs){
  if (n == 0) return;

  TORCH_CHECK(indices.is_cuda(), "indices must be a CUDA tensor");
  TORCH_CHECK(grads.is_cuda(), "grads must be a CUDA tensor");

  at::Tensor founds = at::empty({static_cast<int64_t>(n)}, 
                                at::TensorOptions().dtype(at::kBool).device(indices.device()));
  at::Tensor vector_ptrs = at::empty({static_cast<int64_t>(n)}, 
                                     at::TensorOptions().dtype(at::kLong).device(indices.device()));

  auto stream = at::cuda::getCurrentCUDAStream().stream();
  if (embs.has_value()) {
    find_or_insert_pointers(ht, n, indices, vector_ptrs, founds, score);
  } else {
    find_pointers(ht, n, indices, vector_ptrs, founds);
  }

  auto& device_prop = DeviceProp::getDeviceProp(grads.device().index());

  int64_t dim = grads.size(1);
  int64_t ev_nums = n;

  auto grad_type = scalartype_to_datatype(convertTypeMetaToScalarType(grads.dtype()));

  if (embs.has_value()) {

  DISPATCH_FLOAT_DATATYPE_FUNCTION(grad_type, g_t, [&] {
    DISPATCH_FLOAT_DATATYPE_FUNCTION(weight_type, w_t, [&] {

      AdaGradVecOptimizerV2<g_t,w_t> opt{lr, eps, ht->get_initial_optstate()};

      if (dim % 4 == 0) {
        const int max_grid_size = device_prop.num_sms * (device_prop.max_thread_per_sm / OPTIMIZER_BLOCKSIZE_VEC);
        const int warp_per_block = OPTIMIZER_BLOCKSIZE_VEC/WARPSIZE;

        int grid_size = 0;
        if (ev_nums/warp_per_block < max_grid_size){
            grid_size = (ev_nums-1)/warp_per_block+1;
        }
        else if (ev_nums/warp_per_block > max_grid_size*MULTIPLIER){
            grid_size = max_grid_size*MULTIPLIER;
        }
        else{
            grid_size = max_grid_size;
        }

        auto kernel = update4_kernel_v2<g_t, w_t, decltype(opt)>;
        kernel<<<grid_size, OPTIMIZER_BLOCKSIZE_VEC, 0, stream>>>(
          ev_nums, dim, reinterpret_cast<const g_t *>(grads.data_ptr()),
          reinterpret_cast<w_t **>(vector_ptrs.data_ptr()), reinterpret_cast<w_t *>(embs.value().data_ptr()), founds.data_ptr<bool>(), opt);
        DEMB_CUDA_KERNEL_LAUNCH_CHECK();
      } else {

        int block_size = dim > OPTIMIZER_BLOCKSIZE ? OPTIMIZER_BLOCKSIZE : dim;
        int grid_size = ev_nums;

        auto kernel = update_kernel_v2<g_t, w_t, decltype(opt)>;
        kernel<<<grid_size, block_size, 0, stream>>>(
          ev_nums, dim, reinterpret_cast<const g_t *>(grads.data_ptr()),
          reinterpret_cast<w_t **>(vector_ptrs.data_ptr()), reinterpret_cast<w_t *>(embs.value().data_ptr()), founds.data_ptr<bool>(), opt);
        DEMB_CUDA_KERNEL_LAUNCH_CHECK();
      }
    });
  });
  DEMB_CUDA_KERNEL_LAUNCH_CHECK();

    return;
  }

  DISPATCH_FLOAT_DATATYPE_FUNCTION(grad_type, g_t, [&] {
    DISPATCH_FLOAT_DATATYPE_FUNCTION(weight_type, w_t, [&] {

      AdaGradVecOptimizer<g_t,w_t> opt{lr, eps};

      if (dim % 4 == 0) {
        const int max_grid_size = device_prop.num_sms * (device_prop.max_thread_per_sm / OPTIMIZER_BLOCKSIZE_VEC);
        const int warp_per_block = OPTIMIZER_BLOCKSIZE_VEC/WARPSIZE;

        int grid_size = 0;
        if (ev_nums/warp_per_block < max_grid_size){
            grid_size = (ev_nums-1)/warp_per_block+1;
        }
        else if (ev_nums/warp_per_block > max_grid_size*MULTIPLIER){
            grid_size = max_grid_size*MULTIPLIER;
        }
        else{
            grid_size = max_grid_size;
        }

        auto kernel = update4_kernel<g_t, w_t, decltype(opt)>;
        kernel<<<grid_size, OPTIMIZER_BLOCKSIZE_VEC, 0, stream>>>(
          ev_nums, dim, reinterpret_cast<const g_t *>(grads.data_ptr()),
          reinterpret_cast<w_t **>(vector_ptrs.data_ptr()), founds.data_ptr<bool>(), opt);
        DEMB_CUDA_KERNEL_LAUNCH_CHECK();
      } else {

        int block_size = dim > OPTIMIZER_BLOCKSIZE ? OPTIMIZER_BLOCKSIZE : dim;
        int grid_size = ev_nums;

        auto kernel = update_kernel<g_t, w_t, decltype(opt)>;
        kernel<<<grid_size, block_size, 0, stream>>>(
          ev_nums, dim, reinterpret_cast<const g_t *>(grads.data_ptr()),
          reinterpret_cast<w_t **>(vector_ptrs.data_ptr()), founds.data_ptr<bool>(), opt);
        DEMB_CUDA_KERNEL_LAUNCH_CHECK();
      }
    });
  });
  DEMB_CUDA_KERNEL_LAUNCH_CHECK();
}

void dynamic_emb_rowwise_adagrad_with_table(
  std::shared_ptr<dyn_emb::DynamicVariableBase> ht,
  const uint64_t n, const at::Tensor indices,
  const at::Tensor grads,
  const float lr,
  const float eps,
  DataType weight_type,const std::optional<uint64_t> score,
  const c10::optional<at::Tensor>& embs) {
  if (n == 0) return;
  TORCH_CHECK(indices.is_cuda(), "indices must be a CUDA tensor");
  TORCH_CHECK(grads.is_cuda(), "grads must be a CUDA tensor");

  at::Tensor founds = at::empty({static_cast<int64_t>(n)}, 
                                at::TensorOptions().dtype(at::kBool).device(indices.device()));
  at::Tensor vector_ptrs = at::empty({static_cast<int64_t>(n)}, 
                                     at::TensorOptions().dtype(at::kLong).device(indices.device()));

  auto stream = at::cuda::getCurrentCUDAStream().stream();
  if (embs.has_value()) {
    find_or_insert_pointers(ht, n, indices, vector_ptrs, founds, score);
  } else {
    find_pointers(ht, n, indices, vector_ptrs, founds);
  }

  auto& device_prop = DeviceProp::getDeviceProp(grads.device().index());

  int64_t dim = grads.size(1);
  int64_t ev_nums = n;

  auto grad_type = scalartype_to_datatype(convertTypeMetaToScalarType(grads.dtype()));

  if (embs.has_value()) {

    DISPATCH_FLOAT_DATATYPE_FUNCTION(grad_type, g_t, [&] {
      DISPATCH_FLOAT_DATATYPE_FUNCTION(weight_type, w_t, [&] {

        RowWiseAdaGradVecOptimizerV2<g_t, w_t> opt {lr, eps, ht->get_initial_optstate()};
        if (dim % 4 == 0) {
          const int max_grid_size = device_prop.num_sms * (device_prop.max_thread_per_sm / OPTIMIZER_BLOCKSIZE_VEC);
          const int warp_per_block = OPTIMIZER_BLOCKSIZE_VEC / WARPSIZE;

          int grid_size = 0;
          if (ev_nums / warp_per_block < max_grid_size) {
            grid_size = (ev_nums-1) / warp_per_block + 1;
          }
          else if (ev_nums / warp_per_block > max_grid_size * MULTIPLIER) {
            grid_size = max_grid_size * MULTIPLIER;
          } else {
            grid_size = max_grid_size;
          }

          auto kernel = update4_kernel_v2<g_t, w_t, decltype(opt)>;
          kernel<<<grid_size, OPTIMIZER_BLOCKSIZE_VEC, 0, stream>>>(
            ev_nums, dim, reinterpret_cast<const g_t *>(grads.data_ptr()),
            reinterpret_cast<w_t **>(vector_ptrs.data_ptr()), reinterpret_cast<w_t *>(embs.value().data_ptr()), founds.data_ptr<bool>(), opt);
          DEMB_CUDA_KERNEL_LAUNCH_CHECK();

        } else {

          int block_size = dim > OPTIMIZER_BLOCKSIZE ? OPTIMIZER_BLOCKSIZE : dim;
          int grid_size = ev_nums;
          int shared_memory_bytes = block_size * sizeof(float);

          auto kernel = update_kernel_v2<g_t, w_t, decltype(opt)>;
          kernel<<<grid_size, block_size, shared_memory_bytes, stream>>>(
            ev_nums, dim, reinterpret_cast<const g_t *>(grads.data_ptr()),
            reinterpret_cast<w_t **>(vector_ptrs.data_ptr()), reinterpret_cast<w_t *>(embs.value().data_ptr()), founds.data_ptr<bool>(), opt);
          DEMB_CUDA_KERNEL_LAUNCH_CHECK();
        }
      });
    });
    DEMB_CUDA_KERNEL_LAUNCH_CHECK();

    return;
  }

  DISPATCH_FLOAT_DATATYPE_FUNCTION(grad_type, g_t, [&] {
    DISPATCH_FLOAT_DATATYPE_FUNCTION(weight_type, w_t, [&] {

      RowWiseAdaGradVecOptimizer<g_t, w_t> opt {lr, eps};
      if (dim % 4 == 0) {
        const int max_grid_size = device_prop.num_sms * (device_prop.max_thread_per_sm / OPTIMIZER_BLOCKSIZE_VEC);
        const int warp_per_block = OPTIMIZER_BLOCKSIZE_VEC / WARPSIZE;

        int grid_size = 0;
        if (ev_nums / warp_per_block < max_grid_size) {
          grid_size = (ev_nums-1) / warp_per_block + 1;
        }
        else if (ev_nums / warp_per_block > max_grid_size * MULTIPLIER) {
          grid_size = max_grid_size * MULTIPLIER;
        } else {
          grid_size = max_grid_size;
        }

        auto kernel = update4_kernel<g_t, w_t, decltype(opt)>;
        kernel<<<grid_size, OPTIMIZER_BLOCKSIZE_VEC, 0, stream>>>(
          ev_nums, dim, reinterpret_cast<const g_t *>(grads.data_ptr()),
          reinterpret_cast<w_t **>(vector_ptrs.data_ptr()), founds.data_ptr<bool>(), opt);
        DEMB_CUDA_KERNEL_LAUNCH_CHECK();

      } else {

        int block_size = dim > OPTIMIZER_BLOCKSIZE ? OPTIMIZER_BLOCKSIZE : dim;
        int grid_size = ev_nums;
        int shared_memory_bytes = block_size * sizeof(float);

        auto kernel = update_kernel<g_t, w_t, decltype(opt)>;
        kernel<<<grid_size, block_size, shared_memory_bytes, stream>>>(
          ev_nums, dim, reinterpret_cast<const g_t *>(grads.data_ptr()),
          reinterpret_cast<w_t **>(vector_ptrs.data_ptr()), founds.data_ptr<bool>(), opt);
        DEMB_CUDA_KERNEL_LAUNCH_CHECK();
      }
    });
  });
  DEMB_CUDA_KERNEL_LAUNCH_CHECK();
}

} // namespace dyn_emb

// PYTHON WRAP
void bind_optimizer_kernel_op(py::module &m) {
  m.def("dynamic_emb_sgd_with_table", &dyn_emb::dynamic_emb_sgd_with_table,
        "SGD optimizer for Dynamic Emb", py::arg("table"),
        py::arg("n"), py::arg("indices"), py::arg("grads"),
        py::arg("lr"), py::arg("weight_type"), py::arg("score") = py::none(), py::arg("emb") = c10::nullopt);

  m.def("dynamic_emb_adam_with_table", &dyn_emb::dynamic_emb_adam_with_table,
        "Adam optimizer for Dynamic Emb", py::arg("ht"),
        py::arg("n"), py::arg("indices"), py::arg("grads"),
        py::arg("lr"), py::arg("beta1"),
        py::arg("beta2"), py::arg("eps"), py::arg("weight_decay"), py::arg("iter_num"),
        py::arg("weight_type"), py::arg("score") = py::none(), py::arg("emb") = c10::nullopt);

  m.def("dynamic_emb_adagrad_with_table", &dyn_emb::dynamic_emb_adagrad_with_table,
        "Adagrad optimizer for Dynamic Emb", py::arg("ht"),
        py::arg("n"), py::arg("indices"), py::arg("grads"),py::arg("lr"),
        py::arg("eps"),
        py::arg("weight_type"), py::arg("score") = py::none(), py::arg("emb") = c10::nullopt);

  m.def("dynamic_emb_rowwise_adagrad_with_table", &dyn_emb::dynamic_emb_rowwise_adagrad_with_table,
        "Row Wise Adagrad optimizer for Dynamic Emb", py::arg("ht"),
        py::arg("n"), py::arg("indices"), py::arg("grads"),py::arg("lr"),
        py::arg("eps"),
        py::arg("weight_type"), py::arg("score") = py::none(), py::arg("emb") = c10::nullopt);
}
