{
  description = "DuskyElf's dotfiles";

  nixConfig = {
    extra-substituters = [
      "https://cache.nixos-cuda.org/"
      "https://duskyelf.github.io/NixBTW"
    ];
    extra-trusted-public-keys = [
      "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      # Binary cache for the custom kernel, built on GitHub Actions and
      # deployed to gh-pages. Key name must exactly match the signer
      # (NIX_SECRET_KEY); a rename here silently rejects the cache.
      "i9-kernel-cache:4R0pqOZkrRj4utTbF4zP05Y58QSgShLqQ77KUPzFjwk="
    ];
  };

  inputs = {
    self.submodules = true;

    nixpkgs.url = "nixpkgs/nixos-26.05";

    # Pinned by rev (not branch) so GitHub Actions builds the exact same
    # kernel closure as this laptop. CI has no lock file for this flake, so a
    # floating ref would drift and every cache lookup would miss.
    # To bump the kernel toolchain: update the rev, push, let the
    # compile-kernel workflow rebuild and repopulate the cache.
    # NOTE: deploy-system must NOT follows-override this input, or local
    # builds will use a different rev than CI and miss the cache.
    nixpkgs-fast-release.url = "github:NixOS/nixpkgs/2f11bb7ff83b556e035a5da06596c106ddba1311";

    nixpkgs-unstable.url = "nixpkgs/nixos-unstable";

    # for opencoode and pi-coding-agent
    # which I want to be on the latest version but don't want to wait for the whole nixpkgs-unstable to build
    nixpkgs-unstable-small.url = "nixpkgs/nixos-unstable-small";

    jail-nix = {
      url = "sourcehut:~alexdavid/jail.nix";
    };

    neovimBTW = {
      url = ./neovimBTW;
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
        config.allowUnfree = true;
        overlays = [
          # Workaround: Module-CPANTS-Analyse test fails with Archive::Any::Lite 0.11
          # because SECURE EXTRACT MODE rejects the absolute-symlink test tarball.
          # This cascades: Test-Kwalitee → Finance-Quote → gnucash breaks.
          #
          # Using `perl5.override { overrides = ... }` with the base `prev.perl5.pkgs`
          # creates a top-level `//` merge that does NOT propagate to internal fixpoint
          # references inside makeScopeWithSplicing'. Test-Kwalitee would still use the
          # original ModuleCPANTSAnalyse (with tests enabled).
          #
          # Instead, use overrideScope on the perl package set itself. This rebuilds
          # the entire scope fixpoint, so ALL packages that depend on ModuleCPANTSAnalyse
          # (Test-Kwalitee, Finance-Quote, etc.) will use the overridden version internally.
          (final: prev: {
            perl5 = prev.perl5.override {
              overrides =
                _:
                prev.perl5.pkgs.overrideScope (
                  finalself: prevself: {
                    ModuleCPANTSAnalyse = prevself.ModuleCPANTSAnalyse.overrideAttrs (old: {
                      doCheck = false;
                    });
                  }
                );
            };
          })
        ];
      };
      pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
      pkgs-unstable-small = inputs.nixpkgs-unstable-small.legacyPackages.${system};
      pkgs-fast-release = import inputs.nixpkgs-fast-release {
        system = system;
        config.allowUnfree = true;
      };
      baseJail = inputs.jail-nix.lib.extend {
        inherit pkgs;
        additionalCombinators =
          c: with c; {
            xdg-app =
              home: appName:
              compose [
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
      jail =
        name: pkg: combinators:
        pkgs.symlinkJoin {
          name = "${name}-jailed";
          paths = [
            (baseJail name pkg combinators)
            pkg
          ];
        };
    in
    {
      nixosConfigurations.asus = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit
            inputs
            jail
            pkgs-unstable
            pkgs-fast-release
            ;
        };
        modules = [
          ./system.nix
          ./hosts/asus/system.nix

          ./cli/system.nix
          ./gui/system.nix
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
        extraSpecialArgs = {
          inherit
            inputs
            pkgs-unstable
            pkgs-unstable-small
            jail
            ;
        };
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
