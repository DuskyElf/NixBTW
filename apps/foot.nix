# foot is the terminal. It renders into a wl_shm buffer on the CPU, so a
# terminal redraw never reaches the render engine and niri only uploads the
# finished buffer. That is why it replaced kitty: kitty's eased cursor blink
# kept repainting the whole 3840x2160 surface while the cursor blinked, and it
# showed up as the largest engine-render time of any client in
# /proc/<pid>/fdinfo (the commit that swapped them has the numbers). foot has
# no tabs and no splits; tmux covers both. It speaks sixel rather than the
# kitty graphics protocol, which nothing in the tree used. Stylix supplies the
# font and the colors through programs.foot.settings, so nothing here repeats
# them.
{ ... }:
{
  programs.foot = {
    enable = true;
    settings = {
      cursor.blink = "yes"; # kitty blinked at 0.5 s, same rate
      scrollback.lines = "2000"; # kitty's default; foot's is 1000
    };
  };
}
