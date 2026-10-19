#!/bin/sh
# The fixture's test: passes only on an image built from version v1.
grep -qx v1 /app/version
