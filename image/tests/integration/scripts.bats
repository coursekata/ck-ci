# The image actions' scripts against real tools: BuildKit and buildx, Docker and compose, crane,
# and an OCI registry at REG, localhost:5000 unless given. The current buildx builder must be a
# docker-container builder, which CI sets up the way build-action does. The fixture's build to an
# OCI layout and the comparison images are made once, in setup_file, so every test reads them
# and none depends on another having run. The release tests run release-action's script whole
# against a git repository and a release repository of their own. crane must be on PATH.

load ../helper

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

setup_file() {
  # Read whole, not piped: grep -q stops at its match, buildx then fails writing the rest, and
  # pipefail fails the check on a builder that passes it.
  local info
  info=$(docker buildx inspect --bootstrap) || fail "cannot inspect the current buildx builder"
  grep -qE '^Driver: +docker-container$' <<<"$info" ||
    fail "the current buildx builder must use the docker-container driver"

  export REG=${REG:-localhost:5000} WORK=$BATS_FILE_TMPDIR FIXTURE=$TESTS/fixture
  cd "$FIXTURE" || return
  docker buildx bake --allow "fs.write=$WORK" --set "app.output=type=oci,dest=$WORK/layout,tar=false,oci-mediatypes=true,compression=gzip" \
    --set "app.cache-to=type=local,dest=$WORK/cache,mode=max,oci-mediatypes=true,image-manifest=true" \
    --metadata-file "$WORK/app.json" --progress=plain app >/dev/null 2>&1 || fail "the fixture build failed"
  export IMAGE_BUILD_BAKE_FILE=docker-bake.hcl IMAGE_BUILD_STAGE=runtime IMAGE_BUILD_LAYOUT=$WORK/layout
  IMAGE_BUILD_DIGEST=$(jq -r '.app["containerimage.digest"]' "$WORK/app.json")
  FIXTURE_CACHE_DIGEST=$(jq -r '.manifests[0].digest' "$WORK/cache/index.json")
  export IMAGE_BUILD_DIGEST FIXTURE_CACHE_DIGEST

  SERVED=$(release_build served aaa a) || fail "the served build failed"
  SERVED_REBUILT=$(release_build served bbb b) || fail "the served rebuild failed"
  SICK=$(release_build sick ccc c) || fail "the sick build failed"
  RENAMED=$(release_build served ddd d --set served.labels.org.opencontainers.image.title=renamed) ||
    fail "the relabelled build failed"
  APP=$(release_build app eee e) || fail "the app build failed"
  CHECKED=$(release_build app fff f --set app.target=runtime-checked) || fail "the checked app build failed"
  export SERVED SERVED_REBUILT SICK RENAMED APP CHECKED

  # Each run writes release repositories of its own, so a registry kept between runs holds no tag
  # a test did not write.
  export RUN=$RANDOM$RANDOM
}

# Removes what the tests leave outside bats' own temporary files: the images they load into Docker
# and the refusing registry, if a test started one.
teardown_file() {
  [ ! -f "$WORK/refusing" ] || docker rm -f "$(cat "$WORK/refusing")" >/dev/null 2>&1 || true
  docker image rm -f image-build/app:candidate image-build/served:candidate health/served health/sick health/app \
    health/app-unrelated-test >/dev/null 2>&1 || true
}

setup() {
  cd "$FIXTURE" || return
  export GITHUB_OUTPUT=$BATS_TEST_TMPDIR/output GITHUB_STEP_SUMMARY=$BATS_TEST_TMPDIR/summary
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"
}

# build_for_health <target>: builds the target for this runner into Docker, as health/<target>.
build_for_health() {
  local platform
  platform=$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')
  docker buildx bake --set "$1.platform=$platform" --set "$1.output=type=docker,name=health/$1" --progress=plain "$1" >/dev/null 2>&1
}

