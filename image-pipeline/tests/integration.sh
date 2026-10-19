#!/usr/bin/env bash
# The pipeline's scripts end to end against real tools: BuildKit and buildx, and an
# OCI registry on localhost:5000. The current buildx builder must be a
# docker-container builder on the host network, which CI sets up the way the image
# workflow does. A fixture is built and tested as a pull request would be, which
# pushes nothing, then built, tested and released as a push to the default branch
# would be. Later commits show a test running on the candidate's bytes, failing tests
# failing, a test that never builds on the image refused, a full re-run leaving the
# first release standing, a build importing the released cache, and a run by hand
# building without the cache, replacing it, and the next push rebuilding the same
# image from that cache.
# shellcheck disable=SC2016 # jq programs name their --arg variables inside single quotes
set -euo pipefail
TESTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
P=$(cd "$TESTS/.." && pwd)
# shellcheck source=../lib.sh
. "$P/lib.sh"

REG=localhost:5000
CACHE_TAG=current
WORK=$(mktemp -d)

step() { printf '\n=== %s\n' "$*"; }
check() { "$@" || die "check failed: $*"; }

# absent <ref>: the registry says the reference does not exist.
absent() {
  local rc=0
  digest_of "$1" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 3 ]
}

step "Check the builder"
docker buildx inspect --bootstrap | grep -qE '^Driver: +docker-container$' ||
  die "the current buildx builder must use the docker-container driver"

step "A missing reference reads as absent; an unreachable registry is an error"
check absent "$REG/release/app:nothing"
rc=0
digest_of localhost:1/release/app:nothing >/dev/null 2>&1 || rc=$?
check [ "$rc" = 1 ]

step "Set up the fixture repository"
repo="$WORK/repo"
mkdir -p "$repo"
cp -R "$TESTS/fixture/." "$repo/"
cd "$repo"
git init -q -b main
git config user.email ci@example.invalid
git config user.name ci
git config commit.gpgsign false
git add -A
git commit -qm base
jq -n --arg r "$REG" '[{target: "app", test: "app-test", replaces: "runtime",
  candidate: "\($r)/candidate/app", release: "\($r)/release/app", cache: "\($r)/cache/app"}]' >"$WORK/targets.json"
"$P/targets.sh" "$(cat "$WORK/targets.json")" >/dev/null
"$P/resolve.sh" docker-bake.hcl "$WORK/targets.json" >"$WORK/resolved.json"
check jq -e '[.target.app.attest[] | .disabled] | length == 2 and all' "$WORK/resolved.json"

step "A pull request builds and tests, and pushes nothing"
"$P/build.sh" "$WORK/targets.json" "$WORK/resolved.json" pr true 100 1 "$WORK/pr" >"$WORK/pr.out"
check [ ! -s "$WORK/pr.out" ]
catalog=$(curl -fsS "http://$REG/v2/_catalog")
if jq -e '.repositories // [] | index("candidate/app") != null' <<<"$catalog" >/dev/null; then
  die "a pull request's build pushed to the candidate repository"
fi

step "A pull request whose test fails fails"
git checkout -qb failing main
echo v2 >app/version
git commit -qam v2
if "$P/build.sh" "$WORK/targets.json" "$WORK/resolved.json" pr true 100 1 "$WORK/pr-failing" >/dev/null 2>"$WORK/pr-failing.log"; then
  die "a pull request whose image is v2 passed a test that requires v1"
fi
check grep -q 'sh /check.sh" did not complete successfully: exit code: 1' "$WORK/pr-failing.log"
git checkout -q main

step "A push to the default branch builds and pushes by digest, and tests that digest"
M1=$(git rev-parse HEAD)
"$P/build.sh" "$WORK/targets.json" "$WORK/resolved.json" push true 101 1 "$WORK/m1" >"$WORK/m1.json"
D1=$(jq -r .targets.app.digest "$WORK/m1.json")
C1=$(jq -r .targets.app.cache_digest "$WORK/m1.json")
check [ "$(digest_of "$REG/candidate/app@$D1")" = "$D1" ]
check [ "$(digest_of "$REG/candidate/app@$C1")" = "$C1" ]
check [ "$(digest_of "$REG/candidate/app:cache-101-1")" = "$C1" ]
"$P/test.sh" "$WORK/resolved.json" app-test runtime "$REG/candidate/app@$D1" "$WORK/m1"

