#!/usr/bin/env bash
set -euo pipefail

AUR_PKG="${AUR_PKG:-surfshark-client}"
POOL_URL="https://ocean.surfshark.com/debian/pool/main/s"
FILE="version.json"
MIN_BYTES=5000000

die() { echo "::error::update.sh: $*" >&2; exit 1; }
log() { echo "update.sh: $*" >&2; }

command -v jq   >/dev/null || die "jq not found"
command -v nix  >/dev/null || die "nix not found"
[ -f "$FILE" ]             || die "$FILE missing (run from repo root)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cur=$(jq -er '.version' "$FILE") || die "cannot read .version from $FILE"

# --- version from AUR ---
json=$(curl -fsSL --retry 3 --retry-delay 2 \
  "https://aur.archlinux.org/rpc/v5/info?arg[]=${AUR_PKG}") \
  || die "AUR RPC request failed"

count=$(jq -r '.resultcount' <<<"$json")
[ "$count" = "1" ] || die "AUR returned resultcount=$count for '${AUR_PKG}' (package renamed or removed?)"

raw=$(jq -r '.results[0].Version // empty' <<<"$json")
[ -n "$raw" ] || die "AUR result has no Version field"

ver="${raw#*:}"   # strip epoch
ver="${ver%-*}"   # strip pkgrel
[[ "$ver" =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "unexpected AUR version format: '$raw' -> '$ver'"

log "AUR: $raw -> $ver (current: $cur)"

if [ "$ver" = "$cur" ]; then
  log "already up to date"
  exit 0
fi

newest=$(printf '%s\n%s\n' "$cur" "$ver" | sort -V | tail -n1)
if [ "$newest" != "$ver" ]; then
  log "AUR version $ver is older than current $cur; not downgrading"
  exit 0
fi

# --- verify upstream .deb exists ---
url="${POOL_URL}/surfshark_${ver}_amd64.deb"
curl -fsSIL --retry 2 -o /dev/null "$url" \
  || die "AUR says $ver but upstream .deb missing: $url (AUR ahead of upstream, or pool path changed)"

# --- download + validate ---
deb="$tmp/surfshark.deb"
curl -fsSL --retry 3 --retry-delay 2 -o "$deb" "$url" || die "download failed: $url"

size=$(stat -c %s "$deb")
[ "$size" -ge "$MIN_BYTES" ] || die "download is ${size} bytes (<${MIN_BYTES})"
head -c 8 "$deb" | grep -q '^!<arch>' || die "download is not a deb (ar) archive"

hash=$(nix hash file --sri "$deb") || die "nix hash file failed"
[ -n "$hash" ] || die "empty hash"

# --- write version.json ---
jq --arg v "$ver" --arg u "$url" --arg h "$hash" \
  '.version = $v | .url = $u | .hash = $h' "$FILE" > "$tmp/version.json"
jq -e '.version and .url and .hash' "$tmp/version.json" >/dev/null || die "generated version.json invalid"
mv "$tmp/version.json" "$FILE"

log "updated: $cur -> $ver"
log "NOTE: only version/url/hash changed; review flake.nix/package.nix if .deb layout changed"
