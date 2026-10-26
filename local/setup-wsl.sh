#!/usr/bin/env bash
# One-time setup of WSL Ubuntu 24.04 (or any Ubuntu/Debian) for local kernel
# builds with local/build-muyu.sh. Safe to run again.
set -euo pipefail

echo "== Installing packages (sudo password may be asked)"
sudo apt-get update
sudo apt-get install -y \
  git curl wget python3 python3-yaml jq rsync zip unzip xz-utils zstd \
  build-essential bc bison flex cpio perl patch libssl-dev libelf-dev dwarves \
  binutils file gh

# The NoMount metamodule step in CI uses jetsung/setup-zig with version master.
echo "== Installing zig (master build, like CI) to /opt/zig"
ZIG_INDEX="$(curl -fsSL --retry 3 https://ziglang.org/download/index.json)"
ZIG_KEY="$(uname -m)-linux"
ZIG_URL="$(jq -r --arg k "$ZIG_KEY" '.master[$k].tarball' <<< "$ZIG_INDEX")"
ZIG_SHA="$(jq -r --arg k "$ZIG_KEY" '.master[$k].shasum' <<< "$ZIG_INDEX")"
ZIG_TMP="$(mktemp -d)"
curl -fsSL --retry 3 -o "$ZIG_TMP/zig.tar.xz" "$ZIG_URL"
echo "$ZIG_SHA  $ZIG_TMP/zig.tar.xz" | sha256sum -c --quiet -
sudo rm -rf /opt/zig
sudo mkdir -p /opt/zig
sudo tar -xJf "$ZIG_TMP/zig.tar.xz" -C /opt/zig --strip-components=1
sudo ln -sf /opt/zig/zig /usr/local/bin/zig
rm -rf "$ZIG_TMP"

echo "== Creating /home/runner (the CI scripts write their output and Bazel cache there)"
sudo mkdir -p /home/runner
sudo chown "$(id -u):$(id -g)" /home/runner
mkdir -p /home/runner/.cache/bazel

echo "== Checks"
python3 -c 'import yaml; print("python3-yaml ok")'
echo "zig $(zig version)"
if gh auth status >/dev/null 2>&1; then
  echo "gh: logged in (manager APKs can be fetched)"
else
  echo "gh: not logged in; run 'gh auth login' once to get the manager APKs with each build"
fi
free -g | awk 'NR==2 {printf "RAM: %s GB (16+ GB recommended for the kernel link step)\n", $2}'
swapon --show=SIZE --noheadings | awk '{s=s $1 " "} END {print "swap: " (s ? s : "none")}'
df -h "$HOME" | awk 'NR==2 {print "free space in $HOME: " $4 " (about 30-40 GB needed)"}'
echo "done"
