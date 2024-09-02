#!/bin/bash

# Define a function to output error messages with red color.
echo_error () {
  RED='\033[0;31m'
  NC='\033[0m'
  echo -e "${RED}$1${NC}"
}

echo_log () {
  GREEN='\033[0;32m'
  NC='\033[0m'
  local _timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo -e "${GREEN}$_timestamp - $1${NC}"
}

# set -x
get_fastest_repo () {

  _official_repo="https://pypi.org/simple"
  _aliyun_repo="https://mirrors.aliyun.com/pypi/simple/"
  _tsinghua_repo="https://pypi.tuna.tsinghua.edu.cn/simple/"
  _ustc_repo="https://pypi.mirrors.ustc.edu.cn/simple/"

  echo_log "Creating a conda env for testing repository network speed ... "
  conda create --name test python=3.10 -y >/dev/null
  source activate base >/dev/null&& conda activate test >/dev/null
  echo_log "Conda env test created."

  for _repo in $_official_repo $_aliyun_repo $_tsinghua_repo $_ustc_repo
  do
    echo_log "Testing network speed for $_repo ..."
    # Start the pip install in the background
    pip install --root-user-action=ignore -i $_repo numpy > /tmp/pip.log &
    _pid=$!
    # If download takes more than 15 seconds, kill it.
    for (( i=1; i<=15; i++ ))
    do
      if ps -ef|grep $_pid | grep -v grep >/dev/null 2>&1 ; then
        sleep 1
        [ $i -eq 15 ] && { kill $_pid; echo_error "Pip install numpy with $_repo didn't finished within 15 seconds, kill it."; }
      else
        break
      fi
    done
    # Check download speed
    _speed_num=$(cat /tmp/pip.log | grep "\.whl " -A 1 | tail -1 | awk -F 'MB ' '{print $2}'|awk '{print $1}')
    _speed_unit=$(cat /tmp/pip.log | grep "\.whl " -A 1 | tail -1 | awk -F 'MB ' '{print $2}'|awk '{print $2}')
    _speed_num=${_speed_num:-0}
    _speed_unit=${_speed_unit:-na}
    echo_log "Repository: $_repo speed is: $_speed_num $_speed_unit"
    # Get the fastest repo
    # If unit is "MB/s", compare the $_speed_num with the $_cache_num
    # Keep the first $_speed_num in $_cache_num, if $_speed_unit is "MB/s"
    # If $_cache_num exists, compare $_speed_num with $_cache_num and set the greater one into $_cache_num
    if [ ${_speed_unit} = "MB/s" ]; then
      if [ -z $_cache_num ]; then
        _cache_num=${_speed_num}
        _cache_repo=$_repo
      elif (( $( echo "$_speed_num > $_cache_num" | bc -l) )); then
        _cache_num=${_speed_num}
        _cache_repo=$_repo
      fi
    fi  
    if pip list | grep numpy > /dev/null ; then
      echo_log "Uninstall numpy and purge the pip cache for the next testing."
      pip uninstall --root-user-action=ignore numpy -y >/dev/null
      pip cache purge >/dev/null
    fi
  done
  # If $_cache_num is null, means no network speed is greater than MB/s.
  if [ -z $_cache_num ]; then
    echo_error "No repo has the network speed greater than MB/s, this network environment is not good enough."
    exit 1
  else
    echo_log "The fastest repository is $_cache_repo ."
    echo "$_cache_repo"
  fi
}

get_fastest_repo
