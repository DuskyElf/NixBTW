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

    jail-nix.url = "sourcehut:~alexdavid/jail.nix";

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
      # FIXME: This is a temporary workaround until the PR is merged and released
      # https://github.com/niri-wm/niri/pull/3651
      inputs.niri-unstable.url = "github:duskyelf/niri";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    neovimBTW.url = ./neovimBTW;

    voxtype = {
      url = "github:peteonrails/voxtype";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    worktrunk = {
      url = "github:max-sixty/worktrunk";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    opencode = {
      url = "github:anomalyco/opencode";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
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
      };
      baseJail = inputs.jail-nix.lib.extend {
        inherit pkgs;
        additionalCombinators = c: with c; {
          xdg-app = home: appName: compose [
            (set-env "XDG_CONFIG_HOME" "${home}/.config")
            (set-env "XDG_DATA_HOME" "${home}/.local/share")
            (set-env "XDG_CACHE_HOME" "${home}/.cache")
            (try-rw-bind "${home}/.config/${appName}" "${home}/.config/${appName}")
            (try-rw-bind "${home}/.local/share/${appName}" "${home}/.local/share/${appName}")
            (try-rw-bind "${home}/.cache/${appName}" "${home}/.cache/${appName}")
            (try-rw-bind "${home}/.${appName}" "${home}/.${appName}")
          ];
        };
      };
      jail = name: pkg: combinators: pkgs.symlinkJoin {
        name = "${name}-jailed";
        paths = [ (baseJail name pkg combinators) pkg ];
      };
    in
    {
      nixosConfigurations.asus = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit inputs pkgs-unstable jail;
        };
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
          inputs.worktrunk.homeModules.default
        ];
        extraSpecialArgs = {
          inherit inputs pkgs-unstable jail;
        };
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
