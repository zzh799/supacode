#!/usr/bin/env bash
# Publish the locally built and locally signed app to a GitHub Release, without
# going through the CI/CD pipeline. This is the "distribute the build I just made"
# half of docs/local-packaging.md; scripts/install-local.sh produces the signed
# archive this script packages.
#
# What it does:
#   1. Verifies the signed archive exists (build it with scripts/install-local.sh).
#   2. Packages build/supacode.app.zip + build/supacode.dmg (create-dmg via mise).
#   3. Generates the checksums.json manifest (same format CI uploads).
#   4. Auto-generates release notes from GitHub (only commits already on the
#      remote are compared, so pushes/PRs the remote has never seen are dropped).
#   5. Creates (or updates) release `v<MARKETING_VERSION>` on the target repo and
#      uploads the three assets.
#
# No tag is created locally and nothing is pushed: `gh release create` creates
# the tag ref on the remote. This never triggers CI as long as you do not push
# the tag / main branch yourself (see docs/local-packaging.md).
#
# Usage: scripts/publish-local.sh [options]
#
# Options:
#   --repo owner/repo   GitHub repo to publish to. Defaults to the `origin` remote.
#   --tag NAME          Release/tag name (default: v$MARKETING_VERSION).
#   --target SHA        Commit the release points at (default: local HEAD; must be
#                       pushed to the target repo already).
#   --draft             Create the release as a draft.
#   --prerelease        Mark the release as a prerelease.
#   --dry-run           Build artifacts and print the gh commands without running them.
#   -h, --help          Show this help.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

app_repo=""
tag=""
branch_sha=""
draft=false
prerelease=false
dry_run=false

archive_path="${repo_root}/build/supacode.xcarchive"
app_bundle="${archive_path}/Products/Applications/supacode.app"
artifacts_dir="${repo_root}/build"

