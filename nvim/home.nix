{ nvim-plugs }:
{
  pkgs,
  config,
  ...
}:
{
  programs.neovim = {
    enable = true;
    defaultEditor = true;

    extraLuaConfig = ''
      require("hot")
    '';

    plugins = with nvim-plugs; [
      mini
    ];
  };

  xdg.configFile."nvim/lua/hot" = {
    recursive = true;
    source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/nvim/hot";
  };

  stylix.targets.neovim.enable = false;
}
