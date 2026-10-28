# An image that declares no health check.
target "app" {
  context    = "app"
  dockerfile = "Dockerfile"
  target     = "runtime"
}

target "app-test" {
  inherits = ["app"]
  target   = "test"
}

target "app-failing-test" {
  inherits = ["app"]
  target   = "failing"
}

target "app-unrelated-test" {
  inherits = ["app"]
  target   = "unrelated"
}

# Served images, for the health run.
target "served" {
  context    = "app"
  dockerfile = "Dockerfile"
  target     = "served"
}

target "sick" {
  inherits = ["served"]
  target   = "sick"
}