# same <candidate> <baseline>: prints the release's comparison of the two builds' configs, as crane
# reads them, and fails on a build that failed or a config it could not read, so neither passes as
# a change.
same() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  local built released
  built=$("$SCRIPTS/lib/read-configs.sh" "$REG/release/cmp@$1") || return 1
  released=$("$SCRIPTS/lib/read-configs.sh" "$REG/release/cmp@$2") || return 1
  jq -L "$SCRIPTS/release-action" -r --argjson r "$released" 'include "release"; compare($r) | "unchanged=\(.unchanged)"' <<<"$built"
}

@test "a missing repository reads as empty; an unreachable registry is an error" {
  run --separate-stderr "$SCRIPTS/lib/read-registry.sh" digest "$REG/nothing-$RUN:t"
  assert_success
  assert_output ""
  run --separate-stderr "$SCRIPTS/lib/read-registry.sh" ls "$REG/nothing-$RUN"
  assert_success
  assert_output ""
  run --separate-stderr "$SCRIPTS/lib/read-registry.sh" digest localhost:1/release/app:nothing
  assert_failure
  assert_output ""
  assert_equal "${stderr##*$'\n'}" "::error::Could not read localhost:1/release/app:nothing."
}

@test "a registry that refuses a read is an error, not a missing reference" {
  # A real registry that refuses every read without a login. Its htpasswd holds a password nobody
  # knows, so the refusal comes back over HTTP, as a registry answers a login without access.
  local refusing host
  refusing=$(docker run -d --rm -p 127.0.0.1::5000 -v "$TESTS/fixture/htpasswd:/auth/htpasswd:ro" \
    -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM=ci -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
    registry:3.1.2@sha256:ddf754342cfc8acc51a56d5d0ab6af06826461864460636d8bd5c546dab2a7b8)
  echo "$refusing" >"$WORK/refusing"
  host=$(docker port "$refusing" 5000/tcp | head -1 | sed 's/^127\.0\.0\.1/localhost/')
  for _ in $(seq 20); do curl -s -o /dev/null "http://$host/v2/" && break; sleep 0.5; done
  run --separate-stderr "$SCRIPTS/lib/read-registry.sh" digest "$host/release/app:t"
  assert_failure
  assert_output ""
  assert_stderr --partial UNAUTHORIZED
  run --separate-stderr "$SCRIPTS/lib/read-registry.sh" ls "$host/release/app"
  assert_failure
  assert_output ""
  assert_stderr --partial UNAUTHORIZED
}

@test "the target check reads the image's stage and platforms from a real bake definition" {
  IMAGE_BUILD_TARGET=app IMAGE_BUILD_TEST=app-test run "$SCRIPTS/build-action/check-targets.sh"
  assert_success
  run cat "$GITHUB_OUTPUT"
  assert_line "stage=runtime"
  assert_line "platforms=[]"
}

@test "the tests run on the built image, a failing test fails, and a test stage that never uses it is refused" {
  IMAGE_BUILD_TEST=app-test run "$SCRIPTS/build-action/test-image.sh"
  assert_success
  IMAGE_BUILD_TEST=app-failing-test run "$SCRIPTS/build-action/test-image.sh"
  assert_failure
  assert_output --regexp 'ERROR: .*grep -qx v2 /app/version'
  IMAGE_BUILD_TEST=app-unrelated-test run "$SCRIPTS/build-action/test-image.sh"
  assert_failure
  assert_output --partial "::error::app-unrelated-test never built on the image"
}

