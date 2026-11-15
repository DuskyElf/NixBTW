# Caps as an extra control, and control held alone as an escape overload.
{ ... }:
{
  services.keyd = {
    enable = true;
    keyboards = {
      default = {
        ids = [ "*" ];

        settings = {
          global = {
            macro_sequence_timeout = 10;
          };
          main = {
            control = "capslock";
            capslock = "overload(control, escape)";
          };
        };
      };
    };
  };
}
