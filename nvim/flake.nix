{
  description = "Neovim btw";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-25.05";

    mini-nvim = {
      url = "github:nvim-mini/mini.nvim";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      nvim-plugs = {
        mini = pkgs.vimUtils.buildVimPlugin {
          name = "mini.nvim";
          src = inputs.mini-nvim;
        };
      };
    in
    {
      homeModule = import ./home.nix { inherit nvim-plugs; };
    };
}
