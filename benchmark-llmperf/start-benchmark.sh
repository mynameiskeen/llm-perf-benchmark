#!/bin/bash

###################################################################################################
#
# This script is used to benchmark 6 scenarios of common user cases of LLM. If you have your own
# user cases, please modify SETUP SCRENARIOS section.
#
#   IR, Intention Recognition. User asks a short question, the LLM analyzes the question for 
#   user's intention and categorizaes it into a defined type.
#     - Average input length  : 50
#     - Average output length : 10
#
#   QA, which means Q&A. User asks a short question, the LLM gives the corresponding answer. 
#   The answers could be common knowledges or fine-tuned knowledges.
#     - Average input length  : 50
#     - Average output length : 150
#
#   TS, Text Summarization. User inputs a long context, the LLM responds with the summary of 
#   the input context.
#     - Average input length  : 1000
#     - Average output length : 250
# 
#   GC, Content generation. User inputs a carefully crafted prompt, the LLM respond with a 
#   long generated content.
#     - Average input length  : 100
#     - Average output length : 1000
# 
#   RAG, Argumented Retrival Generation. Usually it works with a RAG pipeline. Pipeline 
#   retrives dozens of chunks as the input context along with the prompt, the LLM generate 
#   the proper answer base on the input contexts.
#     - Average input length  : 6000
#     - Average output length : 500
# 
#   GP, General purpose. This scenario is the by default scenario from llmperf official example.
#     - Average input length  : 550
#     - Average output length : 150
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
# Define a function to analyze the results and monitoring performance.
###########################################################################

analyze_result() {

  if [ ! -f $report ]; then
    echo_error "Benchmark output report file $report does not exist, please check the log $log_file"
    exit 1
  else
    ### Number of requests
    num_requests=$(jq ".results_num_requests_started" $report)
    #### Avg output (tokens)
    output_tokens=$(jq ".results_number_output_tokens_mean" $report)
    #### Standard deviation of output (tokens)
    stddev=$(jq ".results_number_output_tokens_stddev" $report)
    #### Avg TTFT (seconds)
    ttft_mean=$(jq ".results_ttft_s_mean" $report)
    #### P99 TTFT (seconds)
    ttft_p99=$(jq ".results_ttft_s_quantiles_p99" $report)
    #### Avg ITL (seconds)
    itl_mean=$(jq ".results_inter_token_latency_s_mean" $report)
    #### P99 ITL (seconds)
    itl_p99=$(jq ".results_inter_token_latency_s_quantiles_p99" $report)
    #### Avg end to end latency (seconds)
    e2e_mean=$(jq ".results_end_to_end_latency_s_mean" $report)
    #### P99 end to end latency (seconds)
    e2e_p99=$(jq ".results_end_to_end_latency_s_quantiles_p99" $report)
    #### Throughput (Tokens/s)
    tokens_sec=$(jq ".results_mean_output_throughput_token_per_s" $report)
    #### Throughput (Requests/s)
    requests_sec=$(jq ".results_num_completed_requests_per_min" $report)
    #### Average GPU Util (%), only retrive GPU utilization is greater than 50
    avg_gpu=$(cat $perf | grep -v timestamp | awk -F ',' '{print $3}' | awk '{ if ($1 > 1) print $1}' | awk '{ sum += $1} END { if (NR > 0) print sum / NR }')
    #### VRAM Used (MB)"
    avg_mem=$(cat $perf | grep -v timestamp | awk -F ',' '{print $4}' | awk '{ if ($1 > 1) print $1}' | awk '{ sum += $1} END { if (NR > 0) print sum / NR }')
    #### Power (Watts)
    avg_power=$(cat $perf | grep -v timestamp | awk -F ',' '{print $7}' |  awk '{ if ($1 > 100) print $1}' | awk '{ sum += $1} END { if (NR > 0) print sum / NR }')
    if [ "$RUNTIME" = "vllm" ]; then
      #### Max KV cache Used
      max_kvcache=$(cat $metric | awk '{if ( $4 > 0.001 ) print $4}' | sort -r | head -1)
      #### Avg KV cache Used
      avg_kvcache=$(cat $metric | awk '{if ( $4 > 0.001 ) print $4}' | awk '{ sum += $1} END { if (NR > 0) print sum / NR }')
    fi
fi

  ## Convert seconds to microseconds and round to keep 2 digits
  output_tokens_round=$(echo "scale=2; ($output_tokens)/1" | bc)
  stddev_round=$(echo "scale=2; ($stddev)/1" | bc)
  ttft_mean_ms=$(echo "scale=2; ($ttft_mean * 1000)/1" | bc)
  ttft_p99_ms=$(echo "scale=2; ($ttft_p99 * 1000)/1" | bc)
  itl_mean_ms=$(echo "scale=2; ($itl_mean * 1000)/1" | bc)
  itl_p99_ms=$(echo "scale=2; ($itl_p99 * 1000)/1" | bc)
  e2e_mean_ms=$(echo "scale=2; ($e2e_mean * 1000)/1" | bc)
  e2e_p99_ms=$(echo "scale=2; ($e2e_p99 * 1000)/1" | bc)
  tokens_sec_round=$(echo "scale=2; ($tokens_sec)/1" | bc)
  requests_sec_round=$(echo "scale=2; ($requests_sec)/60" | bc)
  avg_gpu_round=$(echo "scale=2; ($avg_gpu)/1" | bc)
  avg_mem_round=$(echo "scale=2; ($avg_mem)/1" | bc)
  max_kvcache=${max_kvcache:-0}
  avg_kvcache=${avg_kvcache:-0}
  avg_power_round=$(echo "scale=2; ($avg_power)/1" | bc)
  if [ "$RUNTIME" = "vllm" ]; then
    max_kvcache_round=$(echo "scale=2; ($max_kvcache * 100)/1" | bc)
    avg_kvcache_round=$(echo "scale=2; ($avg_kvcache * 100)/1" | bc) 
  fi
}

