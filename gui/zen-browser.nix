{
  config,
  ...
}:
{
  programs.zen-browser = {
    enable = true;
  };
  stylix.targets.zen-browser.enable = false;
}
