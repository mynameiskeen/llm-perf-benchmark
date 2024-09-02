#!/bin/bash

###################################################################################################
# 
# This script is used to batch-run benchmarks. The batch jobs need to be defined in a yaml file.
# Each scenario with the same concurreny will be testing for 5 times.
#
###################################################################################################

#set -x

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
    "model": "ensemble",
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
# Define a function to restart the tritonserver docker 
###########################################################################
restart_tritonserver() {

# Get the docker container id
if [ $(docker ps -a | grep triton | wc -l) -eq 1 ]; then
  _container_id=$(docker ps -a | grep tritonserver | awk '{print $1}')
else 
  echo_error "There's no tritonserver container running or stopped."
  exit 1
fi

# Restart docker container
docker restart $_container_id > /dev/null
if [ $? -ne 0 ]; then
  echo_error "Failed to restart tritonserver container: $_container_id "
  exit 1
fi

# Check logs to see if the container restarts successfully.
for (( j=1; j<=10; j++ )) 
do
  # Grep the key words in the docker logs output
  _count=$(docker logs $_container_id 2>&1 | tail -3 |grep "Started HTTPService" | wc -l)
  if [ $_count -eq 1 ]; then
    echo_log "The tritonserver container $_container_id has been restarted."
    break
  else
    sleep 3
    continue
  fi
  if [ $j -eq 10 ]; then
    echo_error "The tritonserver container $_container_id failed to start within 30 seconds"
    exit 1
  fi
done

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
      restart_tritonserver || { echo_error "Failed to restart tritonserver."; exit 1; }
      check_service || { echo_error "Failed to check inference service."; exit 1; }
    fi
    end_secs=$(date +%s)
    duration=$(( $end_secs - start_secs ))
    echo "$(date +"%Y-%m-%d_%H-%M-%S"): Scenarios: $scn, job $i finished successfully, elapsed time: $duration seconds."
  done
done
echo "$(date +"%Y-%m-%d_%H-%M-%S"): All $i jobs have been done, please check $BATCH_RESULT for batch results."