target "app" {
  context    = "app"
  dockerfile = "Dockerfile"
  target     = "runtime"
}

target "app-test" {
  inherits = ["app"]
  target   = "test"
}

# A test target whose stage does not build on the image, which the pipeline must refuse.
target "app-unrelated-test" {
  inherits = ["app"]
  target   = "unrelated"
}

# Reads the build secret the way a bake file in an adopting repository would.
target "secret-check" {
  context    = "app"
  dockerfile = "Dockerfile"
  target     = "secret-check"
  secret     = ["id=token,env=FIXTURE_TOKEN"]
  no-cache   = true
  output     = ["type=cacheonly"]
}

# Served images, for the health run.
target "served" {
  context    = "app"
  dockerfile = "Dockerfile"
  target     = "served"
}

target "served-test" {
  inherits = ["served"]
  target   = "served-test"
}

target "sick" {
  inherits = ["served"]
  target   = "sick"
}

target "sick-test" {
  inherits = ["served"]
  target   = "sick-test"
}
