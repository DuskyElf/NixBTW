{
  description = "DuskyElf's dotfiles";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-25.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    stylix = {
      url = "github:nix-community/stylix/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser.url = "github:0xc000022070/zen-browser-flake/beta";
  };

  outputs = { self, nixpkgs, home-manager, ... }@inputs:
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
      modules = [
        inputs.niri.homeModules.config
        inputs.niri.homeModules.stylix
        inputs.stylix.homeModules.stylix
        inputs.zen-browser.homeModules.beta
        ./home.nix
      ];
    };
  };
}
