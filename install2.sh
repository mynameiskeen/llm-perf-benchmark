#!/bin/bash
###################################################################################################
#
#
###################################################################################################

###########################################################################
# ENV settings
#   - CUDA_VERSION, re-install the cuda in this machine to this version.
#   - GITHUB_PROXY, if this is set, git will use this proxy.
#   - TEST_PIPREPO, if this is set, it will test the repo network
#       to get the fastest one.
#
###########################################################################

# Set CUDA version
CUDA_VERSION="12.5"

# Set github.com proxy, hightly recommend to set this if you are in mainland China
GITHUB_PROXY="https://mirror.ghproxy.com"
# Set MLC package url package name.
MLC_LLM="https://github.com/mynameiskeen/llm_benchmark/blob/main/mlc_packages/mlc_llm_nightly_cu122-0.1.dev1440-cp310-cp310-manylinux_2_28_x86_64.whl"
MLC_AI="https://github.com/mynameiskeen/llm_benchmark/blob/main/mlc_packages/mlc_llm_nightly_cu122-0.1.dev1440-cp310-cp310-manylinux_2_28_x86_64.whl"
MLC_LLM_PKG=$(echo $MLC_LLM | awk -F '/' '{print $NF}')
MLC_AI_PKG=$(echo $MLC_AI | awk -F '/' '{print $NF}')
# Combine with $GITHUB_PROXY
[ ! -z $GITHUB_PROXY ] && { MLC_LLM_URL=$GITHUB_PROXY/$MLC_LLM; MLC_AI_URL=$GITHUB_PROXY/$MLC_AI; } || { MLC_LLM_URL=$MLC_LLM; MLC_AI_URL=$MLC_AI; }

# Set if test the pip repository network.
TEST_PIPREPO=Y

###########################################################################
#
# Define functions to output error and logs.
#
###########################################################################

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

###########################################################################
#
# Define a function to test the network speed of pypi repository
# Candidate repositories are:
#   - https://pypi.org/simple
#   - https://mirrors.aliyun.com/pypi/simple/
#   - https://pypi.tuna.tsinghua.edu.cn/simple/
#   - https://pypi.mirrors.ustc.edu.cn/simple/
#
###########################################################################
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
  # Remove conda test env
  echo_log "Removing conda test env ..."
  conda deactivate && conda env remove -n test -y || { echo_error "Failed to remove conda test env."; exit 1; }
  echo_log "Conda env test removed successfully."
  # If $_cache_num is null, means no network speed is greater than MB/s.
  if [ -z $_cache_num ]; then
    echo_error "No repo has the network speed greater than MB/s, this network environment is not good enough."
    exit 1
  else
    echo_log "The fastest repository is $_cache_repo ."
    PYPI_REPO=$_cache_repo
  fi
}

###########################################################################
# 
# Step 1 - Verify the hardware and OS version.
#
#    - Check the GPU model.
#    - Check the OS distribution and version. 
#        Only ubuntu 22.04 is supported
#
###########################################################################


###########################################################################
# 
# Step 2 - Initial the machine:
#
#    - Update and upgrade OS
#    - Install the essential tools
#    - Re-install CUDA to $CUDA_VERSION
#
###########################################################################

###########################################################################
# 
# Step 3 - Install inference engines and benchmark tool
#
#    - 3.1 miniconda
#    - 3.2 vllm
#    - 3.3 lmdeploy
#    - 3.4 mlc-llm
#    - 3.5 exllamav2
#
###########################################################################

echo_log "====================Step 3, Install inference engines and benchmark tool===================="
# Test the network of pip repositories.
if [ "$TEST_PIPREPO" = "Y" ]; then
  get_fastest_repo
  PIP_INSTALL="pip install -i $PYPI_REPO"
else
  PIP_INSTALL="pip install"
fi
echo_log "The python packages will be installed with: ${PIP_INSTALL}."

# Install miniconda
echo_log "--------------------Step 3.1, install miniconda3--------------------"
#echo_log "Installing miniconda3 in /data/miniconda3 ..."
#if [ -d /data/miniconda3 ]; then
#  rm -rf /data/miniconda3
#fi
#mkdir -p /data/miniconda3 && cd /data/miniconda3
#wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /data/miniconda3/miniconda.sh
#if [ $? -eq 0 ]; then
#  bash /data/miniconda3/miniconda.sh -b -u -p /data/miniconda3
#  rm -rf /data/miniconda3/miniconda.sh
#  sed -i 's/\/root\/miniconda3\/bin\://g' /etc/profile
#  /data/miniconda3/bin/conda init bash
#  . ~/.bashrc
#else
#  echo_error "Failed to download miniconda3."
#  exit 1
#fi
echo_log "--------------------Step 3.1, miniconda3 installed successfully--------------------"

# Install vllm
echo_log "--------------------Step 3.2, install vllm inference engine--------------------"
#echo_log "Installing vllm inference engine ... "
#conda create --name vllm python=3.10 -y
#conda activate vllm
#if [ $? -ne 0 ]; then
#  echo_error "Failed to activate vllm"
#  exit 1
#fi
#pip install huggingface_hub && pip install vllm==0.5.3
#if [ $? -eq 0 ]; then
#  echo_log "vllm installed successfully."
#else
#  echo_error "Failed to install vllm."
#  exit 1
#fi
echo_log "--------------------Step 3.2, vllm installed successfully--------------------"

# Install lmdeploy
echo_log "--------------------Step 3.3, install lmdeploy inference engine--------------------"
#echo_log "Installing lmdeploy inference engine ... "
#conda create --name lmdeploy python=3.10 -y
#source activate base && conda activate lmdeploy
#if [ $? -ne 0 ]; then
#  echo_error "conda activate lmdeploy failed."
#  exit 1
#fi
#echo_log "Current conda environment is: $CONDA_DEFAULT_ENV ."
#pip install lmdeploy==0.5.2
#if [ $? -eq 0 ]; then
#  echo_log "lmdeploy installed successfully."
#else
#  echo_error "Failed to install lmdeploy."
#  exit 1
#fi
echo_log "--------------------Step 3.3, lmdeploy installed successfully--------------------"

# Install mlc_llm
echo_log "--------------------Step 3.4, install mlc-llm inference engine--------------------"
echo_log "Creating conda env mlc-llm ... "
conda create -n mlc-llm python=3.10 -y || { echo_error "Conda env: mlc-llm failed to create."; exit 1; }
source activate base && conda activate mlc-llm || { echo_error "conda activate mlc_llm failed."; exit 1; }
echo_log "Current conda environment is: $CONDA_DEFAULT_ENV ."

# Download mlc-llm packages
echo_log "Downloading wheels from github.com ... "
wget $MLC_LLM_URL -O ./$MLC_LLM_PKG --connect-timeout=5 || { echo_error "Failed to download $MLC_LLM_URL"; exit 1; }
wget $MLC_AI_URL -O ./$MLC_AI_PKG --connect-timeout=5 || { echo_error "Failed to download $MLC_AI_URL"; exit 1; }
echo_log "mlc-llm packages download successfully."

# Install mlc-llm packages
echo_log "Installing mlc-llm packages ... "
$PIP_INSTALL --pre ./$MLC_AI_PKG || { echo_error "Failed to install $MLC_AI_PKG ."; exit 1; }
$PIP_INSTALL --pre ./$MLC_LLM_PKG || { echo_error "Failed to install $MLC_LLM_PKG ."; exit 1; }
echo_log "--------------------Step 3.4, mlc-llm installed successfully--------------------"
