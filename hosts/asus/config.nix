# This machine's identity, as data. The schema is lib/host.nix; base/ and apps/
# read the result as `hostConfig`. A second laptop gets its own file here and a
# hosts/<name>/default.nix that lists it, not a copy of hosts/asus/system.nix.
#
# Hardware that needs a driver, a kernel flag, or a boot service stays in
# system.nix beside that work. Only the values other modules read live here.
{
  hostName = "asus";
  timeZone = "Asia/Kolkata";

  stateVersion = {
    system = "25.11";
    home = "25.11";
  };

  locale = {
    default = "en_US.UTF-8";
    # Regional formats (dates, numbers, paper) for India, strings still English.
    extra = "en_IN";
  };

  user = {
    name = "duskyelf";
    home = "/home/duskyelf";
    description = "DuskyElf";
    git = {
      name = "DuskyElf";
      email = "duskyelf.dev+git@gmail.com";
      signingKey = "~/.ssh/id_ed25519_signing";
    };
  };

  # Panels: the OLED is 3840x2160 at 2.5, the screenpad sits below it. The y
  # offset is where the primary's scaled height ends (2160 / 2.5 = 864); moving
  # the scale without it leaves a gap. Coordinates are physical, so y=864 on the
  # primary's scale means the screenpad starts there.
  niri = {
    outputs = {
      "eDP-1" = {
        focus-at-startup = true;
        mode = {
          width = 3840;
          height = 2160;
        };
        position = {
          x = 0;
          y = 0;
        };
        scale = 2.5;
      };

      "DP-2" = {
        # The screenpad starts dark: niri leaves it unmapped and Mod+1 runs
        # screenpad-toggle, which powers the panel and maps this output.
        enable = false;
        mode = {
          width = 3840;
          height = 1100;
        };
        position = {
          x = 0;
          y = 864;
        };
        scale = 2.5;
      };
    };

    # i915 rejects the panel's modifiers and niri then fails to modeset.
    env.WLR_DRM_NO_MODIFIERS = "1";

    # Draw on the iGPU only. The dGPU is a render node niri must not touch;
    # power.sh removes it in powersave mode, and its absence is not an error.
    render = {
      primary = "/dev/dri/by-path/pci-0000:00:02.0-render";
      ignore = "/dev/dri/by-path/pci-0000:01:00.0-render";
    };
  };

  hardware = {
    backlight = "intel_backlight";

    screenpad = {
      output = "DP-2";
      device = "asus_screenpad";
    };

    battery = {
      device = "BAT0";
      chargeLimit = 80;
    };

    # RTX 2060, 6 GB: 16k context is what fits, and llm-lab warns when the dGPU
    # is removed by a powersave mode.
    gpu = {
      cuda = true;
      contextLength = 16384;
    };
  };
}
