#!/usr/bin/env bash

set -euo pipefail

REPO_BASE="https://ocean.surfshark.com/debian"
DIST="stable"
COMPONENT="main"
ARCH="amd64"
FILE="version.json"

PACKAGES_URL="${REPO_BASE}/dists/${DIST}/${COMPONENT}/binary-${ARCH}/Packages"

tmp_packages=$(mktemp)
tmp_deb=$(mktemp --suffix=.deb)
trap 'rm -f "$tmp_packages" "$tmp_deb"' EXIT

if ! curl -fsSL -o "$tmp_packages" "$PACKAGES_URL"; then
  echo "failed to fetch Packages index from $PACKAGES_URL" >&2
  echo "fall back to: curl -fsSL -o pkg.deb <url from mirror/forum post> and hash it manually" >&2
  exit 1
fi

block=$(awk -v RS='' '/^Package: surfshark$/' "$tmp_packages")

if [ -z "$block" ]; then
  echo "no 'surfshark' stanza found in Packages index" >&2
  echo "(if the package was renamed again, check pool/main/s/ listing directly)" >&2
  exit 1
fi

version=$(awk -F': ' '/^Version:/ {print $2; exit}' <<<"$block")
filename=$(awk -F': ' '/^Filename:/ {print $2; exit}' <<<"$block")

if [ -z "$version" ] || [ -z "$filename" ]; then
  echo "could not parse Version/Filename from Packages stanza" >&2
  exit 1
fi

url="${REPO_BASE}/${filename}"

current_version=$(jq -r '.version' "$FILE")
if [ "$version" = "$current_version" ]; then
  echo "already up to date ($version)"
  exit 0
fi

echo "update: $current_version -> $version"

if ! curl -fsSL -o "$tmp_deb" "$url"; then
  echo "failed to download $url" >&2
  exit 1
fi

if [ ! -s "$tmp_deb" ] || [ "$(stat -c %s "$tmp_deb")" -lt 5000000 ]; then
  echo "downloaded file is suspiciously small for an Electron app (<5MB)" >&2
  exit 1
fi

hash=$(nix hash file --sri "$tmp_deb")
if [ -z "$hash" ]; then
  echo "failed to hash download" >&2
  exit 1
fi

tmp_out=$(mktemp)
jq --arg v "$version" --arg u "$url" --arg h "$hash" \
  '.version = $v | .url = $u | .hash = $h' "$FILE" > "$tmp_out"
mv "$tmp_out" "$FILE"

echo "now at $version"

cat <<'EOF'

NOTE: this script only updates version/url/hash. If the update also
changed internal .deb layout (new daemon filenames, moved
systemd unit paths, renamed binary), the flake.nix package
derivation and NixOS module's systemd unit ExecStart paths will
need manual review -- re-run the verify-layout steps (extract the
.deb and diff `find data/usr data/opt data/etc` output) before
trusting a green build.
EOF
