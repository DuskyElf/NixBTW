{
  config,
  pkgs,
  pkgs-unstable,
  jail,
  ...
}:
let
  home = config.home.homeDirectory;
  #git-pkg = (
  #  jail "git" pkgs.git (
  #    c: with c; [
  #      network
  #      (ro-bind "/home/duskyelf/.config/git/config" "/home/duskyelf/.gitconfig")

  #      (readwrite "/home/duskyelf/Projects")
  #      (readwrite "/home/duskyelf/dotfiles/")
  #      (readwrite "/home/duskyelf/.deploy-system/")

  #      (readonly "/home/duskyelf/.ssh/")
  #      (fwd-env "SSH_AUTH_SOCK")
  #      (readonly (noescape "\"$SSH_AUTH_SOCK\""))

  #      (set-env "EDITOR" "vim")

  #      (add-pkg-deps [
  #        pkgs.less
  #        pkgs.openssh
  #        pkgs.gnupg
  #        pkgs.vim
  #      ])
  #    ]
  #  )
  #);
in
{
  programs.git = {
    enable = true;
    #package = git-pkg;

    signing = {
      key = "~/.ssh/id_ed25519_signing";
      format = "ssh";
      signByDefault = true;
    };

    settings = {
      user = {
        name = "DuskyElf";
        email = "duskyelf.dev+git@gmail.com";
      };
      init.defaultBranch = "main";
    };
  };

  home.packages = [
    (jail "gh"
      (pkgs.github-cli.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
        postInstall = (old.postInstall or "") + ''
          wrapProgram "$out/bin/gh" \
            --prefix PATH : "${pkgs.git}/bin" \
            --prefix LD_LIBRARY_PATH : "${pkgs.git}/lib"
        '';
      }))
      (
        c: with c; [
          network
          mount-cwd
          (xdg-app home "gh")
          (add-pkg-deps [ pkgs.git ])
        ]
      )
    )
    (jail "worktrunk" pkgs-unstable.worktrunk (
      c: with c; [
        (readwrite "/home/duskyelf/Projects")
        (add-pkg-deps [ pkgs.git ])
        (xdg-app home "worktrunk")
      ]
    ))
  ];
}
