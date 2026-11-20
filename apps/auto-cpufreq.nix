# CPU governor on battery and on the charger. Turbo stays off on battery and is
# left to the driver on the charger. A host imports this module only if it wants
# the policy, so there is no battery check here.
{
  services.auto-cpufreq = {
    enable = true;
    settings = {
      battery = {
        governor = "powersave";
        turbo = "never";
      };
      charger = {
        governor = "powersave";
        turbo = "auto";
      };
    };
  };
}