###########################################################################
# Check input parameters
###########################################################################

if [ "$#" -lt 3 ]; then
  echo_error "You must input at least 3 parameters."
  echo "Usage: $0 <scenario> <conccurency> <model name> <job id[optional]> <timestampe[optional]>"
  echo ""
  echo "       - <scenario>    : This script pre-defined 6 scenarios: IR/QA/TS/GC/RAG/GP."
  echo "       - <concurrency> : How many concurrent requests will send to LLM at the same time."
  echo "       - <model name>  : This will pass to /chat/completions api as the model name."
  echo "       - <job id>      : [optional], this id is passing from batch_run.sh."
  echo "       - <timestampe>  : [optional], in "YYYY-MM-DD_HH24-MI" format, also passing from batch_run.sh"
  exit 1
fi

# Scenario
export SCENARIO=$1
if ! echo $SCENARIO | grep -E "^(IR|QA|TS|GC|RAG|GP)$" >/dev/null 2>&1 ; then
  echo_error "Scenario: $_scn is not a pre-defined screnario, please check or define it in this script."
  exit 1
fi
# Concurrent requests
export CONCURRENT_REQUESTS=$2
# Model Name
export MODEL_NAME=$3
# Job ID
export JOB_ID=$4
# Timestampe
export TIMESTAMP=$5

## Endpoint for inference engine. 
export OPENAI_API_BASE="http://localhost:8010/v1"
export OPENAI_API_KEY="na"

###########################################################################
# SETUP SCENARIOS
###########################################################################

## Define total requests. IR 1000, QA 500, rest testing for 150 requests. 
if [ "$SCENARIO" = "IR" ]; then 
  export MAX_REQUESTS=1000
elif [ "$SCENARIO" = "QA" ];then 
  export MAX_REQUESTS=500
else
  # For GC/RAG/GP testing 150 requests
  export MAX_REQUESTS=200
fi

TIMEOUT=3600

## Define standard deviation for input/output tokens, try to stable them.
export STDDEV_INPUT_TOKENS=0
export STDDEV_OUTPUT_TOKENS=0

case $SCENARIO in
    ## Scenario 1, intent recognition.
    IR)
      export MEAN_INPUT_TOKENS=50
      export MEAN_OUTPUT_TOKENS=10
    ;;

    ## Scenario 2, Q&A.
    QA)
      export MEAN_INPUT_TOKENS=50
      export MEAN_OUTPUT_TOKENS=150
    ;;

    ## Scenario 3, Text Summarization
    TS)
      export MEAN_INPUT_TOKENS=1000
      export MEAN_OUTPUT_TOKENS=250
    ;;

    ## Scenario 4, Content Generation
    GC)
      export MEAN_INPUT_TOKENS=100
      export MEAN_OUTPUT_TOKENS=1000
    ;;

    ## Scenario 5, RAG
    RAG)
      export MEAN_INPUT_TOKENS=6000
      export MEAN_OUTPUT_TOKENS=500
    ;;

    ## Scenario 6, GP
    GP)
      export MEAN_INPUT_TOKENS=550
      export MEAN_OUTPUT_TOKENS=150    
    ;;
esac

## llmperf using llama tokenizer to calculate the input/output tokens. Check if it's downloaded already.
if [ ! -d /root/.cache/huggingface/hub/models--hf-internal-testing--llama-tokenizer/ ]; then 
  echo_error "Llama tokenizer cache does not exist, please using below command to download the llama tokenizer first."
  echo "export HF_ENDPOINT=https://hf-mirror.com; huggingface-cli download hf-internal-testing/llama-tokenizer"
  exit 1
