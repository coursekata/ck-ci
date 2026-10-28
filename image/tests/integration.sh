#!/usr/bin/env bash
# The image actions' scripts against real tools: BuildKit and buildx, Docker and
# compose, crane, and an OCI registry on localhost:5000. The current buildx builder
# must be a docker-container builder, which CI sets up the way build-action does, and
# crane must be on PATH. A missing tag or repository reads as empty, and an unreachable
# registry or one that refuses the read is an error. The preflight reads a real bake
# definition, the tests run on a built OCI layout and a test stage that never uses it is
# refused, the layout pushes byte for byte, the build pins the current cache, fixture
# images pass, fail and skip their health checks, and the release runs whole against a
# real git repository: it releases the head, releases nothing for an unchanged build or a
# commit no longer the head, finishes a release cut short, finishes an earlier release of
# the commit from its own image, and refuses a tag.
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
refusing=""
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
# Removes the refusing registry, the images the test loads into Docker and the work directory, so a
# run leaves none.
cleanup() {
  [ -z "$refusing" ] || docker rm -f "$refusing" >/dev/null 2>&1 || true
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

step "A missing repository reads as empty; an unreachable registry is an error"
check [ -z "$("$P/read-registry.sh" digest "$REG/nothing-$RANDOM$RANDOM:t")" ]
check [ -z "$("$P/read-registry.sh" ls "$REG/nothing-$RANDOM$RANDOM")" ]
if "$P/read-registry.sh" digest localhost:1/release/app:nothing >/dev/null 2>"$WORK/unreachable.log"; then
  die "an unreachable registry read as a missing reference"
fi
check grep -qx "::error::Could not read localhost:1/release/app:nothing." "$WORK/unreachable.log"

step "A registry that refuses a read is an error, not a missing reference"
# A real registry that refuses every read without a login. Its htpasswd holds a password nobody
# knows, so the refusal comes back over HTTP, as a registry answers a login without access.
refusing=$(docker run -d --rm -p 127.0.0.1::5000 -v "$TESTS/fixture/htpasswd:/auth/htpasswd:ro" \
  -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM=ci -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  registry:3.1.2@sha256:ddf754342cfc8acc51a56d5d0ab6af06826461864460636d8bd5c546dab2a7b8)
host=$(docker port "$refusing" 5000/tcp | head -1 | sed 's/^127\.0\.0\.1/localhost/')
for _ in $(seq 20); do curl -s -o /dev/null "http://$host/v2/" && break; sleep 0.5; done
denied=$host/release/app
if "$P/read-registry.sh" digest "$denied:t" >/dev/null 2>"$WORK/denied.log"; then
  die "a refused tag read as a missing reference"
fi
check grep -q UNAUTHORIZED "$WORK/denied.log"
if "$P/read-registry.sh" ls "$denied" >/dev/null 2>"$WORK/denied.log"; then
  die "a refused listing read as a missing repository"
fi
check grep -q UNAUTHORIZED "$WORK/denied.log"
docker rm -f "$refusing" >/dev/null

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
candidate=$REG/candidate/app-$RANDOM$RANDOM
CANDIDATE=$candidate LAYOUT="$WORK/layout" DIGEST="$digest" CACHE_LAYOUT="$WORK/cache" CACHE_DIGEST="$cache_digest" CACHE_TAG=cache-1-1 "$P/push.sh" >/dev/null 2>&1
check [ "$(crane manifest "$candidate@$digest" | sha256sum | cut -d' ' -f1)" = "${digest#sha256:}" ]
check [ "$("$P/read-registry.sh" digest "$candidate:cache-1-1")" = "$cache_digest" ]
check [ "$(crane ls "$candidate")" = cache-1-1 ]
check [ -z "$("$P/read-registry.sh" digest "$candidate:nothing")" ]
missing=sha256:$(printf '0%.0s' {1..64})
other=$REG/candidate/other-$RANDOM$RANDOM
if CANDIDATE=$other LAYOUT="$WORK/layout" DIGEST="$missing" CACHE_LAYOUT="$WORK/cache" CACHE_DIGEST="$cache_digest" CACHE_TAG=cache-2-1 "$P/push.sh" >"$WORK/push.log" 2>&1; then
  die "a digest the layout does not hold was pushed"
fi
check grep -q "::error::$WORK/layout does not hold $missing alone" "$WORK/push.log"
check [ -z "$("$P/read-registry.sh" ls "$other")" ]

step "The build pins the current cache by digest; with none it starts cold, and an unreachable registry fails"
pinned=$REG/cache/pin-$RANDOM$RANDOM
CACHE=$pinned GITHUB_OUTPUT="$WORK/cold" "$P/pin-cache.sh" >"$WORK/cold.log"
check grep -qx "::notice::No cache at $pinned:current yet, so this build starts cold." "$WORK/cold.log"
check [ ! -s "$WORK/cold" ]
crane copy "$candidate:cache-1-1" "$pinned:current" >/dev/null 2>&1
CACHE=$pinned GITHUB_OUTPUT="$WORK/warm" "$P/pin-cache.sh"
check grep -qx "from=type=registry,ref=$pinned@$cache_digest" "$WORK/warm"
if CACHE=localhost:1/cache/app GITHUB_OUTPUT="$WORK/unreachable" "$P/pin-cache.sh" >/dev/null 2>&1; then
  die "an unreachable registry pinned no cache and went on"
fi

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
  crane push "$WORK/cmp-$tag" "$REG/release/cmp:$tag" >/dev/null 2>&1 || return 1
  echo "$d"
}
# same <candidate> <baseline>: prints the release's comparison of the two builds' configs, as crane
# reads them. Called in $(...), where -e does not hold, so a build that failed or a config it could
# not read fails here, not as a false "change".
same() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  local build release
  build=$("$P/read-configs.sh" "$REG/release/cmp@$1") && release=$("$P/read-configs.sh" "$REG/release/cmp@$2") || return 1
  jq -L "$P" -r --argjson r "$release" 'include "release"; compare($r) | "unchanged=\(.unchanged)"' <<<"$build"
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

