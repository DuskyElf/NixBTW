{
  description = "DuskyElf's dotfiles";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
    nixosConfigurations.asus = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        ./configuration.nix
        { config._module.args = { hostName = "asus"; }; }
      ];
    };

    homeConfigurations.duskyelf = home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [ ./home.nix ];
    };
  };
}
