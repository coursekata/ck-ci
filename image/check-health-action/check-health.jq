# What check-health.sh does with an image, from `docker image inspect`'s JSON for it and the
# runner's platform: {warning} and no run, or {} and a run. An image built for another platform, or
# that declares no health check, is not run: Docker would run the wrong platform's image, and
# compose calls a service with no health check healthy the moment it starts.
def check($image; $platform):
  .[0] as $i
  | "\($i.Os)/\($i.Architecture)" as $built
  | if $built != $platform then
      {warning: "\($image) is built for \($built), not this runner's \($platform), so no health check ran for it."}
    elif ($i.Config.Healthcheck.Test // [] | . == [] or . == ["NONE"]) then
      {warning: "\($image) declares no HEALTHCHECK, so no health check ran for it."}
    else {} end;
