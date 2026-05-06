{
  config,
  pkgs,
  pkgs-unstable,
  jail,
  ...
}:
let
  home = config.home.homeDirectory;
in
{
  programs.git = {
    enable = true;

    signing = {
      key = "~/.ssh/id_ed25519_signing";
      format = "ssh";
      signByDefault = true;
    };

    settings = {
      user = {
        name = "DuskyElf";
        email = "git@duskyelf.me";
      };
      init.defaultBranch = "main";
    };
  };

  programs.worktrunk = {
    enable = true;
    package = pkgs-unstable.worktrunk;
  };

  home.packages = [
    (jail "gh" (pkgs.github-cli.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.makeWrapper ];
      postInstall = (old.postInstall or "") + ''
        wrapProgram "$out/bin/gh" \
          --prefix PATH : "${pkgs.git}/bin" \
          --prefix LD_LIBRARY_PATH : "${pkgs.git}/lib"
      '';
    })) (
      c: with c; [
        network
        mount-cwd
        (readonly "/nix/store")
        (xdg-app home "gh")
      ]
    ))
  ];
}
