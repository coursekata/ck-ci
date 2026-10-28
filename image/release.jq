# Every decision release.sh makes, as functions of what it read; none reads or writes anything.
# Facts, which release.sh gathers:
#   head, branch_head     whether this run's commit is still the branch's head, and the head
#   release               the release repository
#   candidate_repository, candidate
#                         the repository the build was pushed to, and its digest
#   sha_tag, run_tag      this commit's and this run's tag names
#   tags                  [{name, digest}]: each tag the caller asked for, and what it names now
#   latest                {tag, digest, commit} of the latest release, or null
#   latest_tag            what the latest tag names now, or null
#   unchanged             whether the build matches the latest release, or null if not compared
#   cache                 {repository, digest} of the cache to make current, or null
#   always_update_cache   whether to move the cache whatever the release does

# The highest run-<id> among tag names, or null. Run ids only increase; commit hashes do not sort.
def latest_run: [.[] | select(test("^run-[0-9]+$"))] | max_by(ltrimstr("run-") | tonumber);

def ref($f): "\($f.release):\(.)";

# Configs keyed by platform, as read-configs.sh prints them, with what every build sets afresh
# removed: the creation times, each history entry's time, and the created, revision and version
# labels. What stays is the layers' content digests, every instruction's history entry and the
# runtime settings, a HEALTHCHECK among them, and any other label.
def normal:
  map_values(del(.created)
    | .history |= (if . then map(del(.created)) else . end)
    | .config.Labels |= (if . then del(.["org.opencontainers.image.created"], .["org.opencontainers.image.revision"], .["org.opencontainers.image.version"]) else . end));

# Whether a build's configs match a release's apart from build metadata, and the commit the release
# names in its revision label. Another set of platforms is a change.
def compare($release):
  {unchanged: ((normal) == ($release | normal)),
   revision: ([$release[] | .config.Labels["org.opencontainers.image.revision"] // empty] | first)};

# The plan's writes as crane makes them, in order: {op, from, to}. copy puts the image at from in
# another repository under the reference to; tag gives the image at from the tag to in its own
# repository. A new release's first tag copies the build into the release repository; every other
# tag names an image already there, so a release never mixes images.
def writes($f):
  . as $p
  | "\($f.release)@\($p.target)" as $here
  | [($p.copy | to_entries[]
       | if $p.kind == "new" and .key == 0 then {op: "copy", from: "\($f.candidate_repository)@\($f.candidate)", to: (.value | ref($f))}
         else {op: "tag", from: $here, to: .value} end),
     (if $p.order then {op: "tag", from: $here, to: $f.run_tag} else empty end),
     (if $p.move_latest then {op: "tag", from: $here, to: "latest"} else empty end),
     (if $p.move_cache then {op: "copy", from: "\($f.candidate_repository)@\($f.cache.digest)", to: "\($f.cache.repository):current"} else empty end)];

# What the release does: copy (the missing tags, put on the target), order (whether the target gets
# the run tag, which makes it the latest release), move_latest, move_cache, and writes, all of them
# in the order release.sh makes them. named lists the tags on the release, for the summary, and
# released says whether this build is this commit's release.
# A release becomes the latest only with its run tag, written after its other tags and before
# latest, so the head's next run finishes a release cut short at any point. kind says which case
# this is: new, finish (this build was released already, in full or cut short), earlier (another
# build of this commit was released), unchanged, or behind (no longer the head). error, when set,
# fails the release.
def plan:
  . as $f
  | ($f.tags | map({key: .name, value: .digest}) | from_entries) as $now
  | if ($f.head | not) then
      {kind: "behind", target: null, copy: [], order: false, move_latest: false, move_cache: false, writes: [],
       named: [], released: false}
    elif ($now | has($f.sha_tag) | not) then
      {error: "The tags must include \($f.sha_tag), which marks this commit as released."}
    elif ($now | has($f.run_tag) | not) then
      {error: "The tags must include \($f.run_tag), which orders this release."}
    elif ($now | has("latest")) then
      {error: "The tags must not include latest, which the release moves itself after the run tag."}
    else
      # A build with the latest release's very digest matches it without a comparison.
      ($f.unchanged == true or ($f.latest != null and $f.latest.digest == $f.candidate)) as $unchanged
      | (if $now[$f.sha_tag] == null and $unchanged then {kind: "unchanged", target: $f.latest.digest}
         elif $now[$f.sha_tag] == null then {kind: "new", target: $f.candidate}
         elif $now[$f.sha_tag] == $f.candidate then {kind: "finish", target: $f.candidate}
         else {kind: "earlier", target: $now[$f.sha_tag]}
         end) as $p
      | ($p.kind == "new" or $p.kind == "finish") as $this_build
      | ($p.kind != "unchanged") as $tagging
      | [$f.tags[] | select(.digest != null and .digest != $p.target)] as $taken
      | ($p.target != $f.latest.digest) as $order
      | if $tagging and ($taken | length) > 0 then
          {error: ($taken[0] | "\(.name | ref($f)) already names \(.digest), not this image \($p.target), and a release tag can't be moved. Every tag must be new to each release.")}
        else
          $p + {
            copy: (if $tagging then [$f.tags[] | select(.digest == null and .name != $f.run_tag) | .name] else [] end),
            order: ($order and $now[$f.run_tag] != $p.target),
            move_latest: ($f.latest_tag != $p.target),
            move_cache: ($f.cache != null and ($this_build or $f.always_update_cache)),
            named: (if $tagging then [$f.tags[] | select(.digest == $p.target or (.digest == null and (.name != $f.run_tag or $order))) | .name]
                    else [] end),
            released: $this_build
          }
          | .writes = writes($f)
        end
    end;

# The step summary, from the facts and their plan.
def summary($p):
  . as $f
  | "### Image release\n\n"
  + if $p.kind == "behind" then
      "The branch has moved on to \($f.branch_head), whose run releases its changes. This run released nothing.\n"
    else
      ((if $p.kind == "unchanged" then
          "Unchanged from the latest release"
          + (if $f.latest.commit then ", sha-\($f.latest.commit) (`\($p.target)`)," else " `\($p.target)`" end)
          + " apart from build metadata. Nothing new was released."
        elif $p.released then "Released `\($p.target)`."
        else "This commit's release is `\($p.target)`." end)
       + (if $p.kind == "earlier" and $p.order then " An earlier release of this commit was cut short before its run tag, and this run finished it. Nothing was tagged with \($f.candidate)."
          elif $p.kind == "earlier" then " An earlier release stands. Nothing was tagged with \($f.candidate)."
          elif $p.kind == "new" and $f.latest == null then " The release repository held no release, so this image releases as new."
          else "" end)
       + (if $p.move_latest | not then ""
          elif $f.latest_tag == null then " `latest` now names it."
          else " `latest` moved to it from `\($f.latest_tag)`." end)
       + (if $p.move_cache then " This build's cache is now current." else "" end)
       + "\n")
      + (if ($p.named | length) == 0 then ""
         else "\n| Tag |\n|---|\n" + ($p.named | map("| \(ref($f)) |\n") | add) end)
    end;
