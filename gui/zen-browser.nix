{
  config,
  ...
}:
{
  programs.zen-browser = {
    enable = true;
    suppressXdgMigrationWarning = true;
  };
  stylix.targets.zen-browser.enable = false;
}
