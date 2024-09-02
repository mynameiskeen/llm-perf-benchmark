#!/bin/bash

###################################################################################################
# 
#
###################################################################################################

# Get metrics for vllm
METRICS_URL=http://localhost:8010/metrics
METRICS_NM="num_requests_running|num_requests_waiting|gpu_cache_usage_perc|avg_prompt_throughput_toks_per_s|avg_generation_throughput_toks_per_s"

# Curl to get metrics
while true
do
  METRICS=$(curl -s $METRICS_URL | grep -E $METRICS_NM | grep -v "#" | awk '{print $2}'| tr '\n' ' ')
  TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
  echo "$TIMESTAMP $METRICS"
  sleep 5
done
