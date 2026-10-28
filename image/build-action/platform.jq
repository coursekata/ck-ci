# A platform without the variant Docker leaves off by default, so linux/arm64/v8 is linux/arm64.
def norm: sub("^(?<p>[^/]+/arm64)/v8$"; "\(.p)") | sub("^(?<p>[^/]+/amd64)/v1$"; "\(.p)");

# Whether an image that ships these platforms, as check-targets.sh outputs them, ships $p. None listed
# means the builder's own, which is the runner's.
def ships($p): length == 0 or any(.[]; norm == $p);

# The digest of an OCI index's manifest for $p, or null.
def for_platform($p):
  [.manifests[] | select(.platform | [.os, .architecture, .variant // empty] | join("/") | norm == $p)][0].digest;
