#!/usr/bin/env bash
# Local packaging: build an unsigned Release archive, sign it with the local
# Apple Development identity, and install it to /Applications. No tag, no push,
# no GitHub Actions release, no notarization.
#
# This is the single entry point for docs/local-packaging.md - it performs every
# step the doc described by hand.
#
# Usage: scripts/install-local.sh [--no-build] [--no-launch] [--no-cleanup] [--help]
#
# Options:
#   --no-build    Skip `make archive`; re-sign the existing build/supacode.xcarchive.
#   --no-launch   Skip the startup smoke test (open + pgrep).
#   --no-cleanup  Do not restore Tuist/Package.resolved and supacode.json via git checkout.
#
# Environment overrides:
#   APPLE_TEAM_ID / DEVELOPER_ID_IDENTITY_SHA  passed through to `make archive` when set
#   (not required: the local flow never triggers the Developer ID path).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

do_build=true
do_launch=true
do_cleanup=true

archive_path="${repo_root}/build/supacode.xcarchive"
app_bundle="${archive_path}/Products/Applications/supacode.app"
install_dst="/Applications/supacode.app"

usage() {
  cat <<'EOF'
Usage: scripts/install-local.sh [options]

Builds an unsigned Release archive, signs it with the local Apple Development
certificate, installs it to /Applications, verifies it launches, and restores
the workspace files the build touched (docs/local-packaging.md).

Options:
  --no-build    Skip `make archive`; re-sign build/supacode.xcarchive as-is.
  --no-launch   Do not open the app after installing.
  --no-cleanup  Do not `git checkout -- Tuist/Package.resolved supacode.json`.
  -h, --help    Show this help.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

note() {
  printf '\n==> %s\n' "$*"
}

ok() {
  printf '  \033[32m✔\033[0m %s\n' "$*"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-build)
      do_build=false
      shift
      ;;
    --no-launch)
      do_launch=false
      shift
      ;;
    --no-cleanup)
      do_cleanup=false
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1 (try --help)"
      ;;
  esac
done

cd "$repo_root"

# ---------------------------------------------------------------------------
# Step 0: preflight - doctor + Apple Development codesigning identity
# ---------------------------------------------------------------------------
note "Preflight: build prerequisites"
"${script_dir}/doctor.sh" --quiet || fail "build prerequisites not met: run \`make doctor\` and fix every failure"

note "Locating an Apple Development codesigning identity"
identity="$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | awk '{print $2}' || true)"
if [ -n "${identity}" ]; then
  identity_desc="$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]*[0-9A-F]+[[:space:]]*//')"
  ok "using ${identity} (${identity_desc})"
else
  fail "no Apple Development codesigning identity in the keychain; run \`security find-identity -v -p codesigning\` and see docs/local-packaging.md"
fi

# ---------------------------------------------------------------------------
# Step 2: build the unsigned Release archive
# ---------------------------------------------------------------------------
if [ "${do_build}" = true ]; then
  note "Building the Release archive without signing (this regenerates the workspace and clears DerivedData; first compile is slow)"
  make archive XCODEBUILD_FLAGS="CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO"
else
  note "Skipping the build (--no-build); reusing ${archive_path}"
fi

if [ ! -d "${app_bundle}" ]; then
  fail "app bundle not found at ${app_bundle}; run without --no-build"
fi

note "Archive versions"
plutil -p "${app_bundle}/Contents/Info.plist" | grep -E "CFBundleShortVersionString|CFBundleVersion"

# ---------------------------------------------------------------------------
# Step 3: sign. The archive was built unsigned, so there is no entitlement
# metadata to preserve; the main app gets them injected explicitly. Deepest
# nested code first, main app last (same shape as
# .github/scripts/resign_exported_app.sh). Resources/git-wt/wt is a plain bash
# script and is sealed by the main app's signature, so it needs no codesign.
# ---------------------------------------------------------------------------
note "Signing (deepest-first, local identity, runtime + timestamp, no notarization)"
find "${app_bundle}" -name "*.cstemp" -delete

sparkle_b="${app_bundle}/Contents/Frameworks/Sparkle.framework/Versions/B"

sign_nested() {
  printf '  signing %s\n' "$1"
  codesign -f -s "${identity}" -o runtime --timestamp "$1"
}

sign_nested "${sparkle_b}/Updater.app"
sign_nested "${sparkle_b}/XPCServices/Downloader.xpc"
sign_nested "${sparkle_b}/XPCServices/Installer.xpc"
sign_nested "${sparkle_b}/Autoupdate"
sign_nested "${app_bundle}/Contents/Resources/bin/supacode"
sign_nested "${app_bundle}/Contents/Resources/zmx/zmx"
sign_nested "${sparkle_b}/Sparkle"
sign_nested "${app_bundle}/Contents/Frameworks/Sparkle.framework"

printf '  signing %s (with Release entitlements)\n' "${app_bundle}"
codesign -f -s "${identity}" -o runtime --timestamp \
  --entitlements "${repo_root}/supacode/supacode.entitlements" \
  "${app_bundle}"

# ---------------------------------------------------------------------------
# Step 4: verify the signature
# ---------------------------------------------------------------------------
note "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "${app_bundle}"
codesign -dv "${app_bundle}" 2>&1 | grep -E "TeamIdentifier|flags|Signed Time" || true
printf '  (note: spctl rejects this by design - local certificate + no notarization)\n'
ok "Signature verified"

# ---------------------------------------------------------------------------
# Step 5: swap it into /Applications
# ---------------------------------------------------------------------------
note "Installing to /Applications"
if pgrep -x supacode >/dev/null 2>&1; then
  printf '  quitting the running supacode...\n'
  osascript -e 'quit app "supacode"' || true
  sleep 2
fi
rm -rf "${install_dst}"
ditto "${app_bundle}" "${install_dst}"
ok "Installed ${install_dst}"
printf '  installed versions:\n'
plutil -p "${install_dst}/Contents/Info.plist" | grep -E "CFBundleShortVersionString|CFBundleVersion"
codesign --verify --deep --strict "${install_dst}"
ok "${install_dst} verifies"

# ---------------------------------------------------------------------------
# Step 6: startup smoke test
# ---------------------------------------------------------------------------
if [ "${do_launch}" = true ]; then
  note "Launching the installed app"
  open -a "${install_dst}"
  sleep 6
  if pgrep -x supacode >/dev/null 2>&1; then
    ok "supacode is running"
  else
    fail "supacode did not stay running after launch"
  fi
else
  note "Skipping the launch smoke test (--no-launch)"
fi

# ---------------------------------------------------------------------------
# Step 7: restore build side effects.
# tuist install rewrites Tuist/Package.resolved (package URLs are normalized);
# running the app rewrites supacode.json (e.g. openActionID). Neither is a
# change we want to keep - restore them so the workspace stays clean. Beware:
# uncommitted changes in these two files are discarded here; pass --no-cleanup
# and restore them by hand if you need to keep any.
# ---------------------------------------------------------------------------
if [ "${do_cleanup}" = true ]; then
  note "Restoring build side effects (Tuist/Package.resolved, supacode.json)"
  git checkout -- Tuist/Package.resolved supacode.json
  ok "Restored"
fi

note "Workspace status (expect empty unless --no-cleanup was passed)"
git status --short

note "Done. Do NOT push tags or run \`make bump-and-release\` - this is a local-only install."