{
  description = "DuskyElf's dotfiles";

  nixConfig = {
    extra-substituters = [
      "https://cuda-maintainers.cachix.org/"
    ];
    extra-trusted-public-keys = [
      "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
    ];
  };

  inputs = {
    self.submodules = true;

    nixpkgs.url = "nixpkgs/nixos-25.11";

    nixpkgs-unstable.url = "nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    stylix = {
      url = "github:nix-community/stylix/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    neovimBTW.url = ./neovimBTW;

    voxtype = {
      url = "github:peteonrails/voxtype";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    opencode = {
      url = "github:duskyelf/nixpkgs/update-opencode";
    };

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
      lib = nixpkgs.lib;
      system = "x86_64-linux";
      pkgs-unstable = import inputs.nixpkgs-unstable {
        inherit system;
        config = {
          allowUnfreePredicate =
            pkg:
            builtins.elem (lib.getName pkg) [
              "antigravity"
            ];
        };
      };
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
          inputs.voxtype.homeManagerModules.default
          inputs.zen-browser.homeModules.beta
        ];
        extraSpecialArgs = {
          inherit inputs;
          inherit pkgs-unstable;
        };
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
