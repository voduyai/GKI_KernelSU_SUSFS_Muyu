#!/usr/bin/env bash
# Build the Xiaomi Pad 7 Pro (muyu) kernel on this machine (WSL/Linux),
# running the same steps as "Build muyu (Xiaomi Pad 7 Pro)" on GitHub.
#
#   ./local/build-muyu.sh                build, keep the workspace for inspection
#   ./local/build-muyu.sh --clean        build, then delete the workspace (keeps the zip)
#   ./local/build-muyu.sh --dry-run      only list which workflow steps would run
#   ./local/build-muyu.sh --gki 2026-09  build another android14-6.1 GKI release
#                                        (default 2025-06 = muyu stock, tag _r15)
#   ./local/build-muyu.sh --kernel-only  skip the NoMount metamodule and manager APKs
#
# Like main.yml, a build also produces the NoMount metamodule (needs zig) and
# fetches the KernelSU-Next manager APKs (needs `gh auth login`).
# Settings below mirror .github/workflows/muyu.yml. Paths can be changed with
# MUYU_BUILD_DIR (workspace + logs) and MUYU_OUT_DIR (finished zips + APKs).
set -euo pipefail

# ---- settings (keep in sync with .github/workflows/muyu.yml) ---------------
VERSION="android14-6.1"
ANDROID_VERSION="android14"
KERNEL_VERSION="6.1"
OS_PATCH_LEVEL="2025-06"  # 6.1.138, pinned to r15 by the muyu branch; --gki picks another
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
EXTRAS=true
while [ $# -gt 0 ]; do
  case "$1" in
    --clean) CLEAN=true ;;
    --dry-run) DRY=true ;;
    --kernel-only) EXTRAS=false ;;
    --gki) [ $# -ge 2 ] || { echo "--gki needs a date, e.g. --gki 2026-09" >&2; exit 2; }
           OS_PATCH_LEVEL="$2"; shift ;;
    --gki=*) OS_PATCH_LEVEL="${1#--gki=}" ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
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
# repo walks up from the kernel dir looking for .repo; a stray one above the
# workspace (e.g. ~/.repo) gets reused and the source is synced there instead.
d="$WS"
while d="$(dirname "$d")"; [ "$d" != / ]; do
  [ -e "$d/.repo" ] && die "found $d/.repo above the workspace; repo would sync the kernel into $d instead of $WS/kernel.
  Remove that old checkout (or set MUYU_BUILD_DIR somewhere else) and run again."
done
# Extras never fail the kernel build, so only warn here and say how to fix it.
export GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}"
if $EXTRAS; then
  [[ " $FEATURES " == *" NoMount "* ]] && ! command -v zig >/dev/null &&
    warn "zig not found, the NoMount metamodule will be skipped; run local/setup-wsl.sh again"
  [ -n "$GITHUB_TOKEN" ] ||
    warn "not logged in to GitHub, the manager APKs will be skipped; run: gh auth login"
fi

# The sublevel for each GKI release comes from the same matrix main.yml uses.
# Entries with a variant (other kernel source) or "lts" are not muyu builds.
GKI_MATRIX="$REPO_DIR/.github/config/$VERSION.json"
SUBLEVEL="$(jq -r --arg d "$OS_PATCH_LEVEL" \
  'first(.include[] | select(.date == $d and .variant == null and .sublevel != "X") | .sublevel) // empty' "$GKI_MATRIX")"
[ -n "$SUBLEVEL" ] || die "no $VERSION GKI release '$OS_PATCH_LEVEL' in ${GKI_MATRIX#$REPO_DIR/}. Available:
  $(jq -r '[.include[] | select(.variant == null and .sublevel != "X") | "\(.date)=6.1.\(.sublevel)"] | join(" ")' "$GKI_MATRIX")"

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

