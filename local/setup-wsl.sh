#!/usr/bin/env bash
# One-time setup of WSL Ubuntu 24.04 (or any Ubuntu/Debian) for local kernel
# builds with local/build-muyu.sh. Safe to run again.
set -euo pipefail

echo "== Installing packages (sudo password may be asked)"
sudo apt-get update
sudo apt-get install -y \
  git curl wget python3 python3-yaml jq rsync zip unzip xz-utils zstd \
  build-essential bc bison flex cpio perl patch libssl-dev libelf-dev dwarves \
  binutils file

echo "== Creating /home/runner (the CI scripts write their output and Bazel cache there)"
sudo mkdir -p /home/runner
sudo chown "$(id -u):$(id -g)" /home/runner
mkdir -p /home/runner/.cache/bazel

echo "== Checks"
python3 -c 'import yaml; print("python3-yaml ok")'
free -g | awk 'NR==2 {printf "RAM: %s GB (16+ GB recommended for the kernel link step)\n", $2}'
swapon --show=SIZE --noheadings | awk '{s=s $1 " "} END {print "swap: " (s ? s : "none")}'
df -h "$HOME" | awk 'NR==2 {print "free space in $HOME: " $4 " (about 30-40 GB needed)"}'
echo "done"