step "An index compares by its platforms' configs"
# index <digest> <tag>: wraps the build in an index of its one platform and prints the index's digest.
index() { crane index append -m "$REG/release/cmp@$1" -t "$REG/release/cmp:$2" >/dev/null 2>&1 && crane digest "$REG/release/cmp:$2"; }
ia=$(index "$a" index-a) || die "the index of a failed"
ic=$(index "$c" index-c) || die "the index of c failed"
check [ "$(same "$ia" "$b")" = unchanged=true ]
check [ "$(same "$ic" "$a")" = unchanged=false ]

# The release runs whole, against a git repository whose main is the branch it releases from and a
# release repository of its own each run, so a registry kept between runs holds no tag it did not
# write. The candidates are the comparison builds: b is a with other build metadata, c and d differ.
git init -q --bare "$WORK/git/acme/app"
git init -q "$WORK/clone"
# merge: puts a new commit on main and prints it.
merge() {
  git -C "$WORK/clone" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m change
  git -C "$WORK/clone" push -q "$WORK/git/acme/app" HEAD:refs/heads/main
  git -C "$WORK/clone" rev-parse HEAD
}
rel=$REG/release/rel-$RANDOM$RANDOM
export GITHUB_STEP_SUMMARY="$WORK/summary"
# release <commit> <run id> <digest>: runs the release as that run would, with fresh outputs, under
# the commit's and run's tags and v-<commit>, a tag of the caller's own.
release() {
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"
  GITHUB_SERVER_URL="file://$WORK/git" GITHUB_REPOSITORY=acme/app GITHUB_REF=${REF:-refs/heads/main} GITHUB_SHA=$1 GITHUB_RUN_ID=$2 \
    CANDIDATE=$REG/release/cmp RELEASE=${TO:-$rel} CACHE=${CACHE:-} CACHE_DIGEST=${CACHE_DIGEST:-} ALWAYS_UPDATE_CACHE=false TOKEN="" \
    DIGEST=$3 TAGS="sha-$1"$'\n'"run-$2"$'\n'"v-$1" "$P/release.sh" >"$WORK/release.log" 2>&1 || {
    cat "$WORK/release.log"
    return 1
  }
}
names() { "$P/read-registry.sh" digest "$rel:$1"; }

