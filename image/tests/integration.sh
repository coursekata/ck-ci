#!/usr/bin/env bash
# The image actions' scripts against real tools: BuildKit and buildx, Docker and
# compose, and an OCI registry on localhost:5000. The current buildx builder must be
# a docker-container builder, which CI sets up the way build-action does. The preflight
# reads a real bake definition, the tests run on a built OCI layout and a test stage
# that never uses it is refused, the layout pushes byte for byte, a missing reference
# reads as empty and an unreachable registry as an error, fixture images pass,
# fail and skip their health checks, and the release reads its tags in a real registry.
set -euo pipefail
TESTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
P=$(cd "$TESTS/.." && pwd)

REG=${REG:-localhost:5000}

step() { printf '\n=== %s\n' "$*"; }
die() {
  echo "::error::$*" >&2
  exit 1
}
check() { "$@" || die "check failed: $*"; }
# Deletes the work directory only when it is the one this run made: its name, a real directory and
# the same real path it was made at, so no folder above it has been swapped for a symlink. With the
# marker written at creation it removes the tree; without, the run stopped before writing it, and
# rmdir removes the directory only while it is empty. No -f: input from /dev/null keeps rm from
# asking about the read-only git objects and blobs at a terminal, and anything else in its way
# stops it.
remove_work() {
  local real
  real=$(CDPATH='' cd -P -- "$WORK" 2>/dev/null && pwd -P) || real=""
  if ! [[ $WORK == */ck-ci-integration.???????? ]] || ! [ -d "$WORK" ] || [ -L "$WORK" ] || [ "$real" != "$WORK" ]; then
    echo "::warning::Left $WORK in place: it is not the work directory this run made." >&2
  elif [ -f "$WORK/.ck-ci-integration" ]; then
    # shellcheck disable=SC2217 # rm reads its answers from stdin at a terminal
    rm -r -- "$WORK" </dev/null || echo "::warning::Could not remove $WORK." >&2
  else
    rmdir -- "$WORK" 2>/dev/null || echo "::warning::Left $WORK in place: it has no marker and is not empty." >&2
  fi
}
# Removes the images the test loads into Docker and the work directory, so a run leaves none.
cleanup() {
  docker image rm -f image-build/app:candidate image-build/served:candidate health/served health/sick \
    health/app >/dev/null 2>&1 || true
  remove_work
}

# The work directory, made under TMPDIR's absolute, physical path, so the script's cd cannot move it
# and the cleanup can tell when a folder above it has changed. The trap is armed before anything
# else can fail.
tmp=${TMPDIR:-/tmp}
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
WORK=$(mktemp -d "$tmp/ck-ci-integration.XXXXXXXX")
readonly WORK
trap cleanup EXIT
: >"$WORK/.ck-ci-integration"

step "Check the builder"
# Read whole, not piped: grep -q stops at its match, buildx then fails writing the rest, and
# pipefail fails the check on a builder that passes it.
info=$(docker buildx inspect --bootstrap) || die "cannot inspect the current buildx builder"
grep -qE '^Driver: +docker-container$' <<<"$info" ||
  die "the current buildx builder must use the docker-container driver"

step "A missing reference reads as empty; an unreachable registry is an error"
check [ -z "$("$P/digest-of.sh" "$REG/release/app:nothing")" ]
if "$P/digest-of.sh" localhost:1/release/app:nothing >/dev/null 2>&1; then
  die "an unreachable registry read as a missing reference"
fi

cd "$TESTS/fixture"
export GITHUB_OUTPUT="$WORK/output"
: >"$GITHUB_OUTPUT"

step "The preflight reads the image's stage and platforms from a real bake definition"
IMAGE_BUILD_BAKE_FILE=docker-bake.hcl IMAGE_BUILD_TARGET=app IMAGE_BUILD_TEST=app-test "$P/preflight.sh"
check grep -qx "stage=runtime" "$GITHUB_OUTPUT"
check grep -qx "platforms=\[\]" "$GITHUB_OUTPUT"

