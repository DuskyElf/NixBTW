# The sandbox wrapper every jailable app goes through. jail.nix builds a
# wrapper around a binary; this adds the combinators this machine keeps using
# and the symlinkJoin that puts the wrapper and the real package in one path,
# so the store reference still resolves to the jailed entry point.
{ pkgs, jail-nix }:
let
  jailed = jail-nix.lib.extend {
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
in
{
  jail =
    name: pkg: combinators:
    pkgs.symlinkJoin {
      name = "${name}-jailed";
      paths = [
        (jailed name pkg combinators)
        pkg
      ];
    };
}
