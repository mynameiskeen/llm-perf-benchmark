#!/bin/bash

###################################################################################################
#
# 
###################################################################################################

#set -x

###########################################################################
# Environments setup
###########################################################################

# Set the Conda home
CONDA_PATH=/data/miniconda3/envs/lmdeploy
# Set the listen host
LISTEN_HOST=0.0.0.0
# Set the listen port
LISTEN_PORT=8010
# Set the batch size for lmdeploy
BATCH_SIZE=128
# Enable prefix caching
PREFIX_CACHE="--enable-prefix-caching"
# Set the path stores all the LLM models
MODEL_PATH4=/data/Models/Llama3/llama-3-8b-instruct-awq/
MODEL_PATH16=/data/Models/Llama3/Meta-Llama-3-8B-Instruct/
# Set the ratio of GPU VRAM for the lmdeploy server
GPU_MEM_RATIO="0.9"
# Set the length
MODEL_LENGTH=8192
# Set the model name
MODEL_NAME=llama-3-8b-instruct

###########################################################################
# Define a function to output error messages with red color.
###########################################################################
echo_error () {
  RED='\033[0;31m'
  NC='\033[0m'
  echo -e "${RED}$1${NC}"
}

###########################################################################
# Define a function to output normal logs with green color.
###########################################################################
echo_log () {
  GREEN='\033[0;32m'
  NC='\033[0m'
  local _timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
  echo -e "${GREEN}$_timestamp: $1${NC}"
}

###########################################################################
# 
###########################################################################

# Start ScaleLLM using awq 
cd /data/ScaleLLM
./manage_scalellm.sh start llama3-8b-instruct-awq

if [ $? -ne 0 ]; then
  echo_error "ScaleLLM failed to start."
  exit 1
fi
cd -

# Start benchmark for awq
# run request-rate 2/4/8/16/24/32
rates=(2 4 8 16 24 32)
for rate in ${rates[@]}
do
  echo_log "Starting benchmark for $rate ..."
  /data/miniconda3/envs/vllm/bin/python benchmark_serving.py --backend scalellm \
      --tokenizer $MODEL_PATH4 \
      --model llama-3-8b-instruct-awq --dataset-name sharegpt \
      --dataset-path ./ShareGPT_V3_unfiltered_cleaned_split.json \
      --num-prompts 500 --port 8010 --save-result \
      --result-dir result_outputs/ \
      --result-filename scalellm_llama3-8b-instruct-awq_qps_$rate.json \
      --request-rate $rate
  if [ $? -ne 0 ]; then
    echo_error "Benchmark qps $rate failed."
    exit 1
  fi
  echo_log "Finished benchmark for $rate ..."
done

# Stop ScaleLLM
cd /data/ScaleLLM
./manage_scalellm.sh stop

if [ $? -ne 0 ]; then
  echo_error "ScaleLLM failed to stop."
  exit 1
fi

# Start ScaleLLM in fp16
./manage_scalellm.sh start llama3-8b-instruct

if [ $? -ne 0 ]; then
  echo_error "ScaleLLM failed to start."
  exit 1
fi
cd -

# Start benchmark for fp16
# run request-rate 2/4/8/16/24/32
rates=(2 4 8 16 24 32)
for rate in ${rates[@]}
do
  echo_log "Starting benchmark for $rate ..."
  /data/miniconda3/envs/vllm/bin/python benchmark_serving.py --backend scalellm \
      --tokenizer $MODEL_PATH16 \
      --model Meta-Llama-3-8B-Instruct --dataset-name sharegpt \
      --dataset-path ./ShareGPT_V3_unfiltered_cleaned_split.json \
      --num-prompts 500 --port 8010 --save-result \
      --result-dir result_outputs/ \
      --result-filename scalellm_llama3-8b-instruct_qps_$rate.json \
      --request-rate $rate
  if [ $? -ne 0 ]; then
    echo_error "Benchmark qps $rate failed."
    exit 1
  fi
  echo_log "Finished benchmark for $rate ..."
done