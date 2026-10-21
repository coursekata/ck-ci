# A platform without the variant Docker leaves off by default, so linux/arm64/v8 is linux/arm64.
def norm: sub("^(?<p>[^/]+/arm64)/v8$"; "\(.p)") | sub("^(?<p>[^/]+/amd64)/v1$"; "\(.p)");
