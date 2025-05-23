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
import warnings

# Ignore all FutureWarnings
warnings.filterwarnings("ignore", category=FutureWarning)
warnings.filterwarnings("ignore", category=SyntaxWarning)
import argparse
from dataclasses import dataclass
from functools import partial  # pylint: disable-unused-import
from typing import List, Tuple, Union, cast

import commons.utils.initialize as init
import gin
import torch  # pylint: disable-unused-import
from commons.utils.logging import print_rank_0
from configs import RankingConfig
from megatron.core.optimizer import get_megatron_optimizer
from model import get_ranking_model
from utils import (
    DistributedDataParallelArgs,
    NetworkArgs,
    OptimizerArgs,
    TensorModelParallelArgs,
    TrainerArgs,
    create_embedding_config,
    create_hstu_config,
    create_optimizer_config,
    get_data_loader,
    get_dataset_and_embedding_args,
    maybe_load_ckpts,
    train,
)


@gin.configurable
@dataclass
class RankingArgs:
    prediction_head_arch: List[List[int]] = cast(List[List[int]], None)
    prediction_head_act_type: Union[str, List[str]] = "relu"
    prediction_head_bias: Union[bool, List[bool]] = True
    eval_metrics: Tuple[str, ...] = ("AUC",)

    def __post_init__(self):
        assert (
            self.prediction_head_arch is not None
        ), "Please provide prediction head arch for ranking model"
        if isinstance(self.prediction_head_act_type, str):
            assert self.prediction_head_act_type.lower() in [
                "relu"
            ], "prediction_head_act_type should be in ['relu']"


parser = argparse.ArgumentParser(
    description="Distributed GR Arguments", allow_abbrev=False
)
parser.add_argument("--gin-config-file", type=str)
args = parser.parse_args()
gin.parse_config_file(args.gin_config_file)
trainer_args = TrainerArgs()
dataset_args, embedding_args = get_dataset_and_embedding_args()
network_args = NetworkArgs()
optimizer_args = OptimizerArgs()
ddp_args = DistributedDataParallelArgs()
tp_args = TensorModelParallelArgs()


def create_ranking_config() -> RankingConfig:
    ranking_args = RankingArgs()

    return RankingConfig(
        embedding_configs=[
            create_embedding_config(network_args.hidden_size, arg, optimizer_args)
            for arg in embedding_args
        ],
        prediction_head_arch=ranking_args.prediction_head_arch,
        prediction_head_act_type=ranking_args.prediction_head_act_type,
        prediction_head_bias=ranking_args.prediction_head_bias,
        eval_metrics=ranking_args.eval_metrics,
    )


def main():
    init.initialize_distributed()
    init.initialize_model_parallel(
        tensor_model_parallel_size=tp_args.tensor_model_parallel_size
    )
    init.set_random_seed(trainer_args.seed)
    free_memory, total_memory = torch.cuda.mem_get_info()
    print_rank_0(
        f"distributed env initialization done. Free cuda memory: {free_memory / (1024 ** 2):.2f} MB"
    )
    hstu_config = create_hstu_config(network_args)
    task_config = create_ranking_config()
    model = get_ranking_model(hstu_config=hstu_config, task_config=task_config)

    dense_optimizer_config = create_optimizer_config(network_args, optimizer_args)
    dense_optimizer = get_megatron_optimizer(
        dense_optimizer_config, [model._dense_module]
    )

    train_dataloader, test_dataloader = get_data_loader(
        "ranking", dataset_args, trainer_args
    )
    free_memory, total_memory = torch.cuda.mem_get_info()
    print_rank_0(
        f"model initialization done, start training. Free cuda memory: {free_memory / (1024 ** 2):.2f} MB"
    )

    maybe_load_ckpts(trainer_args.ckpt_load_dir, model, dense_optimizer)

    train(
        model,
        trainer_args,
        train_dataloader,
        test_dataloader,
        dense_optimizer,
    )
    init.destroy_global_state()


if __name__ == "__main__":
    main()
