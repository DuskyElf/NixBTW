{
  pkgs,
  ...
}:
{
  home.packages = with pkgs; [
    gnucash
  ];
}
