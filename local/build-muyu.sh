#!/usr/bin/env bash
# Build the Xiaomi Pad 7 Pro (muyu) kernel on this machine (WSL/Linux),
# running the same steps as "Build muyu (Xiaomi Pad 7 Pro)" on GitHub.
#
#   ./local/build-muyu.sh            build, keep the workspace for inspection
#   ./local/build-muyu.sh --clean    build, then delete the workspace (keeps the zip)
#   ./local/build-muyu.sh --dry-run  only list which workflow steps would run
#
# Settings below mirror .github/workflows/muyu.yml. Paths can be changed with
# MUYU_BUILD_DIR (workspace + logs) and MUYU_OUT_DIR (finished zips).
set -euo pipefail

# ---- settings (keep in sync with .github/workflows/muyu.yml) ---------------
VERSION="android14-6.1"
ANDROID_VERSION="android14"
KERNEL_VERSION="6.1"
SUBLEVEL="138"            # matrix entry 6.1.138 / 2025-06 (pinned to r15 by the muyu branch)
OS_PATCH_LEVEL="2025-06"
PAGE_SIZE="4k"
BRAND_NAME="stock"
FEATURES="SUSFS NoMount BBG NET DS NTSync Ptrace Unicode BPF"   # drop a word to disable it
NOMOUNT_MODE="latest"     # latest = maxsteeel/nomount dev tip, verified = WildKernels pin
ALLOW_VERSION_MISMATCH=false
# Root: KernelSU-Next only. With SUSFS it uses pershoot/KernelSU-Next dev-susfs,
# without SUSFS KernelSU-Next/KernelSU-Next dev, exactly like main.yml.
# ----------------------------------------------------------------------------

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${MUYU_BUILD_DIR:-$HOME/muyu-build}"
WS="$BUILD_DIR/workspace"
OUT_DIR="${MUYU_OUT_DIR:-/mnt/d/Muyu/builds/local}"
CLEAN=false
DRY=false
for a in "$@"; do
  case "$a" in
    --clean) CLEAN=true ;;
    --dry-run) DRY=true ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---- preflight --------------------------------------------------------------
for t in git curl python3 jq rsync zip; do command -v "$t" >/dev/null || die "$t missing; run local/setup-wsl.sh first"; done
python3 -c 'import yaml' 2>/dev/null || die "python3-yaml missing; run local/setup-wsl.sh first"
[ -w /home/runner ] || die "/home/runner is not writable; run local/setup-wsl.sh first"
# A checkout made by Git for Windows (core.autocrlf=true) has CRLF line endings,
# which break every bash step. Use a clone made inside WSL instead.
if grep -q $'\r' "$REPO_DIR/.github/workflows/build.yml"; then
  die "this checkout has Windows (CRLF) line endings. Clone the repo inside WSL and run it from there:
  git clone https://github.com/voduyai/GKI_KernelSU_SUSFS_Muyu.git ~/GKI_KernelSU_SUSFS_Muyu"
fi

sha() { # repo ref -> sha (retry, github can be flaky)
  local s="" n
  for n in 1 2 3 4 5; do
    s="$(git ls-remote "$1" "$2" | cut -f1 | head -n1)" && [ -n "$s" ] && { echo "$s"; return; }
    sleep $((n * 5))
  done
  die "could not resolve $2 of $1"
}

# ---- resolve sources the way main.yml does ----------------------------------
say "Resolving source commits"
has() { [[ " $FEATURES " == *" $1 "* ]]; }
if has SUSFS; then
  ROOT_COMMIT="$(sha https://github.com/pershoot/KernelSU-Next.git refs/heads/dev-susfs)"
else
  ROOT_COMMIT="$(sha https://github.com/KernelSU-Next/KernelSU-Next.git refs/heads/dev)"
fi
KSU_BRANCH="$(sha https://github.com/KernelSU-Next/KernelSU-Next.git refs/heads/dev)"
if [ "$NOMOUNT_MODE" = "latest" ]; then
  NOMOUNT_COMMIT="$(sha https://github.com/maxsteeel/nomount.git refs/heads/dev)"
else
  NOMOUNT_COMMIT="$(grep -oP 'PIN_NOMOUNT="\K[0-9a-f]{40}' "$REPO_DIR/.github/workflows/main.yml" | head -n1)"
fi
SUSFS_PIN="$(grep -oP '\[susfs_commit_android14_6_1\]="\K[0-9a-f]{40}' "$REPO_DIR/.github/workflows/main.yml" | head -n1 || true)"
KERNEL_PATCHES_COMMIT="$(sha https://github.com/WildKernels/kernel_patches.git refs/heads/main)"
ANYKERNEL3_COMMIT="$(sha https://github.com/WildKernels/AnyKernel3.git refs/heads/gki-2.0)"
DROIDSPACES_COMMIT="$(sha https://github.com/ravindu644/Droidspaces-OSS.git refs/heads/main)"