usage() {
  cat <<'EOF'
Usage: scripts/publish-local.sh [options]

Publishes the locally built & signed app (build/supacode.xcarchive) as a GitHub
Release, without running the CI/CD pipeline. See docs/local-packaging.md.

Options:
  --repo owner/repo  GitHub repo to publish. Default: repo of the git `origin` remote.
  --tag NAME         Release/tag to create/update. Default: v+MARKETING_VERSION from
                     Configurations/Project.xcconfig.
  --target SHA       Commit the release points at. Default: local HEAD. The commit
                     must already exist on the target repo.
  --draft            Create an unpublished draft release.
  --prerelease       Mark the release as a prerelease.
  --dry-run          Build the artifacts, print the exact gh commands, upload nothing.
  -h, --help         Show this help.

Requirements: a signed archive (run scripts/install-local.sh first), gh CLI
authenticated to --repo, and the mise-pinned create-dmg (mise install).
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
    --repo)
      [ "$#" -ge 2 ] || fail "--repo requires owner/repo"
      app_repo="$2"
      shift 2
      ;;
    --tag)
      [ "$#" -ge 2 ] || fail "--tag requires a name"
      tag="$2"
      shift 2
      ;;
    --target)
      [ "$#" -ge 2 ] || fail "--target requires a commit SHA"
      branch_sha="$2"
      shift 2
      ;;
    --draft)
      draft=true
      shift
      ;;
    --prerelease)
      prerelease=true
      shift
      ;;
    --dry-run)
      dry_run=true
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
# Preflight
# ---------------------------------------------------------------------------
note "Preflight"
command -v gh >/dev/null 2>&1 || fail "gh CLI not found; install it (brew install gh) and run \`gh auth login\`"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated; run \`gh auth login\`"

if ! mise exec -- create-dmg --help >/dev/null 2>&1; then
  fail "create-dmg is broken or missing; run \`mise uninstall -y npm:create-dmg && mise install npm:create-dmg\`"
fi
ok "gh authenticated, create-dmg available"

[ -d "${app_bundle}" ] || fail "signed app not found at ${app_bundle}; run scripts/install-local.sh first"
codesign --verify --deep --strict "${app_bundle}" >/dev/null 2>&1 \
  || fail "app is not validly signed; re-run scripts/install-local.sh to rebuild and sign"

# ---------------------------------------------------------------------------
# Resolve repo, tag, target commit
# ---------------------------------------------------------------------------
if [ -z "${app_repo}" ]; then
  remote_url="$(git config --get remote.origin.url || true)"
  app_repo="$(printf '%s' "${remote_url}" | sed -E 's#^[a-z]+://[^/]*github\.com/##; s#\.git$##; s#/$##')"
fi
[ -n "${app_repo}" ] || fail "cannot determine the target repo; pass --repo owner/repo"
app_repo="${app_repo#https://github.com/}"
ok "target repo: ${app_repo}"

if [ -z "${tag}" ]; then
  version="$(awk -F' = ' '/^MARKETING_VERSION = [0-9.]+$/{print $2; exit}' Configurations/Project.xcconfig)"
  [ -n "${version}" ] || fail "MARKETING_VERSION not found in Configurations/Project.xcconfig"
  tag="v${version}"
fi
echo "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$' || fail "tag must look like vX.Y.Z, got: $tag"
ok "release: ${tag}"

if [ -z "${branch_sha}" ]; then
  branch_sha="$(git rev-parse HEAD)"
fi
if ! git ls-remote "https://github.com/${app_repo}.git" 2>/dev/null | grep -qw "${branch_sha}"; then
  fail "commit ${branch_sha} is not on ${app_repo}; push the branch first (e.g. git push origin $(git branch --show-current))"
fi
ok "target commit: ${branch_sha:0:12} (on ${app_repo})"

# ---------------------------------------------------------------------------
# Package artifacts: zip, DMG, checksums
# ---------------------------------------------------------------------------
note "Packaging the signed app"
rm -f "${artifacts_dir}/supacode.app.zip"
ditto -c -k --sequesterRsrc --keepParent "${app_bundle}" "${artifacts_dir}/supacode.app.zip"
ok "supacode.app.zip"

rm -f "${artifacts_dir}/supacode.dmg"
# Sign the DMG with the same identity that signed the app, so `codesign -dv` and
# the Gatekeeper check look consistent everywhere (still rejected by spctl - the
# archive is not notarized, see docs/local-packaging.md).
signer="$(codesign -dvv "${app_bundle}" 2>&1 | awk -F'= ' '/^Authority=Apple Development/{print $2; exit}' || true)"
identity=""
if [ -n "${signer}" ]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Apple Development' | grep -F "${signer}" | head -1 | awk '{print $2}' || true)"
fi
if [ -z "${identity}" ]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Apple Development' | head -1 | awk '{print $2}' || true)"
fi
if [ -z "${identity}" ]; then
  fail "no Apple Development identity in the keychain to sign the DMG with"
fi
mise exec -- create-dmg "${app_bundle}" "${artifacts_dir}/" --overwrite --identity="${identity}"
newest_dmg="$(for f in "${artifacts_dir}"/*.dmg; do printf '%s %s\n' "$(stat -f '%m' "$f")" "$f"; done | sort -rn | head -1 | cut -d' ' -f2-)"
[ -n "${newest_dmg}" ] && [ -f "${newest_dmg}" ] || fail "create-dmg did not produce a DMG"
if [ "${newest_dmg}" != "${artifacts_dir}/supacode.dmg" ]; then
  mv "${newest_dmg}" "${artifacts_dir}/supacode.dmg"
fi
ok "supacode.dmg"

python3 "scripts/generate_release_checksums.py" "${tag}" "${artifacts_dir}/checksums.json" \
  "${artifacts_dir}/supacode.dmg" "${artifacts_dir}/supacode.app.zip"
ok "checksums.json"

# ---------------------------------------------------------------------------
# Auto-generate release notes from the GitHub API (same shape as the CI's
# generate-notes step, only commits the remote has seen are listed).
# ---------------------------------------------------------------------------
prev_tag="$(gh release list --limit 1 --exclude-drafts --exclude-pre-releases --repo "${app_repo}" --json tagName --jq '.[0].tagName' 2>/dev/null || true)"
if [ -n "${prev_tag}" ] && [ "${prev_tag}" != "${tag}" ]; then
  gh api "repos/${app_repo}/releases/generate-notes" -f tag_name="${tag}" -f previous_tag_name="${prev_tag}" --jq '.body' > "${artifacts_dir}/release-notes.md"
else
  gh api "repos/${app_repo}/releases/generate-notes" -f tag_name="${tag}" --jq '.body' > "${artifacts_dir}/release-notes.md"
fi
ok "release notes generated (build/release-notes.md)"

create_cmd=(gh release create "${tag}" --repo "${app_repo}" --title "${tag}"
  --notes-file "${artifacts_dir}/release-notes.md" --target "${branch_sha}")
upload_cmd=(gh release upload "${tag}" --repo "${app_repo}" --clobber
  "${artifacts_dir}/supacode.app.zip" "${artifacts_dir}/supacode.dmg" "${artifacts_dir}/checksums.json")
[ "${draft}" = true ] && create_cmd+=(--draft)
[ "${prerelease}" = true ] && create_cmd+=(--prerelease)

if [ "${dry_run}" = true ]; then
  note "Dry run - artifacts built, upload skipped"
  printf '  %s\n' "${create_cmd[*]}"
  printf '  %s\n' "${upload_cmd[*]}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Create (or update) the release and upload assets
# ---------------------------------------------------------------------------
note "Publishing ${tag} to ${app_repo}"
if gh release view "${tag}" --repo "${app_repo}" >/dev/null 2>&1; then
  printf '  release %s already exists, updating it\n' "${tag}"
  edit_cmd=(gh release edit "${tag}" --repo "${app_repo}" --notes-file "${artifacts_dir}/release-notes.md" --target "${branch_sha}")
  [ "${draft}" = true ] && edit_cmd+=(--draft)
  [ "${prerelease}" = true ] && edit_cmd+=(--prerelease)
  "${edit_cmd[@]}"
else
  "${create_cmd[@]}"
fi
"${upload_cmd[@]}"
ok "published ${tag} -> https://github.com/${app_repo}/releases/tag/${tag}"

note "Done. The release is live; local git was not touched (no tag, no push)."
printf '  Remember: this build is signed with a local Apple Development certificate and is\n'
printf '  NOT notarized. Gatekeeper blocks it on other Macs ("Open Anyway" bypasses).\n'