load helper

A=sha256:$(printf '%064x' 1)
B=sha256:$(printf '%064x' 2)

setup() {
  fresh_state
  export DIGEST=$A RELEASED=$A EARLIER="" UNCHANGED=false BASELINE=$B BASELINE_COMMIT="" CACHE_MOVED=false NAMED=$'r.example/release:sha-abc\nr.example/release:run-7'
}

@test "lists the released digest and every tag that names it" {
  run "$SCRIPTS/summarize.sh"
  assert_success
  run summary
  assert_output "### Image release

Released \`$A\`.

| Tag |
|---|
| r.example/release:sha-abc |
| r.example/release:run-7 |"
}

@test "says when the cache moved" {
  export CACHE_MOVED=true
  run "$SCRIPTS/summarize.sh"
  run summary
  assert_line "Released \`$A\`. This build's cache is now current."
}

@test "says when an earlier release stands, and lists only the tags that name it" {
  export RELEASED=$B EARLIER=$B NAMED=r.example/release:sha-abc
  run "$SCRIPTS/summarize.sh"
  run summary
  assert_line "Released \`$B\`. An earlier release stands. Nothing was tagged with $A."
  assert_line "| r.example/release:sha-abc |"
  refute_line "| r.example/release:run-7 |"
}

@test "says when the cache moved though an earlier release stands" {
  export RELEASED=$B EARLIER=$B CACHE_MOVED=true
  run "$SCRIPTS/summarize.sh"
  run summary
  assert_line "Released \`$B\`. An earlier release stands. Nothing was tagged with $A. This build's cache is now current."
}

@test "says nothing of the cache when it did not move" {
  export RELEASED=$B EARLIER=$B
  run "$SCRIPTS/summarize.sh"
  run summary
  assert_line "Released \`$B\`. An earlier release stands. Nothing was tagged with $A."
}

@test "says when the image is unchanged from the newest release, naming its commit, and lists no tags" {
  export UNCHANGED=true RELEASED=$B BASELINE_COMMIT=def NAMED=""
  run "$SCRIPTS/summarize.sh"
  assert_success
  run summary
  assert_line "Unchanged from the newest release, sha-def (\`$B\`), apart from build metadata. Nothing was released or tagged."
  refute_line --partial "Released"
  refute_line --partial "| r.example"
}

@test "names the unchanged baseline by digest alone when it carries no revision label" {
  export UNCHANGED=true RELEASED=$B NAMED=""
  run "$SCRIPTS/summarize.sh"
  run summary
  assert_line "Unchanged from the newest release \`$B\` apart from build metadata. Nothing was released or tagged."
}

@test "says when the cache moved though the image is unchanged" {
  export UNCHANGED=true RELEASED=$B BASELINE_COMMIT=def NAMED="" CACHE_MOVED=true
  run "$SCRIPTS/summarize.sh"
  run summary
  assert_line "Unchanged from the newest release, sha-def (\`$B\`), apart from build metadata. Nothing was released or tagged. This build's cache is now current."
}

@test "says when no baseline was given, so the image released as new" {
  export BASELINE=""
  run "$SCRIPTS/summarize.sh"
  assert_success
  run summary
  assert_line "Released \`$A\`. No baseline was given, so this image releases as new."
}
