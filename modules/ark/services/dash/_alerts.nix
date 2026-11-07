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
          expr = ''1 - node_filesystem_avail_bytes{fstype!~"tmpfs|ramfs|squashfs|overlay|vfat"} / node_filesystem_size_bytes > 0.85'';
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
  ];
}
