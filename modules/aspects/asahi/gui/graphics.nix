# The GPU, with OpenCL.
{ ... }:
{
  den.aspects.asahi.provides.gui.nixos =
    { pkgs, ... }:
    {
      hardware.graphics = {
        enable = true;
        extraPackages = with pkgs; [
          mesa.opencl
        ];
      };

      # GTK's GL renderer: its default (Vulkan) misdraws on the Asahi GPU.
      environment.variables.GSK_RENDERER = "ngl";
    };
}
