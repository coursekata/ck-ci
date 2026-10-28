include "platform";

# What check-targets.sh makes of a bake definition, as `bake --print` prints it for the image and
# test targets: {stage, platforms} for the steps after it, or {error}, which fails the build before
# anything builds.
def check($image; $test):
  def stage($n): .target[$n].target // "";
  def platforms($n): .target[$n].platforms // [] | map(norm) | unique;
  [
    # build-action sets every cache and output, so the bake file's own would bypass the release
    # cache or send bytes out before the checks.
    (($image, $test) as $n | ("cache-from", "cache-to", "output") as $k
      | select(.target[$n][$k] // [] | length > 0)
      | "The bake target `\($n)` sets \($k). build-action sets every cache and output itself, so a build reads only the release cache and nothing leaves the runner before push-action: remove cache-from, cache-to and output from the bake file's image and test targets."),
    # The tests run with the built image swapped in for this stage, so the target must name it.
    if stage($image) == "" then
      "The app's bake target `\($image)` names no stage to build to. Give it target = \"<stage>\", so the test bake target `\($test)` can build from it."
    else empty end,
    # A test target with no stage of its own would rebuild the image and run no tests.
    if stage($test) == "" then
      "The test bake target `\($test)` names no stage to build to. A test layer is required, and it must build from the stage that the `\($image)` target builds to."
    elif stage($test) == stage($image) then
      "The test bake target `\($test)` builds to the same stage as the app's bake target `\($image)`. A test layer is required, and it must build from the stage that the `\($image)` target builds to."
    else empty end,
    # A platform the image ships but its tests don't build would ship untested.
    if platforms($image) != platforms($test) then
      "The app's bake target `\($image)` ships \(platforms($image) | tojson), but the test bake target `\($test)` builds for \(platforms($test) | tojson). Every platform the image ships must be tested."
    else empty end
  ] as $errors
  | if $errors != [] then {error: $errors[0]} else {stage: stage($image), platforms: platforms($image)} end;
