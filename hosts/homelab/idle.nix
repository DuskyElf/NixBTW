# Idle power for a machine that stays on and does nothing 20 hours a day, with
# no screen, no keyboard and no audio in use. Everything here is a device that
# is not needed, a write that can be batched, or a timer with nothing to do;
# none of it trades a capability away.
#
# What is NOT here, on purpose: PCIe ASPM forcing (the classic false AER and
# hang source on this chipset generation, for well under a watt), USB
# unbinding, THP/mitigations/init_on_* tweaks, and disk spindown. The internal
# panel and the audio codec are the two real watts; the rest is noise on a box
# with no meter to prove it. The disk is left spinning: the drive's own low
# power idle is 0.55 W against 0.18 W stopped, and systemd, timesyncd and
# journald wake it often enough that the load-cycle budget buys nothing.
{ lib, ... }:
{
  # The panel is the single biggest idle consumer, and the box will never show
  # anything on it. The connector is LVDS-1 (the IGP's internal output, as
  # /sys/class/drm reports it): `video=LVDS-1:d` keeps any CRTC off it, so radeon
  # never brings the panel up. The backlight still needs the udev rule below,
  # because a panel the driver never drives keeps the firmware's bl_power, and
  # the 2-4 W is in the backlight, not the signal. consoleblank covers the case
  # where somebody plugs in an external screen (fbcon's blank is a DPMS off).
  boot.kernelParams = [
    "video=LVDS-1:d"
    "consoleblank=60"
  ];

  # bl_power 4 is FB_BLANK_POWERDOWN. Applied on every backlight device add, so
  # it survives a driver reload and does not depend on userspace ordering.
  services.udev.extraRules = ''
    SUBSYSTEM=="backlight", ACTION=="add", ATTR{bl_power}="4"
  '';

  # The codec is powered down whenever it is idle. snd_ctl_led drives a mute
  # LED through the codec and is what keeps it out of D3, so it is blacklisted;
  # nothing on this machine has an LED it needs to set.
  boot.extraModprobeConfig = ''
    options snd_hda_intel power_save=1 power_save_controller=Y
    blacklist snd_ctl_led
  '';

  # fstrim defaults to on and there is nothing to trim on a rotational disk.
  services.fstrim.enable = false;

  # Batch writeback: a nix store write is a stream of small files, and letting
  # them sit for a minute costs nothing on ext4 with no disk swap behind it,
  # while it turns a hundred wakeups into one. The expire window matches, so
  # nothing is written back early because it is old.
  boot.kernel.sysctl = {
    "vm.dirty_writeback_centisecs" = 6000;
    "vm.dirty_expire_centisecs" = 6000;
  };

  # The machine is administered over ssh. This drops the NixOS HTML manual from
  # every generation on a disk that keeps two days of them; man pages stay,
  # because an agent greps those.
  documentation.nixos.enable = false;
}
