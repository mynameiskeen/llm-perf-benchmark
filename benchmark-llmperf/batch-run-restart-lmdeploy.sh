#!/bin/bash

###################################################################################################
# 
# This script is used to batch-run benchmarks. The batch jobs need to be defined in a yaml file.
# Each scenario with the same concurreny will be testing for 5 times.
#
###################################################################################################

set -x

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

MODEL_NAME="llama3-8b-instruct"

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
# Define a function to parse scenarios yaml file
###########################################################################

parse_jobs () {

# Check if yq command exists
if ! command -v yq >/dev/null 2>&1 ; then
  echo_error "Command yq does not exist, please install first."
  exit 1
fi

# Get jobs from jobs yaml file
if [[ "$(yq '. | has("jobs")' $JOBS_FILE)" != "true" ]]; then
  echo_error "Failed to parse $JOBS_FILE, please check if the file is a valid yaml or the top level key is \"jobs\"."
  exit 1
fi

# Get all the scenario keys
local _scns=($(yq '.jobs.* | key' $JOBS_FILE ))

# Define a jobs array
batch_jobs=()

for _scn in "${_scns[@]}"
do
  # Pre-defined scenarios are IR/QA/TS/GC/RAG, other than
  if ! echo $_scn | grep -E "^(IR|QA|TS|GC|RAG|GP)$" >/dev/null 2>&1 ; then
    echo_error "Scenario: $_scn is not a pre-defined screnario, please check or define it in start_benchmark.sh."
    exit 1
  fi

  # Get concurrency from jobs yaml file
  local _con=($(yq ".jobs.${_scn}[]" $JOBS_FILE))

  # Check concurrency
  for _con in ${_con[@]}
  do
    # Check if $_con is a number
    if ! echo $_con | grep -E "^[0-9]{1,3}$" >/dev/null 2>&1 ; then 
      echo_error "Concurrency: $_con is not a valid number."
      exit 1
    fi
    
    # Assemble jobs
    local _job="$_scn-$_con"
    batch_jobs+=($_job)
  done
done
}

###########################################################################
# Define a function to check if llm inference is ready.
###########################################################################

check_service() {

# Generate the request body
cat > /tmp/who_are_you.json << EOF
{
  "model": "$MODEL_NAME",
  "messages": [
    {
      "role": "system",
      "content": "You are a helpful assistant."
    },
    {
      "role": "user",
      "content": "Who are you?"
    }
  ]
}
EOF

# Get the inference API endpoint
_endpoint=$(cat start_benchmark.sh  | grep OPENAI_API_BASE | awk -F "OPENAI_API_BASE=" '{print $2}' | sed 's/"//g')

# endpoint url should contain "v1"
if ! echo $_endpoint | grep v1 > /dev/null; then
  echo_error "The endpoint url $_endpoint seems not right, please check."
  exit 1
fi

# Define the full chat url
_chat_url=${_endpoint}/chat/completions

# Use curl to request inference api

_return=$(curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" -d @/tmp/who_are_you.json $_chat_url )
if [ $_return != "200" ]; then
  echo_error "The inference service seems not ready and returned with code: $_return"
  exit 1
fi

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
  for (( j=1; j<=60; j++ ))
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
# Define a function to restart the lmdeploy 
###########################################################################
restart_lmdeploy() {

# If is running
if status ; then
  stop && start
else
  start
fi

}

###########################################################################
# Check input parameters
###########################################################################
if [ "$#" -ne 2 ]; then
  echo_error "You must input 2 parameters."
  echo "Usage: $0 <scenarios file> <model name>"
  echo ""
  echo "      - <jobs file>, the file defines all the scenarios and their jobs will be benchmarked."
  echo "      - <model name>, the model will be bechmarked, this is the name using in /chat/completions api"
  echo ""
  echo "The <jobs file> is a yaml file to define all the batch jobs, the format is like:"
  echo "jobs:"
  echo "  TS:"
  echo "    - 5"
  echo "    - 10"
  echo "    - 20"
  exit 1
else
  JOBS_FILE=$1
  MODEL_NAME=$2
fi

# Check scenarios yaml file
if [ ! -f $JOBS_FILE ]; then
  echo_error "Scenarios file does not exist, please define scenarios in a file first."
  exit 1
fi

###########################################################################
# Start the benchmark
###########################################################################

# Parse scenarios yaml
parse_jobs

# Define result file
BATCH_RESULT=result_outputs/batch_run-$(date +"%Y-%m-%d_%H-%M").csv
echo ${batch_jobs[@]}
# Start the benchmark jobs one by one
for job in "${batch_jobs[@]}"
do
  scn=$(echo $job | awk -F '-' '{print $1}')
  con=$(echo $job | awk -F '-' '{print $2}')
  # Each scenario run 5 times.
  for (( i=1; i<=5; i++ ))
  do
    timestamp=$(date +"%Y-%m-%d_%H-%M")
    start_secs=$(date +%s)
    echo "$(date +"%Y-%m-%d_%H-%M-%S"): Starting scenario: $scn, job $i - concurrency: $con ..."
    ./start_benchmark.sh $scn $con $MODEL_NAME $i $timestamp >> $BATCH_RESULT
    if [ $? -ne 0 ]; then
      echo_error "$(date +"%Y-%m-%d_%H-%M-%S"): Benchmark job $i failed, please check log file logs/${timestamp}.${scn}-${con}-${MODEL_NAME}-${i}.out"
      # Tritonserver with tensorrt-llm backend has a lot of unexptected issues usually caused the service crash.
      # If the current task failed, restart the tritonserver docker and execute the following tasks.
      restart_lmdeploy || { echo_error "Failed to restart tritonserver."; exit 1; }
      check_service || { echo_error "Failed to check inference service."; exit 1; }
    fi
    end_secs=$(date +%s)
    duration=$(( $end_secs - start_secs ))
    echo "$(date +"%Y-%m-%d_%H-%M-%S"): Scenarios: $scn, job $i finished successfully, elapsed time: $duration seconds."
  done
done
echo "$(date +"%Y-%m-%d_%H-%M-%S"): All $i jobs have been done, please check $BATCH_RESULT for batch results."