fi
## Check if result_outputs exists
if [ ! -d result_outputs ]; then
  mkdir result_outputs
fi

## Start the GPU monitoring command
perf=result_outputs/${MODEL_NAME}_${SCENARIO}_$(date +"%Y-%m-%d_%H-%M-%S").perf
nohup nvidia-smi --query-gpu=timestamp,name,utilization.gpu,utilization.memory,memory.total,memory.used,power.draw --format=csv -l 1 > $perf 2>&1 &

if [ $(ps aux | grep [8]010 | grep sglang | wc -l) -gt 0 ]; then
  RUNTIME=sglang
elif [ $(ps aux | grep [8]010 | grep vllm | wc -l) -gt 0 ]; then
  RUNTIME=vllm
elif [ $(ps aux | grep [8]010 | grep lmdeploy | wc -l) -gt 0 ]; then
  RUNTIME=lmdeploy
elif [ $(ps aux | grep tabbyAP[I] | wc -l) -gt 0 ]; then
  RUNTIME=exllamav2
elif [ $(ps aux | grep [t]ritonserver | wc -l) -gt 0 ]; then
  RUNTIME=tritonserver
elif [ $(ps aux | grep [t]ext-generation-server | wc -l) -gt 0 ]; then
  RUNTIME=tgi
elif [ $(ps aux | grep [s]calellm.serve.api_server | wc -l) -gt 0 ]; then
  RUNTIME=scalellm
else
  RUNTIME=unknown
fi
  
## Start the metrics collecting command
if [ "$RUNTIME" = "vllm" ]; then
  metric=result_outputs/${MODEL_NAME}_${SCENARIO}_$(date +"%Y-%m-%d_%H-%M-%S").metric
  nohup sh get-metrics.sh > $metric 2>&1 &
fi

## Define log file
if [ ! -d logs ]; then
  mkdir logs
fi

# If $JOB_ID and $TIMESTAMPE exists, using these 2 variables to make the $log_file
if [ ! -z "$JOB_ID" ] && [ ! -z "$TIMESTAMP" ]; then
  log_file="logs/${TIMESTAMP}.${SCENARIO}-${CONCURRENT_REQUESTS}-${MODEL_NAME}-${JOB_ID}.out"
else
  log_file="logs/$(date +"%Y-%m-%d_%H-%M").${CONCURRENT_REQUESTS}-${CONCURRENCY}-${MODEL_NAME}.out"
fi

###################################################################################################
# Start the benchmark
###################################################################################################

# Uncomment this if running in a docker container
# export RAY_USE_MULTIPROCESSING_CPU_COUNT=1
/data/miniconda3/envs/llmperf/bin/python token_benchmark_ray.py --model $MODEL_NAME \
        --mean-input-tokens $MEAN_INPUT_TOKENS \
        --stddev-input-tokens $STDDEV_INPUT_TOKENS \
        --mean-output-tokens $MEAN_OUTPUT_TOKENS \
        --stddev-output-tokens $STDDEV_OUTPUT_TOKENS \
        --max-num-completed-requests $MAX_REQUESTS \
        --timeout $TIMEOUT \
        --num-concurrent-requests $CONCURRENT_REQUESTS \
        --results-dir "result_outputs" \
        --llm-api openai \
        --additional-sampling-params '{}' > $log_file 2>&1

## Check if benchmark finished successfully
if [ $? -ne 0 ]; then
  echo_error "Benchmark scenario ${SCENARIO} with concurrency $CONCURRENT_REQUESTS for model $MODEL_NAME failed, please check the log file $log_file"
  ## Kill the performance monitoring command
  ps aux | grep [n]vidia-smi | awk '{print $2}' |xargs kill  > /dev/null 2>&1
  ps aux | grep [g]et_metric | awk '{print $2}' |xargs kill  > /dev/null 2>&1
  exit 1
else
  ## Kill the performance monitoring command
  ps aux | grep [n]vidia-smi | awk '{print $2}' |xargs kill  > /dev/null 2>&1
  ps aux | grep [g]et_metric | awk '{print $2}' |xargs kill  > /dev/null 2>&1
fi

## Analyze the results
report=result_outputs/${MODEL_NAME}_${MEAN_INPUT_TOKENS}_${MEAN_OUTPUT_TOKENS}_summary.json
analyze_result

## Output the analysis result
echo "$RUNTIME, $MODEL_NAME, $SCENARIO, $CONCURRENT_REQUESTS, $num_requests, $MEAN_INPUT_TOKENS, $output_tokens_round, $stddev_round, $ttft_mean_ms, $ttft_p99_ms, $itl_mean_ms, $itl_p99_ms, $e2e_mean_ms, $e2e_p99_ms, $tokens_sec_round, $requests_sec_round, $avg_gpu_round, $avg_mem_round, $avg_power_round, $max_kvcache_round, $avg_kvcache_round"
