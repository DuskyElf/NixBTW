# The prebuilt Linux server tarball this repo's headless host installs, by
# release tag and fixed-output hash. Kept apart from ./lock.nix on purpose: the
# laptop's source pin moves every day and rebuilds there, while the homelab
# only takes a new server when this file moves, so a laptop tag bump cannot
# change what that host fetches. Bump it with ./update-server.sh.
{
  tag = "v0.1.11";
  hash = "sha256-K2kcB/W8ta3qSoY9UySq59shvW2CKAzsd4eDbcqgE+E=";
}