# ---- NoMount metamodule (main.yml: build-nomount-module) --------------------
# Runs the same composite action through ghrun. Its setup-zig step is a remote
# action that ghrun skips, so zig comes from PATH (local/setup-wsl.sh).
build_nomount() {
  command -v zig >/dev/null || { warn "zig not found; run local/setup-wsl.sh again"; return 1; }
  cat > "$WS/.ghrun-nomount.yml" <<'EOF'
on:
  workflow_call:
    inputs:
      commit:
        type: string
jobs:
  nomount:
    steps:
      - name: Build NoMount metamodule (nm only, no .ko)
        uses: ./.github/actions/nomount-metamodule
        with:
          commit: ${{ inputs.commit }}
EOF
  jq -n --arg c "$NOMOUNT_COMMIT" '{commit: $c}' > "$BUILD_DIR/nomount-inputs.json"
  rm -rf "$WS/.ghrun/nomount-module-source" "$WS/.ghrun/nomount-metamodule"
  (cd "$WS" && python3 "$REPO_DIR/local/ghrun.py" --workflow .ghrun-nomount.yml --job nomount \
    --inputs "$BUILD_DIR/nomount-inputs.json" --workspace "$WS" --repository voduyai/GKI_KernelSU_SUSFS_Muyu) 2>&1 | tee -a "$LOG"
  [ "${PIPESTATUS[0]}" = 0 ] || return 1
  local src="$WS/.ghrun/NoMount-$NOMOUNT_COMMIT.zip"
  [ -f "$src" ] || { warn "NoMount action finished without $src"; return 1; }
  NOMOUNT_ZIP="$OUT_DIR/NoMount-Metamodule-${NOMOUNT_COMMIT:0:12}.zip"
  cp -f "$src" "$NOMOUNT_ZIP"
  echo "  $(grep -m1 '^version=' "$WS/.ghrun/nomount-metamodule/module.prop" || true)"
  echo "  zip: $NOMOUNT_ZIP"
}

# ---- KernelSU-Next manager APKs (main.yml: resolve-sources + list-manager-apks)
# The manager is never built from source: main.yml takes the "manager" and
# "manager-spoofed" artifacts of the official build-manager-ci run for the
# KernelSU-Next dev tip, or the latest successful dev run when that tip has none.
gh_api() {
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
    -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" "https://api.github.com/$1"
}
fetch_manager() {
  [ -n "$GITHUB_TOKEN" ] || { warn "not logged in to GitHub; run: gh auth login"; return 1; }
  local repo="KernelSU-Next/KernelSU-Next" wf="build-manager-ci.yml" mgr_sha="$KSU_BRANCH"
  local run_id fb arts dl="$BUILD_DIR/manager" aid art apk name got=0
  run_id="$(gh_api "repos/$repo/actions/workflows/$wf/runs?head_sha=$mgr_sha&status=success" | jq -r '.workflow_runs[0].id // empty')" || return 1
  if [ -z "$run_id" ]; then
    echo "  no manager build for dev tip $mgr_sha, falling back to latest successful run"
    fb="$(gh_api "repos/$repo/actions/workflows/$wf/runs?branch=dev&status=success&per_page=1")" || return 1
    run_id="$(jq -r '.workflow_runs[0].id // empty' <<< "$fb")"
    mgr_sha="$(jq -r '.workflow_runs[0].head_sha // empty' <<< "$fb")"
    [ -n "$run_id" ] || { warn "no successful $wf run on dev"; return 1; }
  fi
  echo "  KernelSU-Next $mgr_sha, run https://github.com/$repo/actions/runs/$run_id"
  arts="$(gh_api "repos/$repo/actions/runs/$run_id/artifacts" |
    jq -r '.artifacts[] | select(.name == "manager" or .name == "manager-spoofed") | "\(.id) \(.name)"')" || return 1
  rm -rf "$dl"
  mkdir -p "$dl"
  while read -r aid art; do
    [ -n "$aid" ] || continue
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -H "Authorization: Bearer $GITHUB_TOKEN" \
      -o "$dl/$aid.zip" "https://api.github.com/repos/$repo/actions/artifacts/$aid/zip" || return 1
    unzip -o -q "$dl/$aid.zip" -d "$dl/$aid" || return 1
    for apk in "$dl/$aid"/*.apk; do
      [ -f "$apk" ] || continue
      name="$(basename "$apk")"
      # same rule as main.yml: a spoofed artifact must not overwrite the stock APK
      case "$art" in *poofed*) case "$name" in *poofed*) ;; *) name="${name%.apk}-spoofed.apk" ;; esac ;; esac
      cp -f "$apk" "$OUT_DIR/$name"
      echo "  apk: $OUT_DIR/$name"
      got=$((got + 1))
    done
  done <<< "$arts"
  [ "$got" -gt 0 ] || { warn "run $run_id has no manager APKs (artifacts expired?)"; return 1; }
}

SKIPPED=()
if $EXTRAS; then
  if [[ " $FEATURES " == *" NoMount "* ]]; then
    say "Building NoMount metamodule ($NOMOUNT_COMMIT)"
    build_nomount || SKIPPED+=("NoMount metamodule")
  fi
  say "Fetching KernelSU-Next manager APKs"
  fetch_manager || SKIPPED+=("manager APKs")
fi

if $CLEAN; then
  say "Cleaning workspace"
  rm -rf "$WS" /home/runner/out
fi
say "Done: $OUT_DIR"
[ ${#SKIPPED[@]} = 0 ] || warn "kernel built, but without: ${SKIPPED[*]} (see messages above)"
