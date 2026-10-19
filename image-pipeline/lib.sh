# shellcheck shell=bash
# Helpers sourced by every image-pipeline script.

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "::error::the image-pipeline scripts need bash 4 or newer" >&2
  exit 1
fi

# The tag in an image's cache repository that names the cache its builds import.
# Each release moves it to that release's cache.
# shellcheck disable=SC2034 # read by the scripts that source this one
RELEASE_CACHE_TAG=current

die() {
  echo "::error::$*" >&2
  exit 1
}

# digest_of <ref>: prints the digest a reference resolves to. Returns 3 when buildx
# says the reference is not found, and 1 on anything else. buildx says the same for
# a missing repository as for a missing tag, so a misnamed repository reads as
# absent here. A denied, throttled or unreachable lookup must stop the job; read as
# "absent", it would skip a cache that exists or release over a tag that does.
digest_of() {
  local out digest err
  err=$(mktemp)
  if out=$(docker buildx imagetools inspect --format '{{json .Manifest}}' "$1" 2>"$err"); then
    digest=$(jq -r '.digest // ""' <<<"$out" 2>/dev/null) || digest=""
    if [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
      printf '%s\n' "$digest"
      return 0
    fi
    echo "buildx answered '$out' for $1, which names no digest" >&2
    return 1
  fi
  if grep -qF -- "$1: not found" "$err"; then
    return 3
  fi
  cat "$err" >&2
  return 1
}

# bake_clean <args...>: runs docker buildx bake with nothing from the job's
# environment but PATH, HOME and, when set, the docker config and builder, and with
# bake reading no variable from the environment. A bake file that names a job
# credential by mistake therefore gets nothing; review and each role's trust are what
# bound the people who write bake files.
#
# The one exception is the build secret. When BUILD_SECRET_ENV names a variable, bake
# gets it holding BUILD_SECRET, for the bake file's own env= secret to read. It goes
# first, so the pipeline's variables win if the caller picks one of their names.
# buildx hands a build an unset or empty variable as an empty secret.
bake_clean() {
  local keep=()
  if [ -n "${BUILD_SECRET_ENV:-}" ]; then keep+=("$BUILD_SECRET_ENV=${BUILD_SECRET:-}"); fi
  keep+=(PATH="$PATH" HOME="$HOME" BUILDX_BAKE_DISABLE_VARS_ENV_LOOKUP=1)
  if [ -n "${DOCKER_CONFIG:-}" ]; then keep+=(DOCKER_CONFIG="$DOCKER_CONFIG"); fi
  if [ -n "${BUILDX_BUILDER:-}" ]; then keep+=(BUILDX_BUILDER="$BUILDX_BUILDER"); fi
  env -i "${keep[@]}" docker buildx bake "$@"
}
