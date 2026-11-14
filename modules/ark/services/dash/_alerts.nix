# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# What monitoring mails about (./default.nix): Prometheus alerting rules, as
# the attrset its rule file is. Each names the host it is about.
{
  groups = [
    {
      name = "ark";
      rules = [
        {
          alert = "HostDown";
          expr = ''up{job="node",always_on="true"} == 0'';
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.host }} is not answering";
        }
        {
          alert = "DnsResolverDown";
          expr = ''up{job="blocky"} == 0'';
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "The DNS resolver on {{ $labels.host }} is not answering: devices still have the other";
        }
        {
          alert = "DeployFailing";
          expr = ''max by (host) ({__name__=~"comin_last_(fetch|eval|build|deployment)_failed"}) == 1'';
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "comin on {{ $labels.host }}: its last fetch, evaluation, build or deployment failed";
        }
        {
          alert = "NeedsReboot";
          expr = "comin_need_to_reboot == 1";
          for = "6h";
          labels.severity = "info";
          annotations.summary = "{{ $labels.host }} runs an older kernel or system than it would boot: reboot it";
        }
        {
          alert = "DiskFilling";
          # Not /nix/store: NixOS mounts it as a view of the root filesystem.
          # Only hosts that are always on: a laptop's disk is its own business.
          expr = ''1 - node_filesystem_avail_bytes{always_on="true",fstype!~"tmpfs|ramfs|squashfs|overlay|vfat",mountpoint!="/nix/store"} / node_filesystem_size_bytes > 0.85'';
          for = "30m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.host }}: {{ $labels.mountpoint }} is {{ $value | humanizePercentage }} full";
        }
        {
          alert = "UnitFailed";
          expr = ''node_systemd_unit_state{state="failed"} == 1'';
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.host }}: {{ $labels.name }} failed";
        }
        {
          alert = "BackupStale";
          expr = "time() - restic_backup_last_success_timestamp_seconds > 36 * 3600";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.host }}: no good {{ $labels.backup }} backup to {{ $labels.location }} for {{ $value | humanizeDuration }}";
        }
      ];
    }
    {
      # Apple devices and their MDM (services/devices/apple, ./metrics there).
      name = "apple-devices";
      rules = [
        {
          # The three things Apple makes us renew every year: miss one and
          # every device stops being managed (push certificate), enrolling
          # (ABM token) or getting apps (content token).
          alert = "AppleRenewalDue";
          # A comparison, not a subtraction: that would drop the metric's name.
          expr = ''{__name__=~"apple_(mdm_push_certificate|abm_token|vpp_token)_expiry_timestamp_seconds"} < time() + 30 * 86400'';
          labels.severity = "critical";
          annotations.summary = "{{ $labels.__name__ }}: Apple's {{ if $labels.name }}{{ $labels.name }} {{ end }}expires {{ $value | humanizeTimestamp }}: renew it (see services/devices/apple)";
        }
        {
          # Asked every hour; a day with no answer is a device off, broken,
          # or no longer enrolled.
          alert = "AppleDeviceSilent";
          expr = "time() - apple_device_information_timestamp_seconds > 86400";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} hasn't answered MDM for {{ $value | humanizeDuration }}";
        }
        {
          alert = "AppleDeclarationInvalid";
          expr = "apple_device_declaration_valid == 0";
          for = "30m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} finds {{ $labels.declaration }} invalid: `status-errors` on nanohub says why";
        }
        {
          alert = "AppleDeviceMetricsFailing";
          expr = "apple_devices_metrics_errors > 0 or time() - apple_devices_metrics_timestamp_seconds > 1800";
          for = "30m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.host }}: apple-devices-metrics can't read everything (its journal says what)";
        }
      ];
    }
  ];
}