FEATURE_SET=""
for f in SUSFS NoMount BBG NET DS NTSync Ptrace Unicode BPF Perf; do has "$f" && FEATURE_SET+="$f+"; done
FEATURE_SET="${FEATURE_SET%+}"

cat <<EOF
  kernel        : $VERSION $KERNEL_VERSION.$SUBLEVEL ($OS_PATCH_LEVEL), $PAGE_SIZE, brand=$BRAND_NAME
  features      : ${FEATURE_SET:-none}
  KernelSU-Next : $ROOT_COMMIT
  NoMount       : $NOMOUNT_COMMIT ($NOMOUNT_MODE)
  kernel_patches: $KERNEL_PATCHES_COMMIT
  AnyKernel3    : $ANYKERNEL3_COMMIT
  DroidSpaces   : $DROIDSPACES_COMMIT
  workspace     : $WS
EOF

# ---- fresh workspace: a copy of this repo -----------------------------------
say "Preparing workspace"
mkdir -p "$BUILD_DIR"
rm -rf "$WS"
mkdir -p "$WS"
git -C "$REPO_DIR" ls-files -z | rsync -a --from0 --files-from=- "$REPO_DIR/" "$WS/"
rm -rf /home/runner/out
mkdir -p /home/runner/.cache/bazel

INPUTS="$BUILD_DIR/inputs.json"
jq -n \
  --arg version "$VERSION" --arg android_version "$ANDROID_VERSION" --arg kernel_version "$KERNEL_VERSION" \
  --arg sublevel "$SUBLEVEL" --arg os_patch_level "$OS_PATCH_LEVEL" --arg feature_set "$FEATURE_SET" \
  --arg ksu_branch "$KSU_BRANCH" --arg susfs_commit "$SUSFS_PIN" --arg root_commit "$ROOT_COMMIT" \
  --arg nomount_commit "$NOMOUNT_COMMIT" --arg kernel_patches_commit "$KERNEL_PATCHES_COMMIT" \
  --arg anykernel3_commit "$ANYKERNEL3_COMMIT" --arg droidspaces_commit "$DROIDSPACES_COMMIT" \
  --arg brand_name "$BRAND_NAME" --arg page_size "$PAGE_SIZE" --argjson allow "$ALLOW_VERSION_MISMATCH" \
  '{version:$version, android_version:$android_version, kernel_version:$kernel_version, sublevel:$sublevel,
    os_patch_level:$os_patch_level, variant:"KernelSU-Next", feature_set:$feature_set, ksu_branch:$ksu_branch,
    susfs_commit:$susfs_commit, root_flavor:"next", root_commit:$root_commit, nomount_commit:$nomount_commit,
    kernel_patches_commit:$kernel_patches_commit, anykernel3_commit:$anykernel3_commit,
    droidspaces_commit:$droidspaces_commit, brand_name:$brand_name, keep_kmi:false,
    allow_version_mismatch:$allow, use_cache:false, page_size:$page_size, stock_config_artifact:""}' > "$INPUTS"

# ---- run the CI job ---------------------------------------------------------
say "Running .github/workflows/build.yml (build-gki)"
LOG="$BUILD_DIR/build-$(date +%Y%m%d-%H%M%S).log"
export GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}"
RUN_ARGS=(--workflow .github/workflows/build.yml --job build-gki --inputs "$INPUTS" --workspace "$WS"
  --repository voduyai/GKI_KernelSU_SUSFS_Muyu
  --skip-step "Write Build-verified only artifact metadata")
$DRY && RUN_ARGS+=(--dry-run)
set +e
(cd "$WS" && python3 "$REPO_DIR/local/ghrun.py" "${RUN_ARGS[@]}") 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
echo "log: $LOG"
[ "$rc" = 0 ] || die "build failed (exit $rc); see $LOG"
$DRY && exit 0

# ---- package ----------------------------------------------------------------
say "Packaging AnyKernel3"
[ -f "$WS/AnyKernel3/Image" ] || die "no Image in $WS/AnyKernel3"
mkdir -p "$OUT_DIR"
VER="$(strings "$WS/AnyKernel3/Image" | grep -m1 '^Linux version' || true)"
ZIP="$OUT_DIR/6.1.$SUBLEVEL-android14-$OS_PATCH_LEVEL-KernelSU-Next-AnyKernel3-local-$(date +%Y%m%d-%H%M).zip"
(cd "$WS/AnyKernel3" && zip -qr9 "$ZIP" . -x '.git*' -x 'README.md')
echo "  $VER"
echo "  zip: $ZIP"
echo "  NoMount metamodule: build it on GitHub or grab the matching release from https://github.com/maxsteeel/nomount/releases"

if $CLEAN; then
  say "Cleaning workspace"
  rm -rf "$WS" /home/runner/out
fi
say "Done"