@test "the tested layout and its cache push byte for byte, untagged, and a digest the layout lacks pushes nothing" {
  local candidate=$REG/candidate/app-$RUN other=$REG/candidate/other-$RUN missing
  CANDIDATE=$candidate LAYOUT=$IMAGE_BUILD_LAYOUT DIGEST=$IMAGE_BUILD_DIGEST CACHE_LAYOUT=$WORK/cache CACHE_DIGEST=$FIXTURE_CACHE_DIGEST CACHE_TAG=cache-1-1 \
    run "$SCRIPTS/push-action/push-image.sh"
  assert_success
  run bash -c "crane manifest '$candidate@$IMAGE_BUILD_DIGEST' | sha256sum | cut -d' ' -f1"
  assert_output "${IMAGE_BUILD_DIGEST#sha256:}"
  run "$SCRIPTS/lib/read-registry.sh" digest "$candidate:cache-1-1"
  assert_output "$FIXTURE_CACHE_DIGEST"
  run crane ls "$candidate"
  assert_output cache-1-1
  run --separate-stderr "$SCRIPTS/lib/read-registry.sh" digest "$candidate:nothing"
  assert_success
  assert_output ""

  missing=sha256:$(printf '0%.0s' {1..64})
  CANDIDATE=$other LAYOUT=$IMAGE_BUILD_LAYOUT DIGEST=$missing CACHE_LAYOUT=$WORK/cache CACHE_DIGEST=$FIXTURE_CACHE_DIGEST CACHE_TAG=cache-2-1 \
    run "$SCRIPTS/push-action/push-image.sh"
  assert_failure
  assert_output --partial "::error::$IMAGE_BUILD_LAYOUT does not hold $missing alone"
  run --separate-stderr "$SCRIPTS/lib/read-registry.sh" ls "$other"
  assert_output ""
}

@test "the build pins the current cache by digest; with none it starts cold, and an unreachable registry fails" {
  local pinned=$REG/cache/pin-$RUN
  CACHE=$pinned run "$SCRIPTS/build-action/pin-cache.sh"
  assert_success
  assert_output "::notice::No cache at $pinned:current yet, so this build starts cold."
  run cat "$GITHUB_OUTPUT"
  assert_output ""
  run crane push "$WORK/cache" "$pinned:current"
  assert_success
  CACHE=$pinned run "$SCRIPTS/build-action/pin-cache.sh"
  assert_success
  run step_output from
  assert_output "type=registry,ref=$pinned@$FIXTURE_CACHE_DIGEST"
  : >"$GITHUB_OUTPUT"
  CACHE=localhost:1/cache/app run "$SCRIPTS/build-action/pin-cache.sh"
  assert_failure
  run step_output from
  assert_output ""
}

@test "the image loads for checks with the build's labels, and only with the tested build's layers" {
  printf '{"target":{"app":{"labels":{"org.opencontainers.image.revision":"abc"}}}}' >"$BATS_TEST_TMPDIR/labels.json"
  IMAGE_BUILD_LABELS_FILE=$BATS_TEST_TMPDIR/labels.json IMAGE_BUILD_TARGET=app IMAGE_BUILD_PLATFORMS='[]' run "$SCRIPTS/build-action/load-image.sh"
  assert_success
  run cat "$GITHUB_OUTPUT"
  assert_line "image=image-build/app:candidate"
  run docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' image-build/app:candidate
  assert_output abc

  IMAGE_BUILD_LABELS_FILE=$BATS_TEST_TMPDIR/labels.json IMAGE_BUILD_TARGET=served IMAGE_BUILD_PLATFORMS='[]' run "$SCRIPTS/build-action/load-image.sh"
  assert_failure
  assert_output --partial "not the tested build's"
}

@test "a served image passes its health check, with no network and none of the job's environment" {
  build_for_health served
  export FIXTURE_JOB_VAR=from-the-job
  IMAGE=health/served run --separate-stderr "$SCRIPTS/check-health-action/check-health.sh"
  assert_success
  assert_output ""
}

@test "an image that turns unhealthy fails its health run" {
  build_for_health sick
  IMAGE=health/sick run "$SCRIPTS/check-health-action/check-health.sh"
  assert_failure
  assert_output --partial "health/sick did not become healthy"
}

@test "an image that declares no health check, or HEALTHCHECK NONE, warns and runs nothing" {
  build_for_health app
  IMAGE=health/app run "$SCRIPTS/check-health-action/check-health.sh"
  assert_success
  assert_output "::warning::health/app declares no HEALTHCHECK, so no health check ran for it."
  build_for_health app-unrelated-test
  IMAGE=health/app-unrelated-test run "$SCRIPTS/check-health-action/check-health.sh"
  assert_success
  assert_output "::warning::health/app-unrelated-test declares no HEALTHCHECK, so no health check ran for it."
}

