# Running out of memory, the same on every host: slowing down rather than
# freezing or crashing. A host adds what earlyoom should kill first, or
# spare (services.earlyoom.extraArgs).
{ ... }:
{
  den.schema.host.includes = [
    {
      nixos = {
        # Compressed swap in RAM: no swap at all meant memory pressure had
        # nowhere to go but the page cache, and a host stopped answering
        # instead of slowing down (adam); on the laptop the kernel's OOM
        # killer took the session's own D-Bus and systemd --user with a
        # build, leaving its keys dead until a reboot. Half of RAM, zstd.
        zramSwap = {
          enable = true;
          memoryPercent = 50;
        };

        # When memory runs out anyway, kill the biggest process (a build)
        # early, before the kernel spends an hour thrashing; the kernel's own
        # OOM killer only wakes once there is nothing left to evict.
        services.earlyoom = {
          enable = true;
          freeMemThreshold = 5;
          freeSwapThreshold = 10;
        };
      };
    }
  ];
}
