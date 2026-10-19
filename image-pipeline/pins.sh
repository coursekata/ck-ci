# shellcheck shell=bash disable=SC2034 # read by the scripts and workflows that source this file
# Tool pins for the image pipeline. The workflow hands both to
# docker/setup-buildx-action, and buildx does every registry operation, so nothing
# else is installed.

BUILDKIT_IMAGE="moby/buildkit:v0.34.0@sha256:b059f8d7226d0b326bc871af489a5dddf65e36af4d20d14251b072974d9ee87c"

BUILDX_VERSION="v0.38.0"
