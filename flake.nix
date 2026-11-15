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
    nixpkgs-fast-release.url = "github:NixOS/nixpkgs/0265ae2bec6c3ef106c5466e83160149de08a5b8";

    nixpkgs-unstable.url = "nixpkgs/nixos-unstable";

    # for opencode and the T3 Code pin
    # which I want to be on the latest version but don't want to wait for the whole nixpkgs-unstable to build
    nixpkgs-unstable-small.url = "nixpkgs/nixos-unstable-small";

    jail-nix = {
      url = "sourcehut:~alexdavid/jail.nix";
    };

    neovimBTW = {
      url = ./neovimBTW;
      inputs.nixpkgs.follows = "nixpkgs";
    };

    wallpaper-guardian = {
      url = ./wallpaper-guardian;
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
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
  # machine-wide config in base/, apps in apps/, this laptop in hosts/asus/.
  outputs =
    inputs:
    let
      dotfiles = import ./lib { inherit inputs; };
      apps = import ./apps;
      asus = dotfiles.mkHost {
        host = import ./hosts/asus;
        inherit (apps) homeModules systemModules;
      };
    in
    {
      # The stable kernel series this machine tracks (see
      # hosts/asus/stable-kernel.nix). CI compares this against a candidate
      # pin: nix eval --raw .#kernelVersion --override-input nixpkgs-fast-release <rev>
      kernelVersion = dotfiles.kernel.version;

      nixosConfigurations.asus = asus.nixos;
      homeConfigurations."duskyelf@asus" = asus.home;

      formatter.${dotfiles.pkgs.system} = dotfiles.pkgs.stable.nixfmt-tree;
    };
}
