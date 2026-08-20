#!/usr/bin/env bash
# Download a Turbot Pipes CLI release asset from GitHub, verify it against the
# release checksums.txt, unpack it and install the binary into $BIN_DIR.
#
#   fetch-release.sh <repo> <version> <asset> [binary-name]
#
#   repo    turbot repo name, e.g. steampipe
#   version release tag, e.g. v2.4.5
#   asset   release asset file name, e.g. steampipe_linux_amd64.tar.gz
set -euo pipefail

repo="${1:?repo required}"
version="${2:?version required}"
asset="${3:?asset required}"
binary="${4:-$repo}"
bin_dir="${BIN_DIR:-/out/bin}"

base="https://github.com/turbot/${repo}/releases/download/${version}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

echo "==> fetching ${repo} ${version} (${asset})"
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -O "${base}/${asset}"
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -O "${base}/checksums.txt"

echo "==> verifying checksum"
grep -E "[[:space:]]\*?${asset}\$" checksums.txt > "${asset}.sha256"
sha256sum -c "${asset}.sha256"

echo "==> unpacking"
tar -xzf "$asset"
install -D -m 0755 "./${binary}" "${bin_dir}/${binary}"
"${bin_dir}/${binary}" --version || true
