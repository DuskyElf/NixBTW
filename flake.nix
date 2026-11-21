{
  description = "DuskyElf's dotfiles";

  inputs = {
    self.submodules = true;

    nixpkgs.url = "nixpkgs/nixos-26.05";

    # The nixpkgs inputs are deliberately mixed, and aligning them is not a
    # fix: each one follows the nixpkgs its packages are built against.

    # Pinned by rev (not branch) so GitHub Actions builds the exact same
    # kernel closure as this laptop. CI has no lock file for this flake, so a
    # floating ref would drift and every cache lookup would miss.
    # The rev carries whatever hosts/asus/stable-kernel.nix picks (the newest
    # series with a stable patch release). The daily check-kernel-update workflow
    # moves this pin to the channel tip once the channel is not behind, and
    # holds while this pin is ahead.
    # NOTE: deploy-system must NOT follows-override this input, or local
    # builds will use a different rev than CI and miss the cache.
    nixpkgs-fast-release.url = "github:NixOS/nixpkgs/9bf7e280815e87b21bdd2d9011aacc76348fb4e6";

    nixpkgs-unstable.url = "nixpkgs/nixos-unstable";

    # opencode tracks latest upstream here, and pkgs/t3code reuses this
    # channel's recipe and codex for its stable-tag build. The other packages
    # come from stable, whose cache carries electron, which this channel does
    # not build; codex is here because stable's is below what T3 trusts.
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
      # The stable kernel series this machine tracks (see
      # hosts/asus/stable-kernel.nix). CI compares this against a candidate
      # pin: nix eval --raw .#kernelVersion --override-input nixpkgs-fast-release <rev>
      kernelVersion = dotfiles.kernel.version;

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

      formatter.${dotfiles.pkgs.system} = dotfiles.pkgs.stable.nixfmt-tree;
    };
}
