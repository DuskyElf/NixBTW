# Bash for a machine whose login shell is bash and that has no zsh setup. Plain
# prompt, history that survives a closed terminal, and the window size
# refreshed for programs that read it after a resize.
{
  programs.bash = {
    enable = true;
    initExtra = ''
      PS1='\u@\h:\w\$ '
      shopt -s histappend checkwinsize
    '';
  };
}
