# The two files the caller owns, seeded once and never overwritten, so an edit
# survives a switch. system.nix owns the container, the fetch API, and creating
# an empty llm.env before the container starts (its unit's ExecStartPre); this
# is only their content.
#
#   models   which OpenCode Go models a `query` may use, one per line
#   llm.env  the OPENAI_API_KEY those models need
#
# Both are read at request time. The models file takes effect immediately; a new
# key needs `sudo systemctl restart podman-crawl4ai`, because the container reads
# its environment once.
{
  config,
  ...
}:
let
  dir = "${config.home.homeDirectory}/.config/crawl4ai";
in
{
  home.activation.crawl4aiConfig = config.lib.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p ${dir}
    if [ ! -e ${dir}/models ]; then
      run install -m 0644 ${./models.example} ${dir}/models
    fi
    if [ ! -s ${dir}/llm.env ]; then
      run install -m 0600 ${./llm.env.example} ${dir}/llm.env
    fi
  '';
}
