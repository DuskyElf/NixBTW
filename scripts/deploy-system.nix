# Public recipe for the private deploy wrapper. scripts/bootstrap-deploy.sh
# substitutes @ROOT@ with the checkout path and locks it; the generated
# deploy-system/ stays gitignored, along with its lock.
{
  description = "Local deploy wrapper for @ROOT@";

  inputs = {
    my-dotfiles.url = "git+file://@ROOT@?shallow=1";

    nixpkgs.url = "nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "nixpkgs/nixos-unstable";
    nixpkgs-unstable-small.url = "nixpkgs/nixos-unstable-small";
    jail-nix.url = "sourcehut:~alexdavid/jail.nix";
    home-manager.url = "github:nix-community/home-manager/release-26.05";
    stylix.url = "github:nix-community/stylix/release-26.05";
    niri.url = "github:sodiboo/niri-flake";
    neovimBTW.url = "git+file://@ROOT@/neovimBTW";
    zen-browser.url = "github:0xc000022070/zen-browser-flake/beta";

    # Do not follow-override nixpkgs-fast-release. The kernel cache is built
    # from the rev pinned in the public flake.nix, so overriding it here would
    # make local builds miss the cache.
    my-dotfiles.inputs.nixpkgs.follows = "nixpkgs";
    my-dotfiles.inputs.nixpkgs-unstable.follows = "nixpkgs-unstable";
    my-dotfiles.inputs.nixpkgs-unstable-small.follows = "nixpkgs-unstable-small";
    my-dotfiles.inputs.jail-nix.follows = "jail-nix";
    my-dotfiles.inputs.home-manager.follows = "home-manager";
    my-dotfiles.inputs.stylix.follows = "stylix";
    my-dotfiles.inputs.niri.follows = "niri";
    my-dotfiles.inputs.neovimBTW.follows = "neovimBTW";
    my-dotfiles.inputs.zen-browser.follows = "zen-browser";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    stylix.inputs.nixpkgs.follows = "nixpkgs";
    neovimBTW.inputs.nixpkgs.follows = "nixpkgs";
    niri.inputs.nixpkgs.follows = "nixpkgs-unstable";
    zen-browser.inputs.nixpkgs.follows = "nixpkgs-unstable";
    zen-browser.inputs.home-manager.follows = "home-manager";
  };

  outputs =
    { self, my-dotfiles, ... }:
    {
      nixosConfigurations = my-dotfiles.nixosConfigurations;
      homeConfigurations = my-dotfiles.homeConfigurations;
    };
}
