# release.jq's decisions, on plain data: facts in, a plan or a summary out. Nothing here reads a
# registry, a repository or the environment.
# shellcheck disable=SC2016 # the updates are jq, and $A, $B and $C are jq's
load helper

A=sha256:$(printf '%064x' 1)
B=sha256:$(printf '%064x' 2)
C=sha256:$(printf '%064x' 3)
K=sha256:$(printf '%064x' 4)

# facts [<jq update>]: a head run releasing a changed build A, with B the latest release and latest
# and K the build's cache, then the update applied.
facts() {
  jq -n --arg A "$A" --arg B "$B" --arg K "$K" '{head: true, branch_head: "abc", release: "r.example/release",
    candidate_repository: "r.example/candidate", candidate: $A, sha_tag: "sha-abc", run_tag: "run-7",
    tags: [{name: "sha-abc", digest: null}, {name: "run-7", digest: null}],
    latest: {tag: "run-6", digest: $B, commit: "def"}, latest_tag: $B, unchanged: false,
    cache: {repository: "r.example/cache", digest: $K}, always_update_cache: false}' |
    jq --arg A "$A" --arg B "$B" --arg C "$C" "${1:-.}"
}
release() { jq -L "$SCRIPTS" "$@"; }

# plan_of [<jq update>]: the plan for those facts, compact.
plan_of() { facts "$@" | release -c 'include "release"; plan'; }

# summary_of [<jq update>]: the summary for those facts and their plan.
summary_of() { facts "$@" | release -r 'include "release"; summary(plan)'; }

# has <plan> <jq expression>: the plan satisfies the expression.
has() { jq -e "$2" <<<"$1" >/dev/null || fail "plan $1 does not satisfy $2"; }

@test "the latest release is the highest run tag, by number, not by text" {
  run release -rn 'include "release"; ["run-9", "run-10", "run-100", "sha-abc", "latest", "run-x", "run-3-old"] | latest_run'
  assert_output run-100
}

@test "a repository with no run tag holds no release" {
  run release -rn 'include "release"; ["sha-abc", "latest"], [] | latest_run'
  assert_output $'null\nnull'
}

@test "a changed build is copied under every tag but the run tag, then made the latest release, latest and cache" {
  p=$(plan_of)
  has "$p" '.kind == "new" and .target == "'"$A"'"'
  has "$p" '.copy == ["sha-abc"] and .order and .released and .move_latest and .move_cache'
  has "$p" '.named == ["sha-abc", "run-7"]'
}

@test "the first release, with no latest release, is made the latest" {
  p=$(plan_of '.latest = null | .latest_tag = null | .unchanged = null')
  has "$p" '.kind == "new" and .copy == ["sha-abc"] and .order and .move_latest'
}

@test "every extra tag is copied with the commit's, in the caller's order" {
  p=$(plan_of '.tags += [{name: "v1", digest: null}]')
  has "$p" '.copy == ["sha-abc", "v1"]'
}

@test "an unchanged build writes nothing and names no tag" {
  p=$(plan_of '.unchanged = true')
  has "$p" '.kind == "unchanged" and .target == "'"$B"'"'
  has "$p" '.copy == [] and (.order | not) and (.released | not) and (.move_latest | not) and (.move_cache | not)'
  has "$p" '.named == []'
}

@test "an unchanged build repairs a latest left behind" {
  p=$(plan_of '.unchanged = true | .latest_tag = $C')
  has "$p" '.move_latest and (.order | not)'
}

@test "an unchanged build made without the cache moves the cache and nothing else" {
  p=$(plan_of '.unchanged = true | .always_update_cache = true')
  has "$p" '.copy == [] and (.order | not) and .move_cache'
}

@test "with no cache repository the cache never moves" {
  p=$(plan_of '.cache = null | .always_update_cache = true')
  has "$p" '.move_cache | not'
}

@test "a release cut short before its run tag gets it" {
  p=$(plan_of '.tags[0].digest = $A | .unchanged = null')
  has "$p" '.kind == "finish" and .target == "'"$A"'" and .copy == [] and .order and .released and .move_cache'
}

@test "a release cut short after its run tag gets latest, and no second run tag" {
  p=$(plan_of '.tags[].digest = $A | .latest = {tag: "run-7", digest: $A, commit: null} | .unchanged = null')
  has "$p" '.kind == "finish" and .copy == [] and (.order | not) and .released and .move_latest'
}

@test "an earlier release of this commit that is the latest stands, and this build is written nowhere" {
  p=$(plan_of '.tags = [{name: "sha-abc", digest: $B}, {name: "run-7", digest: null}] | .unchanged = null')
  has "$p" '.kind == "earlier" and .target == "'"$B"'" and .copy == [] and (.order | not) and (.move_cache | not)'
  has "$p" '.named == ["sha-abc"]'
}

