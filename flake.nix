# The source tree for the laptop and the homelab, not the deploy unit.
# `deploy-system/` is a private wrapper flake that pins every input and holds
# the lock the machines switch with; it stays private so the exact nixpkgs,
# stylix, niri and zen-browser revisions are not published. A fresh clone can
# evaluate once its submodules are checked out and Nix resolves the floating
# inputs, but the machine's exact closure comes from that wrapper. The recipe
# and bootstrap are in lib/deploy/.
{
  description = "DuskyElf's dotfiles";

  inputs = {
    self.submodules = true;

    nixpkgs.url = "nixpkgs/nixos-26.05";

    # The nixpkgs inputs are deliberately mixed, and aligning them is not a
    # fix: each one follows the nixpkgs its packages are built against.

    # Pinned by rev (not branch) so GitHub Actions builds the exact same
    # kernel closures as both machines. CI has no lock file for this flake, so a
    # floating ref would drift and every signed-cache lookup would miss. One pin
    # covers both kernels: the laptop's series (hosts/asus/stable-kernel.nix)
    # and the homelab's LTS (hosts/homelab/kernel.nix) both come out of this
    # rev. The CI check compares it with release-26.05 and moves the pin to the
    # channel tip only when that moves no host's kernel backwards.
    # NOTE: deploy-system must NOT follows-override this input, or local
    # builds will use a different rev than CI and miss the cache.
    nixpkgs-fast-release.url = "github:NixOS/nixpkgs/0fd1e8f4d772064af902762c4a828853e40cafa3";

    nixpkgs-unstable.url = "nixpkgs/nixos-unstable";

    # opencode tracks latest upstream here, and pkgs/t3code reuses this
    # channel's recipe for its stable-tag build. The other packages come from
    # stable, whose cache carries electron, which this channel does not build.
    nixpkgs-unstable-small.url = "nixpkgs/nixos-unstable-small";

    jail-nix = {
      url = "sourcehut:~alexdavid/jail.nix";
    };

    neovimBTW = {
      url = ./apps/nvim/neovimBTW;
      inputs.nixpkgs.follows = "nixpkgs";
    };

    wallpaper-guardian = {
      url = ./apps/wallpaper/wallpaper-guardian;
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Only a host that carries a hosts/<name>/disko.nix uses this: it is the
    # module and CLI nixos-anywhere formats that host's disk with.
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    stylix = {
      url = "github:nix-community/stylix/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake/beta";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
      inputs.home-manager.follows = "home-manager";
    };
  };

  # Declarations and wiring. Everything that computes lives in lib/, the
  # machine-wide config in base/, apps in apps/, the machines in hosts/.
  outputs =
    inputs:
    let
      lib = inputs.nixpkgs.lib;
      dotfiles = import ./lib { inherit inputs; };

      # Every directory under hosts/ is one machine, so a new host is a
      # hosts/<name>/ directory and nothing else. readDir skips the files there
      # (READMEs, patches) and attrNames sorts, so the output set is stable.
      # `hosts/<name>/default.nix` is what mkHost imports.
      hostNames = builtins.attrNames (
        lib.filterAttrs (name: type: type == "directory" && !(lib.hasPrefix "." name)) (
          builtins.readDir ./hosts
        )
      );

      hosts = map (
        name:
        dotfiles.mkHost {
          host = import (./hosts + "/${name}");
        }
      ) hostNames;
    in
    {
      # The kernel each host runs, keyed by host name. One question to a
      # candidate pin returns every machine's answer, so CI never re-derives a
      # selection that lives in the host files:
      #   nix eval --json .#kernelVersions --override-input nixpkgs-fast-release <rev>
      # The laptop's value is hosts/asus/stable-kernel.nix; the homelab names
      # its LTS series in hosts/homelab/kernel.nix. Both read the same pin, so
      # one rev moves both kernels, and either can move alone.
      kernelVersions = builtins.listToAttrs (
        map (host: {
          name = host.hostConfig.hostName;
          value = host.nixos.config.boot.kernelPackages.kernel.version;
        }) hosts
      );

      # Both names come from hosts/<name>/config.nix, so the outputs follow a
      # host rename or a new user without an edit here.
      nixosConfigurations = builtins.listToAttrs (
        map (host: {
          name = host.hostConfig.hostName;
          value = host.nixos;
        }) hosts
      );
      homeConfigurations = builtins.listToAttrs (
        map (host: {
          name = "${host.hostConfig.user.name}@${host.hostConfig.hostName}";
          value = host.home;
        }) hosts
      );

      # `nix fmt` runs nixfmt-tree over the repo.
      formatter.${dotfiles.pkgs.system} = dotfiles.pkgs.stable.nixfmt-tree;
    };
}
