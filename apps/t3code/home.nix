# T3 Code on a desktop: the source-built app, its URL scheme, and the repair
# for its headless browser download. A headless host takes
# apps/t3code/server.nix instead, which serves upstream's prebuilt tarball and
# skips the desktop launcher and URL-scheme registration.
{
  config,
  pkgs,
  pkgs-unstable-small,
  ...
}:
let
  # The tag and the fixed-output hashes live in pkgs/t3code/lock.nix and move
  # with the daily update (pkgs/t3code/update.sh). Every dependency comes from
  # the stable set, whose cache carries electron. The recipe comes from
  # unstable-small: stable only has a 0.0.x recipe.
  t3code = import ../../pkgs/t3code {
    inherit pkgs;
    recipeSrc = pkgs-unstable-small.path;
  };
in
{
  home.packages = [ t3code ];

  # T3 Code calls `xdg-mime default` for its own scheme at launch, which does
  # nothing while mimeapps.list is a read-only store link (base/home.nix owns
  # it), so the scheme is declared here. It points at the packaged entry, not
  # T3's com.t3tools.T3Code.desktop: that one execs bare electron because the
  # wrapper sets no T3CODE_DESKTOP_LAUNCHER_PATH.
  xdg.mimeApps.defaultApplications."x-scheme-handler/t3code" = "t3code.desktop";

  # T3's downloads are already on disk by the time a switch runs, so this
  # repairs them without a watcher. Anchored to the package install so the
  # Chromium the shim points at exists on a first switch.
  home.activation.t3HeadlessChromeShim = config.lib.dag.entryAfter [
    "installPackages"
  ] "run ${./chrome-shim.sh}";
}