step "The tests run on the built image, and a test stage that never uses it is refused"
docker buildx bake --allow "fs.write=$WORK" --set "app.output=type=oci,dest=$WORK/layout,tar=false,oci-mediatypes=true,compression=gzip" \
  --set "app.cache-to=type=local,dest=$WORK/cache,mode=max,oci-mediatypes=true,image-manifest=true" \
  --metadata-file "$WORK/app.json" --progress=plain app >/dev/null 2>&1
digest=$(jq -r '.app["containerimage.digest"]' "$WORK/app.json")
export IMAGE_BUILD_BAKE_FILE=docker-bake.hcl IMAGE_BUILD_STAGE=runtime IMAGE_BUILD_LAYOUT="$WORK/layout" IMAGE_BUILD_DIGEST="$digest"
IMAGE_BUILD_TEST=app-test "$P/run-tests.sh" >/dev/null
if IMAGE_BUILD_TEST=app-unrelated-test "$P/run-tests.sh" >"$WORK/unrelated.log" 2>&1; then
  die "a test stage that never used the image passed as a test of it"
fi
check grep -q "::error::app-unrelated-test never built on the image" "$WORK/unrelated.log"

step "The tested layout and its cache push byte for byte, untagged, and a digest the layout lacks pushes nothing"
cache_digest=$(jq -r '.manifests[0].digest' "$WORK/cache/index.json")
CANDIDATE=$REG/candidate/app LAYOUT="$WORK/layout" DIGEST="$digest" CACHE_LAYOUT="$WORK/cache" CACHE_DIGEST="$cache_digest" CACHE_TAG=cache-1-1 "$P/push.sh" >/dev/null 2>&1
check [ "$("$P/digest-of.sh" "$REG/candidate/app@$digest")" = "$digest" ]
check [ "$("$P/digest-of.sh" "$REG/candidate/app:cache-1-1")" = "$cache_digest" ]
check [ "$(curl -s "http://$REG/v2/candidate/app/tags/list" | jq -c .tags)" = '["cache-1-1"]' ]
missing=sha256:$(printf '0%.0s' {1..64})
if CANDIDATE=$REG/candidate/app LAYOUT="$WORK/layout" DIGEST="$missing" CACHE_LAYOUT="$WORK/cache" CACHE_DIGEST="$cache_digest" CACHE_TAG=cache-2-1 "$P/push.sh" >/dev/null 2>&1; then
  die "a digest the layout does not hold was pushed"
fi
check [ -z "$("$P/digest-of.sh" "$REG/candidate/app:cache-2-1")" ]

step "The image loads for checks with the build's labels, and only with the tested build's layers"
printf '{"target":{"app":{"labels":{"org.opencontainers.image.revision":"abc"}}}}' >"$WORK/labels.json"
IMAGE_BUILD_LABELS_FILE="$WORK/labels.json" IMAGE_BUILD_TARGET=app IMAGE_BUILD_PLATFORMS='[]' "$P/load-image.sh" >/dev/null 2>&1
check grep -qx "image=image-build/app:candidate" "$GITHUB_OUTPUT"
check [ "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' image-build/app:candidate)" = abc ]
if IMAGE_BUILD_LABELS_FILE="$WORK/labels.json" IMAGE_BUILD_TARGET=served IMAGE_BUILD_PLATFORMS='[]' "$P/load-image.sh" >"$WORK/load.log" 2>&1; then
  die "an image whose layers are not the layout's loaded for checks"
fi
check grep -q "not the tested build's" "$WORK/load.log"
platform=$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')
# load <target>: builds the target for this runner into Docker, as health/<target>.
load() { docker buildx bake --set "$1.platform=$platform" --set "$1.output=type=docker,name=health/$1" --progress=plain "$1" >/dev/null 2>&1; }

step "A served image passes its health check, with no network and none of the job's environment"
export FIXTURE_JOB_VAR=from-the-job
load served
"$P/health.sh" health/served >"$WORK/served.out"
check [ ! -s "$WORK/served.out" ]
unset FIXTURE_JOB_VAR

step "An image that turns unhealthy fails its health run"
load sick
if "$P/health.sh" health/sick >/dev/null 2>"$WORK/sick.log"; then
  die "an image whose health check never passes passed its health run"
fi
check grep -q "health/sick did not become healthy" "$WORK/sick.log"

step "An image that declares no health check warns, and runs nothing"
load app
"$P/health.sh" health/app >"$WORK/app.out"
check grep -q "^::warning::health/app declares no HEALTHCHECK" "$WORK/app.out"

# release_build <target> <revision> <tag> [<extra --set>...]: builds target with the labels
# build-action sets to a layout, pushes it as push-action does, as $REG/release/cmp:<tag>, and prints
# its digest. The push goes from the runner, since the builder may not reach its localhost.
release_build() {
  local target=$1 rev=$2 tag=$3 d
  shift 3
  docker buildx bake --allow "fs.write=$WORK" --metadata-file "$WORK/$tag.json" \
    --set "$target.labels.org.opencontainers.image.revision=$rev" \
    --set "$target.labels.org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)-$tag" \
    --set "$target.labels.org.opencontainers.image.version=sha-$rev" \
    --set "$target.output=type=oci,dest=$WORK/cmp-$tag,tar=false,oci-mediatypes=true,compression=gzip" \
    "$@" --progress=plain "$target" >/dev/null 2>&1 || return 1
  d=$(jq -r --arg t "$target" '.[$t]["containerimage.digest"]' "$WORK/$tag.json")
  [[ $d =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  docker buildx imagetools create --prefer-index=false --tag "$REG/release/cmp:$tag" "oci-layout://$WORK/cmp-$tag@$d" >/dev/null 2>&1 || return 1
  echo "$d"
}
# same <candidate> <baseline>: prints compare-release's answer. Called in $(...), where -e does not
# hold, so a build that failed or a config it could not read fails here, not as a false "change".
same() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  : >"$WORK/cmp.out"
  CANDIDATE_REF=$REG/release/cmp@$1 BASELINE_REF=$REG/release/cmp@$2 GITHUB_OUTPUT="$WORK/cmp.out" "$P/compare-release.sh" >"$WORK/cmp.log" || return 1
  ! grep -q '::warning::' "$WORK/cmp.log" || return 1
  grep '^unchanged=' "$WORK/cmp.out"
}

step "A rebuild that changes only the labels each run sets compares unchanged; other content does not"
a=$(release_build served aaa a) || die "the served build failed"
b=$(release_build served bbb b) || die "the served rebuild failed"
check [ "$a" != "$b" ]
check [ "$(same "$b" "$a")" = unchanged=true ]
c=$(release_build sick ccc c) || die "the sick build failed"
check [ "$(same "$c" "$a")" = unchanged=false ]
d=$(release_build served ddd d --set served.labels.org.opencontainers.image.title=renamed) || die "the relabelled build failed"
check [ "$(same "$d" "$a")" = unchanged=false ]

step "A HEALTHCHECK change alone compares as a change"
e=$(release_build app eee e) || die "the app build failed"
f=$(release_build app fff f --set app.target=runtime-checked) || die "the checked app build failed"
check [ "$(same "$e" "$f")" = unchanged=false ]

step "A release cut short is finished, and a commit already released stands"
rel=$REG/release/rel
this=0123456789abcdef0123456789abcdef01234567
# The first attempt released $a under sha-<commit> and stopped before run-1: a re-run adds run-1.
docker buildx imagetools create --prefer-index=false --tag "$rel:sha-$this" "$REG/release/cmp@$a" >/dev/null 2>&1
: >"$GITHUB_OUTPUT"
TAGS="sha-$this"$'\n'run-1 RELEASE=$rel DIGEST=$a GITHUB_SHA=$this "$P/read-release.sh" >/dev/null
check grep -qx "earlier=" "$GITHUB_OUTPUT"
check grep -qx "digest=$a" "$GITHUB_OUTPUT"
check [ "$(awk '/^missing<</ { f = 1; next } f && /^EOF$/ { exit } f' "$GITHUB_OUTPUT")" = "$rel:run-1" ]
# A later build of the same commit, whatever it holds, leaves that release standing.
: >"$GITHUB_OUTPUT"
TAGS="sha-$this"$'\n'run-2 RELEASE=$rel DIGEST=$b GITHUB_SHA=$this "$P/read-release.sh" >/dev/null
check grep -qx "earlier=$a" "$GITHUB_OUTPUT"

step "integration passed"
