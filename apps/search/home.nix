# The keys file, seeded once and never overwritten, so an edit survives a
# switch. system.nix owns the service and creates the file empty before it
# starts, because the service cannot see the home; this is only its content.
#
# The file is the whole configuration: search.py picks at random from the
# providers whose key is non-empty, and falls through to the next when one
# refuses. `GET /health` on port 10001 says which ones it can see.
{
  config,
  ...
}:
let
  dir = "${config.home.homeDirectory}/.config/search";
in
{
  home.activation.searchKeys = config.lib.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p ${dir}
    if [ ! -s ${dir}/keys.env ]; then
      run install -m 0600 ${./keys.example} ${dir}/keys.env
    fi
  '';
}
