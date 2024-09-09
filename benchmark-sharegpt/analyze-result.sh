#!/bin/bash

i=1

# Define keywords
keywords=("Benchmark duration" "Total input tokens" "Total generated tokens" "Mean TTFT" "Median TTFT" "P99 TTFT" "Mean ITL" "Median ITL" "P99 ITL" "Input token throughput" "Output token throughput" "Request throughput")

for str in "${keywords[@]}"
do
    grep "$str" $1 | awk -F':' '{print $2}'|sed 's/ //g' >/tmp/k_$i
    ((i++))
done

# List all the output files
files=$(ls -v /tmp/k_*)

# Combine all results
paste $files | pr -t -e20