@test "an earlier release of this commit cut short before its run tag is made the latest with this run's" {
  p=$(plan_of '.tags[0].digest = $C | .unchanged = null')
  has "$p" '.kind == "earlier" and .target == "'"$C"'" and .copy == [] and .order and (.released | not) and (.move_cache | not)'
  has "$p" '.named == ["sha-abc", "run-7"]'
}

@test "an earlier release of this commit cut short gets the tags still missing, on that release" {
  p=$(plan_of '.tags = [{name: "sha-abc", digest: $B}, {name: "run-7", digest: null}, {name: "v1", digest: null}] | .unchanged = null')
  has "$p" '.kind == "earlier" and .target == "'"$B"'" and .copy == ["v1"] and (.order | not) and (.move_cache | not)'
  has "$p" '.named == ["sha-abc", "v1"]'
}

@test "an earlier release fails when one of its tags names another image" {
  p=$(plan_of '.tags = [{name: "sha-abc", digest: $B}, {name: "run-7", digest: null}, {name: "v1", digest: $C}] | .unchanged = null')
  has "$p" '.error | startswith("r.example/release:v1 already names")'
}

@test "a release whose run tag a re-run already wrote gets no second one, though a higher run is the latest" {
  p=$(plan_of '.tags[].digest = $A | .latest = {tag: "run-9", digest: $C, commit: null} | .latest_tag = $C | .unchanged = null')
  has "$p" '.kind == "finish" and .copy == [] and (.order | not) and .released and .move_latest'
}

@test "an earlier release with no release the latest is made the latest" {
  p=$(plan_of '.tags[0].digest = $C | .latest = null | .unchanged = null')
  has "$p" '.order'
}

@test "a run by hand moves the cache though an earlier release stands" {
  p=$(plan_of '.tags[0].digest = $B | .always_update_cache = true | .unchanged = null')
  has "$p" '(.order | not) and .move_cache'
}

@test "a new release copies the build in once, tags it, then orders it, moves latest and the cache" {
  p=$(plan_of '.tags += [{name: "v1", digest: null}]')
  has "$p" '.writes == [
    {op: "copy", from: "r.example/candidate@'"$A"'", to: "r.example/release:sha-abc"},
    {op: "tag", from: "r.example/release@'"$A"'", to: "v1"},
    {op: "tag", from: "r.example/release@'"$A"'", to: "run-7"},
    {op: "tag", from: "r.example/release@'"$A"'", to: "latest"},
    {op: "copy", from: "r.example/candidate@'"$K"'", to: "r.example/cache:current"}]'
}

@test "an earlier release gets its missing tags and the run tag from itself, never from this build" {
  p=$(plan_of '.tags = [{name: "sha-abc", digest: $C}, {name: "run-7", digest: null}, {name: "v1", digest: null}] | .unchanged = null')
  has "$p" '.writes == [
    {op: "tag", from: "r.example/release@'"$C"'", to: "v1"},
    {op: "tag", from: "r.example/release@'"$C"'", to: "run-7"},
    {op: "tag", from: "r.example/release@'"$C"'", to: "latest"}]'
}

@test "a build with the latest release's own digest is unchanged, though not compared" {
  p=$(plan_of '.latest.digest = $A | .latest_tag = $A | .unchanged = null')
  has "$p" '.kind == "unchanged" and .writes == [] and (.released | not)'
}

@test "a released commit is finished, not judged unchanged, whatever the comparison said" {
  p=$(plan_of '.tags[0].digest = $A | .unchanged = true')
  has "$p" '.kind == "finish" and .order and .released'
}

@test "an unchanged build writes no tags, so a tag that names another image does not fail it" {
  p=$(plan_of '.unchanged = true | .tags += [{name: "v1", digest: $C}]')
  has "$p" '.kind == "unchanged" and .copy == [] and .named == []'
}

@test "a run whose commit is no longer the head writes nothing" {
  p=$(plan_of '.head = false')
  has "$p" '.kind == "behind" and .target == null and .writes == [] and (.released | not)'
}

@test "a tag that names another image fails, since release tags never move" {
  p=$(plan_of '.tags += [{name: "main", digest: $C}]')
  has "$p" '.error == "r.example/release:main already names '"$C"', not this image '"$A"', and a release tag can'"'"'t be moved. Every tag must be new to each release."'
}

@test "this run's tag naming another image fails" {
  p=$(plan_of '.tags = [{name: "sha-abc", digest: $C}, {name: "run-7", digest: $B}] | .latest.digest = $A')
  has "$p" '.error | startswith("r.example/release:run-7 already names")'
}

@test "tags that include latest fail, since the release moves it after the run tag" {
  p=$(plan_of '.tags += [{name: "latest", digest: null}]')
  has "$p" '.error == "The tags must not include latest, which the release moves itself after the run tag."'
}

