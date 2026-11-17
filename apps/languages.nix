{
  lib,
  pkgs,
  ...
}:
{
  home.packages = with pkgs; [
    rustc
    cargo
    clippy
    nodejs
    python3
    sccache
  ];

  # Caches live on the agent tmpfs so parallel worktrees stop rebuilding the
  # same dependencies and stop writing them to the SSD. The mount is volatile,
  # so every cache here starts cold after a reboot.
  home.sessionVariables = {
    # sccache defaults to a 10G cap, which is most of the 24G mount.
    SCCACHE_CACHE_SIZE = "4G";
    SCCACHE_DIR = "/mnt/agent-worktrees/caches/sccache";
    # The store path, not the name: this variable is inherited into nix-shell and
    # project devShells where sccache is not on PATH, and a wrapper that cannot
    # be found fails every rustc call instead of falling back.
    RUSTC_WRAPPER = lib.getExe pkgs.sccache;
    # Cargo's incremental mode makes every rustc call non-cacheable, so sccache
    # reports the compile and does nothing. Turning it off is what makes the
    # wrapper do work, and it also keeps the incremental dirs out of the tmpfs.
    # The final link of a bin crate is never cached either way.
    CARGO_INCREMENTAL = "0";

    # npm's cache, not pnpm's store: npm is what is installed, and it ignores
    # store-dir. Add the pnpm store dir here when pnpm lands.
    NPM_CONFIG_CACHE = "/mnt/agent-worktrees/caches/npm";
    UV_CACHE_DIR = "/mnt/agent-worktrees/caches/uv";
    GOCACHE = "/mnt/agent-worktrees/caches/go-build";
  };
}
