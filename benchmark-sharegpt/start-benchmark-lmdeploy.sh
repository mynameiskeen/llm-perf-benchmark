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
# Define a function to check the lmdeploy instance status.
#   - Running, return 0
#   - Not running, return 1
###########################################################################
status () {
  # Get current lmdeploy instance pid.
  _pid=$(ps aux | grep lmdeploy | grep [a]pi_server |awk '{print $2}')

  # If $_pid exists, return 0 else return 1.
  if [ x"$_pid" != "x" ]; then
    return 0
  else
    return 1
  fi
}

###########################################################################
# Define a function to stop the lmdeploy instance.
###########################################################################
stop () {
  # If lmdeploy is not running
  if ! status; then
    echo_error "There's no lmdeploy instance running."
    exit 1
  else
    kill $_pid
    # After kill, checking the log for "shutdown complete" message.
    while true
    do
      _status=$(tail -10 server_lmdeploy.out | grep "shutdown complete" |wc -l)
      if [ $_status -eq 0 ]; then
        echo_log "The lmdeploy instance is terminating ..."
        sleep 2
      else
        echo_log "The lmdeploy instance stopped successfully."
        break
      fi
    done
  fi
}

###########################################################################
# Start lmdeploy
# Define lmdeploy output log file.
OUTPUT="$(date +"%Y-%m-%d_%H-%M-%S").${MODEL_NAME}-awq.out"
if [ ! -d logs ]; then
  mkdir logs
fi

# Start awq lmdeploy in the backgroud.
echo_log "Starting lmdeploy with model: $MODEL_NAME ..."
nohup $CONDA_PATH/bin/python \
    $CONDA_PATH/bin/lmdeploy serve api_server $MODEL_PATH4 \
    --log-level INFO \
    --server-name $LISTEN_HOST \
    --server-port $LISTEN_PORT \
    --session-len $MODEL_LENGTH \
    --cache-max-entry-count $GPU_MEM_RATIO \
    --max-batch-size $BATCH_SIZE \
    $PREFIX_CACHE  > logs/$OUTPUT 2>&1 &

# Remove the file link first
if [ -L server_lmdeploy.out ]; then
  rm server_lmdeploy.out
fi

# link the current log file to server_lmdeploy.out
ln -s logs/$OUTPUT server_lmdeploy.out

# Checking logs for the starting state
for (( i=1; i<=60; i++ ))
do
  # Grep the key words in the server_lmdeploy.out
  _count=$(grep -E "(model_config|turbomind format|backend_config|startup complete)" server_lmdeploy.out |wc -l)
  if [ $_count -eq 1 ]; then
    echo_log "Loading mode config ..."
    sleep 2
  elif [ $_count -eq 2 ]; then
    echo_log "Loading weight in turbomind format ..."
    sleep 2
  elif [ $_count -eq 3 ]; then
    echo_log "Loading backend config ..."
    sleep 2
  elif [ $_count -eq 4 ]; then
    echo_log "The lmdeploy instance started."
    echo_log "API server started on http://${LISTEN_HOST}:${LISTEN_PORT}"
    break
  else
    sleep 1
    continue
  fi
done

# Start benchmark for awq
# run request-rate 2/4/8/16/24/32
rates=(2 4 8 16 24 32)
for rate in ${rates[@]}
do
  echo_log "Starting benchmark for $rate ..."
  /data/miniconda3/envs/vllm/bin/python benchmark_serving.py --backend lmdeploy \
      --tokenizer $MODEL_PATH4 \
      --model $MODEL_PATH4 --dataset-name sharegpt \
      --dataset-path ./ShareGPT_V3_unfiltered_cleaned_split.json \
      --num-prompts 500 --port 8010 --save-result \
      --result-dir result_outputs/ \
      --result-filename lmdeploy_llama3-8b-instruct-awq_qps_$rate.json \
      --request-rate $rate
  if [ $? -ne 0 ]; then
    echo_error "Benchmark qps $rate failed."
    exit 1
  fi
  echo_log "Finished benchmark for $rate ..."
done

# Stop awq lmdeploy
stop

# Start bf16 lmdeploy
OUTPUT="$(date +"%Y-%m-%d_%H-%M-%S").${MODEL_NAME}-bf16.out"

# Start awq lmdeploy in the backgroud.
echo_log "Starting lmdeploy with model: $MODEL_NAME ..."
nohup $CONDA_PATH/bin/python \
    $CONDA_PATH/bin/lmdeploy serve api_server $MODEL_PATH16 \
    --log-level INFO \
    --server-name $LISTEN_HOST \
    --server-port $LISTEN_PORT \
    --session-len $MODEL_LENGTH \
    --cache-max-entry-count $GPU_MEM_RATIO \
    --max-batch-size $BATCH_SIZE \
    $PREFIX_CACHE  > logs/$OUTPUT 2>&1 &


# Remove the file link first
if [ -L server_lmdeploy.out ]; then
  rm server_lmdeploy.out
fi

# link the current log file to server_lmdeploy.out
ln -s logs/$OUTPUT server_lmdeploy.out

# Checking logs for the starting state
for (( i=1; i<=60; i++ ))
do
  # Grep the key words in the server_lmdeploy.out
  _count=$(grep -E "(Initializing|Starting to load|Loading model weights|startup complete)" server_lmdeploy.out |wc -l)
  if [ $_count -eq 1 ]; then
    echo_log "Initializing LLM enging ..."
    sleep 2
  elif [ $_count -eq 2 ]; then
    echo_log "Begin to load model weights ..."
    sleep 2
  elif [ $_count -eq 3 ]; then
    echo_log "Graph capturing in process ..."
    sleep 2
  elif [ $_count -eq 4 ]; then
    echo_log "The lmdeploy instance started."
    echo_log "API server started on http://${LISTEN_HOST}:${LISTEN_PORT}"
    break
  else
    sleep 1
    continue
  fi
done

# Start benchmark for awq
# run request-rate 2/4/8/16/24/32
rates=(2 4 8 16 24 32)
for rate in ${rates[@]}
do
  echo_log "Starting benchmark for $rate ..."
  /data/miniconda3/envs/vllm/bin/python benchmark_serving.py --backend lmdeploy \
      --tokenizer $MODEL_PATH16 \
      --model $MODEL_PATH16 --dataset-name sharegpt \
      --dataset-path ./ShareGPT_V3_unfiltered_cleaned_split.json \
      --num-prompts 500 --port 8010 --save-result \
      --result-dir result_outputs/ \
      --result-filename lmdeploy_llama3-8b-instruct-awq_qps_$rate.json \
      --request-rate $rate
  if [ $? -ne 0 ]; then
    echo_error "Benchmark qps $rate failed."
    exit 1
  fi
  echo_log "Finished benchmark for $rate ..."
done

# Stop awq lmdeploy
stop
echo_log "lmdeploy bf16 stopped."