{
  description = "DuskyElf's dotfiles";

  inputs = {
    self.submodules = true;

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

    neovimBTW.url = ./neovimBTW;

    zen-browser.url = "github:0xc000022070/zen-browser-flake/beta";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          inputs.neovimBTW.overlays.default
        ];
      };
    in
    {
      nixosConfigurations.asus = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./system.nix
          ./hosts/asus/system.nix

          ./cli/system.nix
          ./gui/system.nix
          ./gui/waydroid.nix
        ];
      };

      homeConfigurations."duskyelf@asus" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./home.nix

          ./cli/home.nix
          ./gui/home.nix

          inputs.niri.homeModules.config
          inputs.niri.homeModules.stylix
          inputs.stylix.homeModules.stylix
          inputs.zen-browser.homeModules.beta
        ];
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