step "The release copies the tested digest and its cache"
"$P/release-target.sh" "$WORK/targets.json" "$WORK/m1.json" app "$M1" 101 >"$WORK/m1-release.json"
check jq -e --arg d "$D1" '.digest == $d and .copied == ["image", "run", "cache"]' "$WORK/m1-release.json"
check [ "$(digest_of "$REG/release/app:sha-$M1")" = "$D1" ]
check [ "$(digest_of "$REG/release/app:run-101")" = "$D1" ]
check [ "$(digest_of "$REG/cache/app:$CACHE_TAG")" = "$C1" ]

step "Releasing again copies nothing"
"$P/release-target.sh" "$WORK/targets.json" "$WORK/m1.json" app "$M1" 101 >"$WORK/m1-again.json"
check jq -e '.copied == []' "$WORK/m1-again.json"

step "The test runs on the candidate's bytes, not a local build of the stage it replaces"
git checkout -qb v2 main
echo v2 >app/version
git commit -qam v2
"$P/test.sh" "$WORK/resolved.json" app-test runtime "$REG/candidate/app@$D1" "$WORK/v2"

step "A test that fails on the pushed digest fails"
"$P/build.sh" "$WORK/targets.json" "$WORK/resolved.json" push true 102 1 "$WORK/v2" >"$WORK/v2.json"
D2=$(jq -r .targets.app.digest "$WORK/v2.json")
if "$P/test.sh" "$WORK/resolved.json" app-test runtime "$REG/candidate/app@$D2" "$WORK/v2" 2>"$WORK/v2-test.log"; then
  die "an image of version v2 passed a test that requires v1"
fi
check grep -q 'sh /check.sh" did not complete successfully: exit code: 1' "$WORK/v2-test.log"

step "A full re-run of the released commit leaves the first release and the cache standing"
"$P/release-target.sh" "$WORK/targets.json" "$WORK/v2.json" app "$M1" 102 >"$WORK/rerun.json"
check jq -e --arg d "$D1" '.digest == $d and .copied == []' "$WORK/rerun.json"
check [ "$(digest_of "$REG/cache/app:$CACHE_TAG")" = "$C1" ]
check absent "$REG/release/app:run-102"

step "A test stage that does not build on the image is refused, though its build passes"
jq '.[0].test = "app-unrelated-test"' "$WORK/targets.json" >"$WORK/targets-unrelated.json"
"$P/resolve.sh" docker-bake.hcl "$WORK/targets-unrelated.json" >"$WORK/resolved-unrelated.json"
if "$P/test.sh" "$WORK/resolved-unrelated.json" app-unrelated-test runtime "$REG/candidate/app@$D1" "$WORK/v2" 2>"$WORK/unrelated.log"; then
  die "a test stage that never built on the image passed as a test of it"
fi
check grep -q "never built on the image under test" "$WORK/unrelated.log"

step "An image that does not build the stage its test replaces is refused before building"
jq '.[0].replaces = "unrelated"' "$WORK/targets.json" >"$WORK/targets-mismatch.json"
if "$P/resolve.sh" docker-bake.hcl "$WORK/targets-mismatch.json" >/dev/null 2>"$WORK/mismatch.log"; then
  die "an image whose stage is not the replaced one resolved"
fi
check grep -q "the two must be the same stage" "$WORK/mismatch.log"
git checkout -q main

step "A later push that changes only the test imports the released cache"
echo "# still v1" >>app/check.sh
git commit -qam "test only"
docker buildx prune --all --force >/dev/null
"$P/build.sh" "$WORK/targets.json" "$WORK/resolved.json" push true 103 1 "$WORK/m3" >"$WORK/m3.json" 2>"$WORK/m3.log"
vertex=$(grep -oE '^#[0-9]+ \[runtime +3/3\] RUN' "$WORK/m3.log" | head -1 | cut -d' ' -f1)
check [ -n "$vertex" ]
check grep -qx "$vertex CACHED" "$WORK/m3.log"

step "A run by hand builds every step without the cache, keeps the commit's release, and replaces the cache"
docker buildx prune --all --force >/dev/null
"$P/build.sh" "$WORK/targets.json" "$WORK/resolved.json" push false 104 1 "$WORK/m4" >"$WORK/m4.json" 2>"$WORK/m4.log"
check jq -e '.fresh == true' "$WORK/m4.json"
# The base image is pinned by digest, so the builder's own copy of it is the same bytes
# a pull would fetch; every step after it must run.
cached=$(awk '/^#[0-9]+ \[/ && !/\] FROM / { name[$1] = $0 } /^#[0-9]+ CACHED$/ && ($1 in name) { print name[$1] }' "$WORK/m4.log")
[ -z "$cached" ] || die "a build without the cache took steps from a cache: $cached"
D4=$(jq -r .targets.app.digest "$WORK/m4.json")
C4=$(jq -r .targets.app.cache_digest "$WORK/m4.json")
check [ "$D4" != "$D1" ]
"$P/release-target.sh" "$WORK/targets.json" "$WORK/m4.json" app "$M1" 104 >"$WORK/m4-release.json"
check jq -e --arg d "$D1" '.digest == $d and .copied == ["cache"]' "$WORK/m4-release.json"
check [ "$(digest_of "$REG/release/app:sha-$M1")" = "$D1" ]
check absent "$REG/release/app:run-104"
check [ "$(digest_of "$REG/cache/app:$CACHE_TAG")" = "$C4" ]

