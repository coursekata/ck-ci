FROM busybox:1.37.0-musl@sha256:5cec3fc171c87218698e85a52af7087de727372aae264a787b8112901a5b0092 AS runtime
COPY version /app/version
RUN echo "built $(cat /app/version)"
USER nobody
# A build fixture, not a service: it runs no process to check.
HEALTHCHECK NONE

# runtime with a health check and no other change, for the comparison's integration step.
FROM runtime AS runtime-checked
HEALTHCHECK --interval=1s CMD true

# The image's test, which passes only on an image of version v1.
FROM runtime AS test
RUN grep -qx v1 /app/version

# A test stage that never uses the image, which run-tests.sh must refuse.
FROM busybox:1.37.0-musl@sha256:5cec3fc171c87218698e85a52af7087de727372aae264a787b8112901a5b0092 AS unrelated
RUN echo "tests nothing about runtime"

# A served image whose health check passes once it is listening, and only while it
# has none of the job's environment and no network: its routing table holds no route.
# Counting interfaces would not do, since a kernel with tunnel drivers built in gives
# every network namespace its own down tunnel devices.
FROM busybox:1.37.0-musl@sha256:5cec3fc171c87218698e85a52af7087de727372aae264a787b8112901a5b0092 AS served
RUN mkdir /www && echo ok >/www/index.html
USER nobody
HEALTHCHECK --interval=1s --timeout=1s --start-period=2s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/ && test -z "$FIXTURE_JOB_VAR" && test "$(grep -c . /proc/net/route)" -eq 1
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]

# A served image whose health check probes a port nothing listens on.
FROM served AS sick
HEALTHCHECK --interval=1s --timeout=1s --retries=2 CMD wget -q -O /dev/null http://127.0.0.1:8081/