step "The first release is tagged, made the latest, given latest, and its cache made current"
crane copy "$candidate@$cache_digest" "$REG/release/cmp:cache" >/dev/null 2>&1
one=$(merge)
cache=$REG/cache/rel-$RANDOM$RANDOM
CACHE=$cache CACHE_DIGEST=$cache_digest release "$one" 1 "$a" || die "the first release failed"
check grep -qx "released=true" "$GITHUB_OUTPUT"
check [ "$(names "sha-$one")" = "$a" ] && check [ "$(names "v-$one")" = "$a" ] && check [ "$(names run-1)" = "$a" ]
check [ "$(names latest)" = "$a" ]
check [ "$("$P/read-registry.sh" digest "$cache:current")" = "$cache_digest" ]

step "A build unchanged from the latest release releases nothing"
two=$(merge)
release "$two" 2 "$b" || die "the unchanged release failed"
check grep -qx "released=false" "$GITHUB_OUTPUT"
check grep -qx "digest=$a" "$GITHUB_OUTPUT"
check [ -z "$(names "sha-$two")" ] && check [ -z "$(names "v-$two")" ] && check [ -z "$(names run-2)" ]

step "A run whose commit is no longer the head writes nothing"
release "$one" 3 "$c" || die "the run behind the head failed"
check grep -qx "digest=" "$GITHUB_OUTPUT"
check [ -z "$(names run-3)" ] && check [ "$(names latest)" = "$a" ]
check grep -q "The branch has moved on to $two" "$GITHUB_STEP_SUMMARY"

step "A release cut short before its run tag is finished by the head's next run"
three=$(merge)
crane copy "$REG/release/cmp@$c" "$rel:sha-$three" >/dev/null 2>&1
release "$three" 4 "$c" || die "finishing the release failed"
check grep -qx "released=true" "$GITHUB_OUTPUT"
check [ "$(names run-4)" = "$c" ] && check [ "$(names "v-$three")" = "$c" ] && check [ "$(names latest)" = "$c" ]

step "A release cut short after its run tag gets latest"
four=$(merge)
crane copy "$REG/release/cmp@$d" "$rel:sha-$four" >/dev/null 2>&1
crane tag "$rel@$d" run-5 >/dev/null 2>&1
release "$four" 5 "$d" || die "finishing the release failed"
check grep -qx "released=true" "$GITHUB_OUTPUT"
check [ "$(names "v-$four")" = "$d" ] && check [ "$(names latest)" = "$d" ]

step "An earlier release of this commit, of another build, gets its missing tags; this build gets none"
five=$(merge)
crane copy "$REG/release/cmp@$c" "$rel:sha-$five" >/dev/null 2>&1
release "$five" 6 "$b" || die "finishing the earlier release failed"
check grep -qx "released=false" "$GITHUB_OUTPUT"
check grep -qx "digest=$c" "$GITHUB_OUTPUT"
check [ "$(names "v-$five")" = "$c" ] && check [ "$(names run-6)" = "$c" ] && check [ "$(names latest)" = "$c" ]
check grep -q "Nothing was tagged with $b" "$GITHUB_STEP_SUMMARY"

step "A branch that does not exist, a tag, or a registry that cannot be read, fails rather than release"
if REF=refs/heads/gone release "$five" 7 "$c"; then die "a missing branch released"; fi
git -C "$WORK/clone" -c user.name=t -c user.email=t@t -c tag.gpgsign=false tag -a v1 -m v1 "$five"
git -C "$WORK/clone" push -q "$WORK/git/acme/app" refs/tags/v1
if REF=refs/tags/v1 release "$five" 7 "$c"; then die "a run on a tag passed"; fi
check grep -q "::error::refs/tags/v1 is not a branch" "$WORK/release.log"
if TO=localhost:1/release/rel release "$five" 7 "$c"; then die "an unreachable registry released"; fi
check grep -q "::error::Could not read localhost:1/release/rel:sha-$five." "$WORK/release.log"

step "integration passed"
