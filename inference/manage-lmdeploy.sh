#!/bin/bash

####################################################################################################
#
# This script is used to manage lmdeploy inference Engine. It can start/stop and check status of
# a lmdeploy inference server.
#
# Before use it, please make sure you set the correct model name, model path and model length in
# the start() function. Please also be carefull for the arguments in the environments setup
# section
# 
#    CONDA_PATH, this script uses miniconda virtual environment, CONDA_PATH is the path to the 
#        conda environment.
#
#    LISTEN_HOST, the host lmdeploy server will be listening on, either is "0.0.0.0" or "127.0.0.1" 
#        for local listening.
#
#    LISTEN_PORT, the port lmdeploy server will be listening on.
#
#    BATCH_SIZE(--max-batch-size) 256, set maximum number of sequences per iteration, 256 had 
#        better performance in most scenarios except RAG on A100 hardware after the benchmark 
#        comparision. For GPU less power than A100, recommends it set to 128.
#     
#    PREFIX_CACHE="--enable-prefix-caching", enable prompts prefix cache. It improves the 
#        performance of TTFT/ITL/E2E latency and throughtput for prompts with a prefix, 
#        like a system prompt or a fixed prefix description.
# 
#    MODEL_HOME, set the home path for all the LLM models 
#
#    GPU_MEM_RATIO, set the GPU VRAM ratio used for model weight and KV cache.
# 
####################################################################################################

# set -x 

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
MODEL_HOME=/data/Models/
# Set the ratio of GPU VRAM for the lmdeploy server
GPU_MEM_RATIO="0.9"

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
# Define a function to start the lmdeploy instance.
###########################################################################
start () {
  # Check if $MODEL_NAME exists
  if [ ! -z $MODEL_NAME ]; then
    # Define the models managed by this scripts, and their context length.
    case $MODEL_NAME in
      glm-4-9b-chat-int4)
        MODEL_PATH="$MODEL_HOME/GLM-4/glm-4-9b-chat-int4/"
        MODEL_LENGTH="8192"
        ;;
      glm-4-9b-chat)
        MODEL_PATH="$MODEL_HOME/GLM-4/glm-4-9b-chat/"
        MODEL_LENGTH="8192"
        ;;
      qwen2-7b-instruct)
        MODEL_PATH="$MODEL_HOME/Qwen2/Qwen2-7B-Instruct/"
        MODEL_LENGTH="8192"
        ;;        
      qwen2-7b-instruct-awq-int4)
        MODEL_PATH="$MODEL_HOME/Qwen2/Qwen2-7B-Instruct-AWQ/"
        MODEL_LENGTH="8192"
        ;;
      llama3-8b-instruct)
        MODEL_PATH="$MODEL_HOME/Llama3/Meta-Llama-3-8B-Instruct"
        MODEL_LENGTH="8192"
      ;;
      llama3-8b-instruct-awq-int4)
        MODEL_PATH="$MODEL_HOME/Llama3/llama-3-8b-instruct-awq/"
        MODEL_LENGTH="8192"
      ;;
      *)
        echo_error "Invalid model name: $MODEL_NAME"
        help
        exit 1
        ;;
    esac
  else
    echo_error "The action: \"$ACTION\" must specify a model name."
    help
    exit 1
  fi

  # Check if the MODEL_PATH exists
  if [ ! -d $MODEL_PATH ]
    then
      echo "Path $MODEL_PATH does not exist!"
      exit 1
  fi

  # Check if the CONDA_PATH exists
  if [ ! -d $CONDA_PATH ]
    then
      echo "Path $CONDA_PATH does not exist!"
      exit 1
  fi

  # If lmdeploy is running
  if status; then
    echo_error "A lmdeploy instance is already running with pid: $_pid, please check!"
    exit 1
  fi

  # Define lmdeploy output log file.
  OUTPUT="$(date +"%Y-%m-%d_%H-%M-%S").${MODEL_NAME}.out"
  if [ ! -d logs ]; then
    mkdir logs
  fi

  # Start lmdeploy in the backgroud.
  echo_log "Starting lmdeploy with model: $MODEL_NAME ..."
  nohup $CONDA_PATH/bin/python \
    $CONDA_PATH/bin/lmdeploy serve api_server $MODEL_PATH \
	  --log-level INFO --model-name $MODEL_NAME \
    --server-name $LISTEN_HOST \
	  --server-port $LISTEN_PORT \
    --session-len $MODEL_LENGTH \
	  --cache-max-entry-count $GPU_MEM_RATIO \
	  --max-batch-size $BATCH_SIZE \
    $PREFIX_CACHE  > logs/$OUTPUT 2>&1 &
  if [ $? -ne 0 ]; then
    echo_error "Starting lmdeploy failed, please check log file logs/${OUTPUT}."
    exit 1
  fi
  # Remove the file link first
  if [ -L server.out ]; then
    rm server.out
  fi
  # Re-link the current log file to server.out
  ln -s logs/$OUTPUT server.out
  # Checking logs for the starting state
  for (( i=1; i<=60; i++ ))
  do
    # Grep the key words in the server.out
    _count=$(grep -E "(model_config|turbomind format|backend_config|startup complete)" server.out |wc -l)
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
      _status=$(tail -10 server.out | grep "shutdown complete" |wc -l)
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
# Define a function to print help information
###########################################################################
help () {
  echo "Usage: $0 <start/stop/status> <model name>
        MODEL_NAME is one of :
          glm-4-9b-chat-gptq-int4
          glm-4-9b-chat
          qwen2-7b-instruct-gptq-int4
          qwen2-7b-instruct-awq-int4
	        llama3-8b-instruct
	        llama3-8b-instruct-awq-int4"
}

###########################################################################
# Main body of the script
###########################################################################

# Check input parameters.
if [ "$#" -lt 1 ]; then
  echo_error "You must input at least 1 parameters."
  help
  exit 1
fi

ACTION=$1

MODEL_NAME=$2

case $ACTION in 
  start)
    start
    ;;
  stop)
    stop
    ;;
  status)
    if status; then
      echo "The lmdeploy instance is running."
    else
      echo "No lmdeploy instance running."
    fi
    ;;
  *)
    echo_error "Invalid action: $ACTION"
    help
    exit 1
    ;;
esac