@test "a rebuild that changes only the labels each run sets compares unchanged; other content does not" {
  assert_not_equal "$SERVED" "$SERVED_REBUILT"
  run same "$SERVED_REBUILT" "$SERVED"
  assert_success
  assert_output unchanged=true
  run same "$SICK" "$SERVED"
  assert_success
  assert_output unchanged=false
  run same "$RENAMED" "$SERVED"
  assert_success
  assert_output unchanged=false
}

@test "a HEALTHCHECK change alone compares as a change" {
  run same "$APP" "$CHECKED"
  assert_success
  assert_output unchanged=false
}

# index <digest> <tag>: wraps the build in an index of its one platform and prints the index's digest.
index() { crane index append -m "$REG/release/cmp@$1" -t "$REG/release/cmp:$2" >/dev/null 2>&1 && crane digest "$REG/release/cmp:$2"; }

@test "an index compares by its platforms' configs" {
  local served sick
  served=$(index "$SERVED" "index-served-$RUN")
  sick=$(index "$SICK" "index-sick-$RUN")
  run same "$served" "$SERVED_REBUILT"
  assert_success
  assert_output unchanged=true
  run same "$sick" "$SERVED"
  assert_success
  assert_output unchanged=false
}

# merge: puts a new commit on this test's main and prints it.
merge() {
  git -C "$CLONE" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m change
  git -C "$CLONE" push -q "$BATS_TEST_TMPDIR/git/acme/app" HEAD:refs/heads/main
  git -C "$CLONE" rev-parse HEAD
}

# release <commit> <run id> <digest>: runs release-action's script whole, as that run of this test's
# repository would, releasing a comparison build to this test's release repository under the
# commit's and run's tags and v-<commit>, a tag of the caller's own.
release() {
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"
  GITHUB_SERVER_URL="file://$BATS_TEST_TMPDIR/git" GITHUB_REPOSITORY=acme/app GITHUB_REF=${REF:-refs/heads/main} \
    GITHUB_SHA=$1 GITHUB_RUN_ID=$2 CANDIDATE=$REG/release/cmp RELEASE=${TO:-$RELEASE} CACHE=${CACHE:-} CACHE_DIGEST=${CACHE_DIGEST:-} \
    ALWAYS_UPDATE_CACHE=false TOKEN="" DIGEST=$3 TAGS="sha-$1"$'\n'"run-$2"$'\n'"v-$1" "$SCRIPTS/release-action/release.sh"
}

# names <tag>: the digest the tag names in this test's release repository, or nothing.
names() { "$SCRIPTS/lib/read-registry.sh" digest "$RELEASE:$1"; }

# A release test starts from an empty release repository of its own and a main with no commits.
start_releasing() {
  export RELEASE=$REG/release/rel-$RUN-$BATS_TEST_NUMBER CLONE=$BATS_TEST_TMPDIR/clone
  git init -q --bare "$BATS_TEST_TMPDIR/git/acme/app"
  git init -q "$CLONE"
}

@test "the first release is tagged, made the latest, given latest, and its cache made current" {
  start_releasing
  local one cache=$REG/cache/rel-$RUN-$BATS_TEST_NUMBER
  run crane push "$WORK/cache" "$REG/release/cmp:cache"
  assert_success
  one=$(merge)
  CACHE=$cache CACHE_DIGEST=$FIXTURE_CACHE_DIGEST run release "$one" 1 "$SERVED"
  assert_success
  run "$SCRIPTS/lib/read-registry.sh" digest "$cache:current"
  assert_output "$FIXTURE_CACHE_DIGEST"
  run step_output released
  assert_output true
  run names "sha-$one"
  assert_output "$SERVED"
  run names "v-$one"
  assert_output "$SERVED"
  run names run-1
  assert_output "$SERVED"
  run names latest
  assert_output "$SERVED"
}

