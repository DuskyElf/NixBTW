# Builds scripts/node_modules from scripts/package-lock.json.
#
# cli/sh.nix links the result into the live scripts tree, so wallpaper.mjs keeps
# running from the working tree while its dependencies come from the store.
# package.json and the lock are the only inputs. Add a dependency with
# `npm install --package-lock-only`, then switch; node_modules itself is a
# read-only store symlink and will reject a normal install.
{ importNpmLock, nodejs }:
importNpmLock.buildNodeModules {
  npmRoot = ./.;
  inherit nodejs;
}
