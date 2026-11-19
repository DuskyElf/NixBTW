# Bash for a machine whose login shell is bash and that has no zsh setup. Plain
# prompt, history that survives a closed terminal, and the window size
# refreshed for programs that read it after a resize.
#
# `nx` is defined here as well as in apps/zsh.nix: the two shells are separate
# opt-ins, and a host that takes this one without zsh must still get it. Keep
# the two copies identical.
{
  programs.bash = {
    enable = true;
    initExtra = ''
      PS1='\u@\h:\w\$ '
      shopt -s histappend checkwinsize

      nx() {
        nix-shell -p "$1" --run "$1"
      }
    '';
  };
}
