# The OpenTofu bar reads this from the repository root. The only module here is the bar's own
# fixture, which uses no cloud provider, so only the bundled terraform rules apply.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