@test "tags without the commit's tag, or this run's, fail" {
  p=$(plan_of '.tags = [{name: "run-7", digest: null}]')
  has "$p" '.error == "The tags must include sha-abc, which marks this commit as released."'
  p=$(plan_of '.tags = [{name: "sha-abc", digest: null}]')
  has "$p" '.error == "The tags must include run-7, which orders this release."'
}

@test "the summary names the release, every tag on it, and where latest moved from" {
  run summary_of
  assert_output "### Image release

Released \`$A\`. \`latest\` moved to it from \`$B\`. This build's cache is now current.

| Tag |
|---|
| r.example/release:sha-abc |
| r.example/release:run-7 |"
}

@test "the summary says when the repository held no release" {
  run summary_of '.latest = null | .latest_tag = null | .unchanged = null | .cache = null'
  assert_line "Released \`$A\`. The release repository held no release, so this image releases as new. \`latest\` now names it."
}

@test "the summary names the release an unchanged build matched, by commit when it has one" {
  run summary_of '.unchanged = true'
  assert_output "### Image release

Unchanged from the latest release, sha-def (\`$B\`), apart from build metadata. Nothing new was released."
  run summary_of '.unchanged = true | .latest.commit = null | .latest_tag = $C'
  assert_line "Unchanged from the latest release \`$B\` apart from build metadata. Nothing new was released. \`latest\` moved to it from \`$C\`."
}

@test "the summary says when an earlier release stands, or this run finished it" {
  run summary_of '.tags[0].digest = $B | .unchanged = null'
  assert_line "This commit's release is \`$B\`. An earlier release stands. Nothing was tagged with $A."
  assert_line "| r.example/release:sha-abc |"
  refute_line "| r.example/release:run-7 |"
  run summary_of '.tags[0].digest = $C | .unchanged = null'
  assert_line "This commit's release is \`$C\`. An earlier release of this commit was cut short before its run tag, and this run finished it. Nothing was tagged with $A. \`latest\` moved to it from \`$B\`."
}

@test "the summary of a run no longer the head names the head that releases" {
  run summary_of '.head = false'
  assert_output "### Image release

The branch has moved on to abc, whose run releases its changes. This run released nothing."
}

# config [<jq update>]: one platform's config as a registry returns it, with every field a build
# sets afresh, then the update applied.
config() {
  jq -n '{architecture: "arm64", os: "linux", created: "2026-10-27T00:00:00Z",
    config: {Cmd: ["serve"], Labels: {"org.opencontainers.image.created": "2026-10-27T00:00:00Z",
      "org.opencontainers.image.revision": "def", "org.opencontainers.image.version": "sha-def", "team": "web"}},
    rootfs: {type: "layers", diff_ids: ["sha256:aa"]},
    history: [{created: "2026-10-27T00:00:00Z", created_by: "COPY f /f # buildkit"}]}' | jq "${1:-.}"
}

# compare_of <build update> <release update>: the comparison of one-platform builds so changed.
compare_of() {
  local build release
  build=$(config "$1" | jq '{"linux/arm64": .}')
  release=$(config "$2" | jq '{"linux/arm64": .}')
  release -c --argjson r "$release" 'include "release"; compare($r)' <<<"$build"
}

@test "a rebuild that differs only in what every build sets afresh is unchanged, and names the release's commit" {
  run compare_of '.created = "2026-10-28T00:00:00Z" | .history[0].created = "2026-10-28T00:00:00Z"
    | .config.Labels["org.opencontainers.image.created"] = "x" | .config.Labels["org.opencontainers.image.revision"] = "abc"
    | .config.Labels["org.opencontainers.image.version"] = "sha-abc"' .
  assert_output '{"unchanged":true,"revision":"def"}'
}

@test "any other label is a change" {
  run compare_of '.config.Labels.team = "api"' .
  assert_output '{"unchanged":false,"revision":"def"}'
}

@test "a HEALTHCHECK alone is a change" {
  run compare_of '.config.Healthcheck = {Test: ["CMD", "true"]} | .history += [{created_by: "HEALTHCHECK", empty_layer: true}]' .
  assert_output --partial '"unchanged":false'
}

@test "another layer is a change" {
  run compare_of '.rootfs.diff_ids = ["sha256:bb"]' .
  assert_output --partial '"unchanged":false'
}

@test "another set of platforms is a change" {
  run release -c --argjson r "$(config | jq '{"linux/arm64": .}')" 'include "release"; compare($r)' \
    <<<"$(config | jq '{"linux/arm64": ., "linux/amd64": (.architecture = "amd64")}')"
  assert_output --partial '"unchanged":false'
}

@test "a release with no revision label names no commit" {
  run compare_of . 'del(.config.Labels["org.opencontainers.image.revision"])'
  assert_output '{"unchanged":true,"revision":null}'
}
