#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/$(basename "${BASH_SOURCE[0]}")"
srcroot="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"

# Pin a Zig-linkable Xcode for `zig build`'s SDK lookups (see select-developer-dir.sh).
# Always delegate so an inherited DEVELOPER_DIR is validated, not trusted blindly.
# Plain assignment, separate export, so a selector failure aborts under set -e.
DEVELOPER_DIR="$("${script_dir}/select-developer-dir.sh")"
export DEVELOPER_DIR
repo_root="${srcroot}"
zmx_dir="${srcroot}/ThirdParty/zmx"
zmx_submodule_path="${zmx_dir#"${repo_root}/"}"
zmx_build_root="${srcroot}/.build/zmx"
zmx_global_cache_dir="${zmx_build_root}/.zig-global-cache"
zmx_fingerprint_path="${zmx_build_root}/fingerprint"
zmx_binary_path="${zmx_build_root}/bin/zmx"

# zmx (and the ghostty 1.3.x it vendors) require Zig 0.15.x, which differs
# from the 0.14.1 pinned in mise.toml for the vendored ghostty v1.2.3. Pin the
# toolchain explicitly so the two never interfere with each other's caches.
zmx_zig_version="0.15.2"

# zmx's build.zig.zon depends on ghostty via `git+https://github.com/...`.
# Zig's built-in git client cannot use the local proxy for github.com, so the
# build script swaps that URL for a local `git+http://127.0.0.1:PORT` mirror
# (served from a bare clone of the upstream repo) by applying this patch for
# the duration of the build and reverting it afterwards.
zmx_patch_path="${srcroot}/patches/zmx-local-ghostty-mirror.patch"
ghostty_mirror_path="${srcroot}/.build/ghostty-upstream.git"
ghostty_mirror_commit="c74f6d56d1feef473033057bc0ff7e3f00cf6421"
git_http_port="8765"
git_http_script="${script_dir}/git-http-server.py"
git_http_server_pid=""

# Mirror Xcode's ARCHS_STANDARD for macOS (arm64, x86_64); resync if Configurations/Project.xcconfig pins ARCHS.
# Unconditional: every build emits both slices regardless of CONFIGURATION / ONLY_ACTIVE_ARCH.
zmx_targets=(
  "x86_64-macos"
  "aarch64-macos"
)

print_fingerprint() {
  (
    cd "${zmx_dir}"
    {
      git rev-parse HEAD
      git diff --no-ext-diff --no-color HEAD -- . | shasum -a 256
      git ls-files --others --exclude-standard | LC_ALL=C sort | shasum -a 256
      shasum -a 256 "${script_path}" | awk '{print $1}'
      shasum -a 256 "${srcroot}/mise.toml" | awk '{print $1}'
      shasum -a 256 "${zmx_patch_path}" | awk '{print $1}'
      shasum -a 256 "${git_http_script}" | awk '{print $1}'
    } | shasum -a 256 | awk '{print $1}'
  )
}

ensure_ghostty_mirror() {
  if [ -d "${ghostty_mirror_path}" ] &&
    git --git-dir="${ghostty_mirror_path}" cat-file -t "${ghostty_mirror_commit}" >/dev/null 2>&1; then
    return
  fi

  echo "info: cloning ghostty upstream mirror (one-time; needs proxy on 127.0.0.1:7890)"
  rm -rf "${ghostty_mirror_path}"
  git \
    -c http.proxy=http://127.0.0.1:7890 \
    -c https.proxy=http://127.0.0.1:7890 \
    clone --bare --single-branch --no-tags \
    https://github.com/ghostty-org/ghostty.git \
    "${ghostty_mirror_path}"

  if ! git --git-dir="${ghostty_mirror_path}" cat-file -t "${ghostty_mirror_commit}" >/dev/null 2>&1; then
    echo "error: ghostty mirror is missing commit ${ghostty_mirror_commit}" >&2
    exit 1
  fi
}

ensure_git_http_server() {
  if curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:${git_http_port}/" 2>/dev/null; then
    return
  fi
  GIT_PROJECT_ROOT="${srcroot}/.build" \
    python3 "${git_http_script}" "${git_http_port}" >"${zmx_build_root}/git-http-server.log" 2>&1 &
  git_http_server_pid=$!
  for _ in $(seq 1 50); do
    if curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:${git_http_port}/" 2>/dev/null; then
      return
    fi
    sleep 0.1
  done
  echo "error: git http server failed to start (see ${zmx_build_root}/git-http-server.log)" >&2
  exit 1
}

apply_zmx_patch() {
  (
    cd "${zmx_dir}"
    if ! git apply --check "${zmx_patch_path}" 2>/dev/null; then
      git apply "${zmx_patch_path}"
    fi
  )
}

revert_zmx_patch() {
  (
    cd "${zmx_dir}"
    if git apply --reverse --check "${zmx_patch_path}" 2>/dev/null; then
      git apply --reverse "${zmx_patch_path}"
    fi
  )
}

cleanup() {
  revert_zmx_patch 2>/dev/null || true
  if [ -n "${git_http_server_pid}" ]; then
    kill "${git_http_server_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

ensure_zmx_checkout() {
  if [ -f "${zmx_dir}/build.zig" ]; then
    return
  fi

  git -C "${repo_root}" submodule sync --recursive -- "${zmx_submodule_path}"
  git -C "${repo_root}" submodule update --init --recursive -- "${zmx_submodule_path}"

  if [ ! -f "${zmx_dir}/build.zig" ]; then
    echo "error: missing ${zmx_dir} after submodule update" >&2
    exit 1
  fi
}

ensure_zmx_checkout

if [ "${1:-}" = "--print-fingerprint" ]; then
  print_fingerprint
  exit 0
fi

fingerprint="$(print_fingerprint)"

mkdir -p "${zmx_build_root}"
rm -rf "${zmx_build_root}/.zig-cache"

if [ -f "${zmx_fingerprint_path}" ] &&
  [ -x "${zmx_binary_path}" ] &&
  [ "$(cat "${zmx_fingerprint_path}")" = "${fingerprint}" ]; then
  exit 0
fi

cd "${zmx_dir}"

ensure_ghostty_mirror
ensure_git_http_server
apply_zmx_patch

slice_paths=()
for target in "${zmx_targets[@]}"; do
  slice_prefix="${zmx_build_root}/slices/${target}"
  slice_cache="${slice_prefix}/.zig-cache"
  slice_binary="${slice_prefix}/bin/zmx"
  mise exec zig@"${zmx_zig_version}" -- zig build \
    -Doptimize=ReleaseSafe \
    -Dtarget="${target}" \
    --prefix "${slice_prefix}" \
    --cache-dir "${slice_cache}" \
    --global-cache-dir "${zmx_global_cache_dir}"
  if [ ! -x "${slice_binary}" ]; then
    echo "error: zmx build produced no binary at ${slice_binary} for target ${target}" >&2
    exit 1
  fi
  slice_paths+=("${slice_binary}")
done

mkdir -p "$(dirname "${zmx_binary_path}")"
lipo -create "${slice_paths[@]}" -output "${zmx_binary_path}"

# Defense in depth: -verify_arch fails closed on a partial / thin lipo output, but exits silently.
if ! lipo "${zmx_binary_path}" -verify_arch x86_64 arm64; then
  echo "error: zmx universal binary at ${zmx_binary_path} is missing x86_64 or arm64 slice" >&2
  exit 1
fi

printf '%s\n' "${fingerprint}" > "${zmx_fingerprint_path}"
