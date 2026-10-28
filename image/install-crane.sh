#!/usr/bin/env bash
# Installs crane, which does every registry read and write outside a build, from
# go-containerregistry's release, pinned by version and checked against the checksum recorded here.
# A new version changes all three lines by hand: neither Renovate nor Dependabot moves a checksum.
set -euo pipefail
version=v0.22.1
case $(uname -m) in
  x86_64) arch=x86_64 sum=0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0 ;;
  aarch64 | arm64) arch=arm64 sum=898c0cff975f898a33e8c4580bdafb0e7c02c7faa33374e946762f97c4ab7110 ;;
  *)
    echo "::error::No crane is pinned for $(uname -m)."
    exit 1
    ;;
esac
dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/crane.XXXXXX")
file=go-containerregistry_Linux_$arch.tar.gz
curl -fsSL --retry 3 -o "$dir/$file" "https://github.com/google/go-containerregistry/releases/download/$version/$file"
echo "$sum  $dir/$file" | sha256sum -c --quiet
tar -xzf "$dir/$file" -C "$dir" crane
echo "$dir" >>"$GITHUB_PATH"