step "The next push imports the fresh cache and rebuilds the image the run by hand built"
docker buildx prune --all --force >/dev/null
"$P/build.sh" "$WORK/targets.json" "$WORK/resolved.json" push true 105 1 "$WORK/m5" >"$WORK/m5.json"
check [ "$(jq -r .targets.app.digest "$WORK/m5.json")" = "$D4" ]

step "A build reads the build secret only under the name the caller gives it"
export FIXTURE_TOKEN=from-the-job
if bake_clean -f docker-bake.hcl --progress=plain secret-check >/dev/null 2>"$WORK/secret-unnamed.log"; then
  die "a build read a job variable the caller never named as the build secret"
fi
BUILD_SECRET_ENV=FIXTURE_TOKEN BUILD_SECRET=s3cret bake_clean -f docker-bake.hcl --progress=plain secret-check >/dev/null 2>"$WORK/secret.log" ||
  die "a build could not read the build secret its caller named"
unset FIXTURE_TOKEN

step "A served image passes its health check on a pull request and on a push, with no network and none of the job's environment"
export FIXTURE_JOB_VAR=from-the-job
jq -n --arg r "$REG" '[{target: "served", test: "served-test", replaces: "served",
  candidate: "\($r)/candidate/served", release: "\($r)/release/served", cache: "\($r)/cache/served"}]' >"$WORK/served.json"
"$P/resolve.sh" docker-bake.hcl "$WORK/served.json" >"$WORK/served-resolved.json"
"$P/build.sh" "$WORK/served.json" "$WORK/served-resolved.json" pr false 200 1 "$WORK/served-pr" >/dev/null
"$P/health.sh" "$WORK/served.json" "$WORK/served-resolved.json" pr "$WORK/served-pr" >"$WORK/served-pr.out"
check [ ! -s "$WORK/served-pr.out" ]
"$P/build.sh" "$WORK/served.json" "$WORK/served-resolved.json" push false 201 1 "$WORK/served-push" >"$WORK/served-push.json"
"$P/health.sh" "$WORK/served.json" "$WORK/served-resolved.json" push "$WORK/served-push" "$WORK/served-push.json" >"$WORK/served-push.out"
check [ ! -s "$WORK/served-push.out" ]
unset FIXTURE_JOB_VAR

step "An image that does not ship the runner's platform warns, and runs nothing"
jq '.target.served.platforms = ["linux/s390x"]' "$WORK/served-resolved.json" >"$WORK/served-elsewhere.json"
"$P/health.sh" "$WORK/served.json" "$WORK/served-elsewhere.json" push "$WORK/served-push" "$WORK/served-push.json" >"$WORK/elsewhere.out"
check grep -q '^::warning::served ships \["linux/s390x"\]' "$WORK/elsewhere.out"

step "An image that turns unhealthy fails its health run"
jq '.[0] |= (.target = "sick" | .test = "sick-test" | .replaces = "sick")' "$WORK/served.json" >"$WORK/sick.json"
"$P/resolve.sh" docker-bake.hcl "$WORK/sick.json" >"$WORK/sick-resolved.json"
"$P/build.sh" "$WORK/sick.json" "$WORK/sick-resolved.json" pr false 202 1 "$WORK/sick-pr" >/dev/null
if "$P/health.sh" "$WORK/sick.json" "$WORK/sick-resolved.json" pr "$WORK/sick-pr" >/dev/null 2>"$WORK/sick.log"; then
  die "an image whose health check never passes passed its health run"
fi
check grep -q "sick did not become healthy" "$WORK/sick.log"

step "An image that declares no health check warns, and runs nothing"
"$P/health.sh" "$WORK/targets.json" "$WORK/resolved.json" push "$WORK/m1" "$WORK/m1.json" >"$WORK/app-health.out"
check grep -q '^::warning::app declares no HEALTHCHECK' "$WORK/app-health.out"

step "integration passed"
