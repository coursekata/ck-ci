run "passes_the_name_through" {
  command = plan

  assert {
    condition     = output.name == "fixture"
    error_message = "the name did not come through"
  }
}
