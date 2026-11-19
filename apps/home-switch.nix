# The link that makes `~/.config/scripts/hm-switch.sh` this checkout's copy, so
# an edit to apps/home-switch/hm-switch.sh takes effect without a rebuild. It is
# its own app because the link and the stale-link guard below only matter on a
# host that runs the daily update, and the daily unit is what calls it.
{
  config,
  hostConfig,
  ...
}:
{
  xdg.configFile."scripts/hm-switch.sh".source =
    config.lib.file.mkOutOfStoreSymlink "${hostConfig.dotsDir}/apps/home-switch/hm-switch.sh";

  # The old generation linked ~/.config/scripts to a directory outside the new
  # tree (a store copy or the live scripts/ dir). After the move that link
  # dangles, cleanup can skip it, and linkGeneration's mkdir -p then fails on
  # it. Drop any symlink at that path before linking; a real directory is left
  # alone, and readlink is empty for anything but a symlink.
  home.activation.dropStaleScriptsLink = config.lib.dag.entryBefore [ "linkGeneration" ] ''
    stale=$(readlink "$HOME/.config/scripts" 2>/dev/null || true)
    if [ -n "$stale" ]; then
      run rm -f "$HOME/.config/scripts"
    fi
  '';
}
