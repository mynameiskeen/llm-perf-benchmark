#!/bin/bash

###################################################################################################
#
# This script is used to prepare the machine and install all the inference engine and tools needed
# for the benchmark.
#
###################################################################################################



###################################################################################################
# ENV settings
###################################################################################################

# Set CUDA version
CUDA_VERSION="12.5"

# set -x
# Define a function to output error messages with red color.
echo_error () {
  RED='\033[0;31m'
  NC='\033[0m'
  echo -e "${RED}$1${NC}"
}

echo_log () {
  GREEN='\033[0;32m'
  NC='\033[0m'
  local _timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
  echo -e "${GREEN}$_timestamp: $1${NC}"
}

# Check GPU model
echo_log "Checking GPU model ... "
if [ -f /proc/driver/nvidia/gpus/*/information ]; then
  GPU_MODEL=$(cat /proc/driver/nvidia/gpus/*/information | grep Model | awk -F 'NVIDIA ' '{print $2}')
  if [ x"$GPU_MODEL" = "x" ]; then
    echo_error "This machine does not have a GPU card!"
    exit 1 
  fi
else
  echo_error "This machine does not have a GPU card!"
  exit 1
fi
echo_log "The GPU model is $GPU_MODEL."

# Check OS version
echo_log "Checking OS distribution and OS version ... "
if [ -f /etc/os-release ]; then
  OS_NAME=$(awk -F= '/^NAME/{print $2}' /etc/os-release | sed 's/"//g')
  OS_VERSION=$(awk -F= '/^VERSION_ID/{print $2}' /etc/os-release | sed 's/"//g')
  if [ "$OS_NAME" != "Ubuntu" ]; then
    echo_error "The OS distribution is not Ubuntu, this script can only run in Ubuntu."
    exit 1
  elif [ "$OS_VERSION" != "22.04" ]; then
    echo_error "The OS version is not 22.04, this sript can only run in 22.04."
    exit 1
  else
    echo_log "OS distribution: $OS_NAME and OS version: $OS_VERSION verified."   
  fi
else
  echo_error "The OS distribution is not Ubuntu, this script can only run in Ubuntu."
  exit 1
fi

# Update and upgrade OS
echo_log "Starting to update and upgrade the OS ... "
apt update -y && DEBIAN_FRONTEND=noninteractive apt upgrade -yq
if [ $? -eq 0 ]; then
  echo_log "The OS has been updated/upgraded"
else
  echo_error "The OS update/upgrade failed."
  exit 1
fi

# Install the essential tools
echo_log "Installing essential tools ... "
apt-get install wget bc jq -y
# Intall yq for parsing yaml file
if ! command -v yq >/dev/null 2>&1 ; then
  wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq &&\
    chmod +x /usr/bin/yq
  if [ $? -ne 0 ]; then
    echo_error "Install yq failed, please check."
    exit 1
  fi
fi
echo_log "Tools wget, bc, jq, yq installed."

# Remove CUDA and re-install ${CUDA_VERSION}
echo_log "Removing current version of CUDA and Nvidia drivers ... "
apt-get purge cuda* -y
apt-get purge libcudnn* -y --allow-change-held-packages
apt-get purge libcublas* -y --allow-change-held-packages
apt-get purge nccl* -y --allow-change-held-packages
apt-get autoremove -y
apt-get autoclean -y
rm -rf /usr/local/cuda*
echo_log "Current verson of CUDA and Nvidia drivers have been removed."

# Re-install
CUDA_TOOLKIT=cuda-toolkit-$(echo $CUDA_VERSION|sed 's/\./-/g')
CUDA_DRIVERS="cuda-drivers-555 nvidia-driver-555-open"
echo_log "Downloading keyring and cuda-repository-pin from nvidia.com ... "
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb
echo "deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/ /" | tee /etc/apt/sources.list.d/cuda-ubuntu2204-x86_64.list
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-ubuntu2204.pin
mv cuda-ubuntu2204.pin /etc/apt/preferences.d/cuda-repository-pin-600
echo_log "Download keyring and cuda-repository-pin done."
apt-get update -y
echo_log "Re-installing $CUDA_TOOLKIT ... "
apt-get install $CUDA_TOOLKIT -y
if [ $? -ne 0 ]; then
  echo_error "Install $CUDA_TOOLKIT failed, please check."
fi
echo_log "Re-install $CUDA_TOOLKIT done."

# Install 