@test "a build unchanged from the latest release releases nothing" {
  start_releasing
  local one two
  one=$(merge)
  run release "$one" 1 "$SERVED"
  assert_success
  two=$(merge)
  run release "$two" 2 "$SERVED_REBUILT"
  assert_success
  run step_output released
  assert_output false
  run step_output digest
  assert_output "$SERVED"
  run --separate-stderr names "sha-$two"
  assert_output ""
  run --separate-stderr names "v-$two"
  assert_output ""
  run --separate-stderr names run-2
  assert_output ""
}

@test "a run whose commit is no longer the head writes nothing" {
  start_releasing
  local one two
  one=$(merge)
  two=$(merge)
  run release "$one" 1 "$SERVED"
  assert_success
  run cat "$GITHUB_OUTPUT"
  assert_line "digest="
  run --separate-stderr "$SCRIPTS/lib/read-registry.sh" ls "$RELEASE"
  assert_success
  assert_output ""
  run cat "$GITHUB_STEP_SUMMARY"
  assert_output --partial "The branch has moved on to $two"
}

@test "a release cut short before its run tag is finished by the head's next run" {
  start_releasing
  local one two
  one=$(merge)
  run release "$one" 1 "$SERVED"
  assert_success
  two=$(merge)
  run crane copy "$REG/release/cmp@$SICK" "$RELEASE:sha-$two"
  assert_success
  run release "$two" 2 "$SICK"
  assert_success
  run step_output released
  assert_output true
  run names run-2
  assert_output "$SICK"
  run names "v-$two"
  assert_output "$SICK"
  run names latest
  assert_output "$SICK"
}

@test "a release cut short after its run tag gets latest" {
  start_releasing
  local one two
  one=$(merge)
  run release "$one" 1 "$SERVED"
  assert_success
  two=$(merge)
  run crane copy "$REG/release/cmp@$RENAMED" "$RELEASE:sha-$two"
  assert_success
  run crane tag "$RELEASE@$RENAMED" run-2
  assert_success
  run release "$two" 2 "$RENAMED"
  assert_success
  run step_output released
  assert_output true
  run names "v-$two"
  assert_output "$RENAMED"
  run names latest
  assert_output "$RENAMED"
}

@test "an earlier release of this commit, of another build, gets its missing tags; this build gets none" {
  start_releasing
  local one two
  one=$(merge)
  run release "$one" 1 "$SERVED"
  assert_success
  two=$(merge)
  run crane copy "$REG/release/cmp@$SICK" "$RELEASE:sha-$two"
  assert_success
  run release "$two" 2 "$SERVED_REBUILT"
  assert_success
  run step_output released
  assert_output false
  run step_output digest
  assert_output "$SICK"
  run names "v-$two"
  assert_output "$SICK"
  run names run-2
  assert_output "$SICK"
  run names latest
  assert_output "$SICK"
  run cat "$GITHUB_STEP_SUMMARY"
  assert_output --partial "Nothing was tagged with $SERVED_REBUILT"
}

@test "a registry that cannot be read fails rather than release" {
  start_releasing
  local one
  one=$(merge)
  TO=localhost:1/release/rel run release "$one" 1 "$SERVED"
  assert_failure
  assert_output --partial "::error::Could not read localhost:1/release/rel:sha-$one."
}

@test "a branch that does not exist fails rather than release" {
  start_releasing
  local one
  one=$(merge)
  REF=refs/heads/gone run release "$one" 1 "$SERVED"
  assert_failure
  assert_output --partial "::error::Could not read refs/heads/gone's head"
}

@test "a run on a tag fails rather than release nothing" {
  start_releasing
  local one
  one=$(merge)
  git -C "$CLONE" -c user.name=t -c user.email=t@t -c tag.gpgsign=false tag -a v1 -m v1 "$one"
  git -C "$CLONE" push -q "$BATS_TEST_TMPDIR/git/acme/app" refs/tags/v1
  REF=refs/tags/v1 run release "$one" 1 "$SERVED"
  assert_failure
  assert_output --partial "::error::refs/tags/v1 is not a branch"
}
