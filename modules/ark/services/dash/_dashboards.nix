# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# Grafana's dashboards, written here and nowhere else (./default.nix loads
# them read-only): { <file name> = <dashboard>; }, each turned into the JSON
# Grafana reads. A panel is a few fields; `panel` fills in the rest, and
# `grid` lays panels out left to right, `w` columns of 24 wide each.
{ lib }:
let
  datasource = {
    type = "prometheus";
    uid = "prometheus";
  };

  panel =
    {
      title,
      exprs,
      type ? "timeseries",
      unit ? null,
      instant ? false,
      w ? 12,
      h ? 8,
      min ? null,
      max ? null,
      thresholds ? null,
      mappings ? [ ],
      options ? { },
      # Per-column settings (a table's), and how to reshape the results.
      overrides ? [ ],
      transformations ? [ ],
    }:
    {
      inherit title type datasource;
      gridPos = { inherit w h; };
      targets = lib.imap0 (i: e: {
        refId = builtins.elemAt [ "A" "B" "C" "D" "E" ] i;
        inherit datasource instant;
        expr = e.expr;
        legendFormat = e.legend or "";
        format = if type == "table" then "table" else "time_series";
      }) exprs;
      fieldConfig = {
        defaults = {
          inherit mappings;
        }
        // lib.optionalAttrs (unit != null) { inherit unit; }
        // lib.optionalAttrs (min != null) { inherit min; }
        // lib.optionalAttrs (max != null) { inherit max; }
        // lib.optionalAttrs (thresholds != null) {
          thresholds = {
            mode = "absolute";
            steps = map (s: { inherit (s) color value; }) thresholds;
          };
        };
        inherit overrides;
      };
      inherit options transformations;
    };

  # A panel that asks the DNS log (PostgreSQL, aspects/dns.nix) in SQL.
  sqlPanel =
    {
      title,
      sql,
      type ? "table",
      w ? 12,
      h ? 10,
      unit ? null,
      options ? { },
    }:
    let
      source = {
        type = "grafana-postgresql-datasource";
        uid = "dns";
      };
    in
    {
      inherit title type options;
      datasource = source;
      gridPos = { inherit w h; };
      targets = [
        {
          refId = "A";
          datasource = source;
          editorMode = "code";
          rawQuery = true;
          rawSql = sql;
          format = if type == "table" then "table" else "time_series";
        }
      ];
      fieldConfig = {
        defaults = lib.optionalAttrs (unit != null) { inherit unit; };
        overrides = [ ];
      };
      transformations = [ ];
    };

  # Panels left to right, wrapping at 24 columns; ids in order.
  grid =
    panels:
    (lib.foldl'
      (
        acc: p:
        let
          wrap = acc.x + p.gridPos.w > 24;
          x = if wrap then 0 else acc.x;
          y = if wrap then acc.y + acc.rowH else acc.y;
          rowH = if wrap then p.gridPos.h else lib.max acc.rowH p.gridPos.h;
        in
        {
          x = x + p.gridPos.w;
          inherit y rowH;
          out = acc.out ++ [
            (
              p
              // {
                id = lib.length acc.out + 1;
                gridPos = p.gridPos // {
                  inherit x y;
                };
              }
            )
          ];
        }
      )
      {
        x = 0;
        y = 0;
        rowH = 0;
        out = [ ];
      }
      panels
    ).out;

  dashboard =
    {
      uid,
      title,
      panels,
      variables ? [ ],
      # Marks on every panel's time axis, each from a query: a series that
      # starts is an event, titled from its labels.
      annotations ? [ ],
    }:
    {
      inherit uid title;
      tags = [ "ark" ];
      editable = false;
      schemaVersion = 39;
      timezone = "browser";
      time = {
        from = "now-24h";
        to = "now";
      };
      refresh = "1m";
      templating.list = variables;
      annotations.list = map (a: {
        inherit (a) name expr;
        inherit datasource;
        enable = true;
        iconColor = a.color or "blue";
        step = "1m";
        titleFormat = a.title;
        textFormat = a.text or "";
        tagKeys = a.tags or "host";
        useValueForTime = false;
      }) annotations;
      panels = grid panels;
    };

  upDown = [
    {
      type = "value";
      options = {
        "0" = {
          text = "down";
          color = "red";
        };
        "1" = {
          text = "up";
          color = "green";
        };
      };
    }
  ];
  okFailed = [
    {
      type = "value";
      options = {
        "0" = {
          text = "ok";
          color = "green";
        };
        "1" = {
          text = "failed";
          color = "red";
        };
      };
    }
  ];
  colored = {
    colorMode = "background";
    graphMode = "none";
    textMode = "value_and_name";
  };
  # Real disks: not memory, not /boot, and not /nix/store, which NixOS mounts
  # as a read-only view of the root filesystem (so it would count it twice).
  # Settings for one column of a table, by its name.
  column = name: properties: {
    matcher = {
      id = "byName";
      options = name;
    };
    inherit properties;
  };
  disks = ''fstype!~"tmpfs|ramfs|squashfs|overlay|vfat",mountpoint!="/nix/store"'';
in
{
  # Every host at a glance: is it up, did its last deploy work, which commit
  # it runs, how old its backups are, how full its disks.
  ark = dashboard {
    uid = "ark";
    title = "ark";
    panels = [
      (panel {
        title = "Hosts";
        type = "stat";
        exprs = [
          {
            expr = ''up{job="node"}'';
            legend = "{{host}}";
          }
        ];
        mappings = upDown;
        options = colored;
        w = 8;
        h = 5;
      })
      (panel {
        title = "Last deploy";
        type = "stat";
        exprs = [
          {
            expr = ''max by (host) ({__name__=~"comin_last_(fetch|eval|build|deployment)_failed"})'';
            legend = "{{host}}";
          }
        ];
        mappings = okFailed;
        options = colored;
        w = 8;
        h = 5;
      })
      (panel {
        title = "Needs a reboot";
        type = "stat";
        exprs = [
          {
            expr = "comin_need_to_reboot";
            legend = "{{host}}";
          }
        ];
        mappings = [
          {
            type = "value";
            options = {
              "0" = {
                text = "no";
                color = "green";
              };
              "1" = {
                text = "yes";
                color = "orange";
              };
            };
          }
        ];
        options = colored;
        w = 8;
        h = 5;
      })
      (panel {
        title = "Deployed commit";
        type = "table";
        instant = true;
        exprs = [ { expr = "comin_deployment_info"; } ];
        w = 12;
        options.showHeader = true;
      })
      (panel {
        title = "Hours since the last good backup";
        type = "bargauge";
        instant = true;
        exprs = [
          {
            expr = "(time() - restic_backup_last_success_timestamp_seconds) / 3600";
            legend = "{{backup}} → {{location}}";
          }
        ];
        unit = "h";
        min = 0;
        max = 48;
        thresholds = [
          {
            color = "green";
            value = null;
          }
          {
            color = "orange";
            value = 26;
          }
          {
            color = "red";
            value = 36;
          }
        ];
        options = {
          orientation = "horizontal";
          displayMode = "basic";
        };
        w = 12;
      })
      # One row per disk: how full (a bar), how much is left, how big.
      (panel {
        title = "Disks";
        type = "table";
        instant = true;
        exprs = [
          { expr = "1 - node_filesystem_avail_bytes{${disks}} / node_filesystem_size_bytes{${disks}}"; }
          { expr = "node_filesystem_avail_bytes{${disks}}"; }
          { expr = "node_filesystem_size_bytes{${disks}}"; }
        ];
        transformations = [
          {
            id = "merge";
            options = { };
          }
          {
            id = "organize";
            options = {
              excludeByName = lib.genAttrs [
                "Time"
                "__name__"
                "always_on"
                "device"
                "fstype"
                "instance"
                "job"
              ] (_: true);
              renameByName = {
                host = "Host";
                mountpoint = "Mount";
              };
              indexByName = {
                host = 0;
                mountpoint = 1;
                "Value #A" = 2;
                "Value #B" = 3;
                "Value #C" = 4;
              };
            };
          }
        ];
        overrides = [
          (column "Value #A" [
            {
              id = "displayName";
              value = "Used";
            }
            {
              id = "unit";
              value = "percentunit";
            }
            {
              id = "min";
              value = 0;
            }
            {
              id = "max";
              value = 1;
            }
            {
              id = "custom.cellOptions";
              value = {
                type = "gauge";
                mode = "basic";
              };
            }
            {
              id = "thresholds";
              value = {
                mode = "absolute";
                steps = [
                  {
                    color = "green";
                    value = null;
                  }
                  {
                    color = "orange";
                    value = 0.75;
                  }
                  {
                    color = "red";
                    value = 0.85;
                  }
                ];
              };
            }
          ])
          (column "Value #B" [
            {
              id = "displayName";
              value = "Free";
            }
            {
              id = "unit";
              value = "bytes";
            }
          ])
          (column "Value #C" [
            {
              id = "displayName";
              value = "Size";
            }
            {
              id = "unit";
              value = "bytes";
            }
          ])
        ];
        options.sortBy = [ { displayName = "Host"; } ];
        w = 24;
        h = 9;
      })
    ];
  };

  # The DNS log: what each device looked up (aspects/dns.nix). Device names
  # are tailnet names (cale.net.<domain>, phone.heather.net.<domain>).
  dns = dashboard {
    uid = "dns";
    title = "DNS";
    variables = [
      {
        name = "device";
        label = "Device";
        type = "query";
        datasource = {
          type = "grafana-postgresql-datasource";
          uid = "dns";
        };
        query = "SELECT DISTINCT client_name FROM log_entries WHERE request_ts > now() - interval '30 days' ORDER BY 1";
        refresh = 2;
        multi = true;
        includeAll = true;
        current = {
          text = "All";
          value = "$__all";
        };
      }
      {
        name = "site";
        label = "Site contains";
        type = "textbox";
        query = "";
      }
    ];
    panels = [
      (sqlPanel {
        title = "Restricted";
        w = 24;
        sql = ''
          SELECT request_ts AS "Time", client_name AS "Device", question_name AS "Site", reason AS "Blocked as"
          FROM log_entries
          WHERE $__timeFilter(request_ts) AND reason ~ 'BLOCKED \((.*[ ,])?(gambling|porn)\M'
          ORDER BY request_ts DESC
          LIMIT 500
        '';
      })
      (sqlPanel {
        title = "Log size";
        type = "stat";
        w = 6;
        h = 5;
        unit = "bytes";
        sql = ''
          SELECT pg_total_relation_size('log_entries') AS "On disk"
        '';
      })
      (sqlPanel {
        title = "Entries";
        type = "stat";
        w = 6;
        h = 5;
        sql = ''
          SELECT count(*) AS "Lookups kept" FROM log_entries
        '';
      })
      (sqlPanel {
        title = "Oldest kept";
        type = "stat";
        w = 12;
        h = 5;
        unit = "dateTimeFromNow";
        sql = ''
          SELECT extract(epoch FROM min(request_ts)) * 1000 AS "Oldest" FROM log_entries
        '';
      })
      (sqlPanel {
        title = "Lookups per device";
        type = "timeseries";
        sql = ''
          SELECT $__timeGroupAlias(request_ts, '15m'), client_name AS metric, count(*) AS value
          FROM log_entries
          WHERE $__timeFilter(request_ts)
          GROUP BY 1, 2
          ORDER BY 1
        '';
      })
      (sqlPanel {
        title = "Most blocked";
        sql = ''
          SELECT question_name AS "Site", reason AS "Blocked as", count(*) AS "Lookups"
          FROM log_entries
          WHERE $__timeFilter(request_ts) AND response_type = 'BLOCKED'
          GROUP BY 1, 2
          ORDER BY 3 DESC
          LIMIT 25
        '';
      })
      (sqlPanel {
        title = "All lookups";
        w = 24;
        h = 16;
        sql = ''
          SELECT request_ts AS "Time", client_name AS "Device", question_name AS "Site",
                 question_type AS "Type", response_type AS "Answer", reason AS "Why"
          FROM log_entries
          WHERE $__timeFilter(request_ts)
            AND client_name IN (''${device:sqlstring})
            AND question_name ILIKE '%' || ''${site:sqlstring} || '%'
          ORDER BY request_ts DESC
          LIMIT 1000
        '';
      })
    ];
  };

  # One host in detail, chosen at the top.
  host = dashboard {
    uid = "host";
    title = "Host";
    variables = [
      {
        name = "host";
        label = "Host";
        type = "query";
        inherit datasource;
        query = {
          query = ''label_values(up{job="node"}, host)'';
          refId = "hosts";
        };
        refresh = 1;
        sort = 1;
      }
    ];
    panels = [
      (panel {
        title = "CPU";
        exprs = [
          {
            expr = ''1 - avg(rate(node_cpu_seconds_total{host="$host",mode="idle"}[5m]))'';
            legend = "busy";
          }
        ];
        unit = "percentunit";
        min = 0;
        max = 1;
      })
      (panel {
        title = "Memory";
        exprs = [
          {
            expr = ''1 - node_memory_MemAvailable_bytes{host="$host"} / node_memory_MemTotal_bytes{host="$host"}'';
            legend = "used";
          }
        ];
        unit = "percentunit";
        min = 0;
        max = 1;
      })
      (panel {
        title = "Load";
        exprs = [
          {
            expr = ''node_load1{host="$host"}'';
            legend = "1 min";
          }
          {
            expr = ''node_load15{host="$host"}'';
            legend = "15 min";
          }
        ];
      })
      (panel {
        title = "Disks";
        exprs = [
          {
            expr = ''1 - node_filesystem_avail_bytes{host="$host",${disks}} / node_filesystem_size_bytes{host="$host",${disks}}'';
            legend = "{{mountpoint}}";
          }
        ];
        unit = "percentunit";
        min = 0;
        max = 1;
      })
      (panel {
        title = "Network";
        exprs = [
          {
            expr = ''sum(rate(node_network_receive_bytes_total{host="$host",device!~"lo|veth.*|ve-.*|tailscale.*"}[5m]))'';
            legend = "in";
          }
          {
            expr = ''sum(rate(node_network_transmit_bytes_total{host="$host",device!~"lo|veth.*|ve-.*|tailscale.*"}[5m]))'';
            legend = "out";
          }
        ];
        unit = "Bps";
      })
      (panel {
        title = "Failed units";
        type = "table";
        instant = true;
        exprs = [ { expr = ''node_systemd_unit_state{host="$host",state="failed"} == 1''; } ];
      })
    ];
  };

  # Deploys over time: each host's (comin, aspects/deploy.nix) and each
  # Apple device catching up with its declarations after. `ark push` shows a
  # rollout live; this is the history.
  deploys = dashboard {
    uid = "deploys";
    title = "Deploys";
    annotations = [
      {
        name = "Deployments";
        # A commit's deployment info is a new series on the host.
        expr = "comin_deployment_info unless comin_deployment_info offset 2m";
        title = "{{host}}: {{commit_id}}";
        text = "{{status}}";
        color = "green";
      }
      {
        name = "Failures";
        expr = ''max by (host) ({__name__=~"comin_last_(eval|build|deployment)_failed"}) == 1 unless max by (host) ({__name__=~"comin_last_(eval|build|deployment)_failed"} offset 2m) == 1'';
        title = "{{host}}: deploy failed";
        color = "red";
      }
    ];
    panels = [
      (panel {
        title = "Deploys by host";
        type = "state-timeline";
        exprs = [
          {
            expr = ''max by (host) ({__name__=~"comin_last_(eval|build|deployment)_failed"})'';
            legend = "{{host}}";
          }
        ];
        mappings = okFailed;
        w = 24;
        h = 7;
        options = {
          showValue = "never";
          mergeValues = true;
        };
      })
      (panel {
        title = "Devices catching up";
        type = "state-timeline";
        exprs = [
          {
            expr = "apple_device_declarations_pending";
            legend = "{{device}}";
          }
        ];
        mappings = [
          {
            type = "value";
            options."0" = {
              text = "current";
              color = "green";
            };
          }
          {
            type = "range";
            options = {
              from = 1;
              to = 1000;
              result = {
                text = "fetching";
                color = "yellow";
              };
            };
          }
        ];
        w = 24;
        h = 5;
        options = {
          showValue = "never";
          mergeValues = true;
        };
      })
      (panel {
        title = "Deployed commit";
        type = "table";
        instant = true;
        exprs = [ { expr = "comin_deployment_info"; } ];
        w = 12;
        options.showHeader = true;
      })
      (panel {
        title = "Declarations a device rejects";
        type = "table";
        instant = true;
        exprs = [ { expr = "apple_device_declaration_valid == 0"; } ];
        w = 12;
        options.showHeader = true;
      })
    ];
  };

  # The Apple devices (services/devices/apple): what each is and how it's
  # doing, and the three Apple tokens that keep them managed.
  devices =
    let
      daysLeft = [
        {
          color = "red";
          value = null;
        }
        {
          color = "orange";
          value = 14;
        }
        {
          color = "green";
          value = 30;
        }
      ];
      expiry =
        title: expr:
        (panel {
          inherit title;
          type = "stat";
          instant = true;
          exprs = [
            {
              expr = "(${expr} - time()) / 86400";
              legend = title;
            }
          ];
          unit = "d";
          thresholds = daysLeft;
          options = colored // {
            textMode = "value";
          };
          w = 8;
          h = 4;
        });
    in
    dashboard {
      uid = "devices";
      title = "Devices";
      panels = [
        (expiry "Push certificate" "apple_mdm_push_certificate_expiry_timestamp_seconds")
        (expiry "ABM token" "apple_abm_token_expiry_timestamp_seconds")
        (expiry "Apps and Books token" "apple_vpp_token_expiry_timestamp_seconds")
        (panel {
          title = "Devices";
          type = "table";
          instant = true;
          exprs = [ { expr = "apple_device_info"; } ];
          transformations = [
            {
              id = "organize";
              options.excludeByName = {
                Time = true;
                Value = true;
                __name__ = true;
                instance = true;
                job = true;
                host = true;
                always_on = true;
              };
            }
          ];
          w = 12;
          h = 6;
          options.showHeader = true;
        })
        (panel {
          title = "Battery";
          type = "bargauge";
          instant = true;
          exprs = [
            {
              expr = "apple_device_battery_level_ratio";
              legend = "{{device}}";
            }
          ];
          unit = "percentunit";
          min = 0;
          max = 1;
          thresholds = [
            {
              color = "red";
              value = null;
            }
            {
              color = "orange";
              value = 0.2;
            }
            {
              color = "green";
              value = 0.4;
            }
          ];
          w = 6;
          h = 6;
        })
        (panel {
          title = "Storage used";
          type = "bargauge";
          instant = true;
          exprs = [
            {
              expr = "1 - apple_device_storage_available_bytes / apple_device_storage_total_bytes";
              legend = "{{device}}";
            }
          ];
          unit = "percentunit";
          min = 0;
          max = 1;
          thresholds = [
            {
              color = "green";
              value = null;
            }
            {
              color = "orange";
              value = 0.8;
            }
            {
              color = "red";
              value = 0.9;
            }
          ];
          w = 6;
          h = 6;
        })
        (panel {
          title = "Battery over time";
          exprs = [
            {
              expr = "apple_device_battery_level_ratio";
              legend = "{{device}}";
            }
          ];
          unit = "percentunit";
          min = 0;
          max = 1;
          w = 12;
        })
        (panel {
          title = "Since it last answered";
          type = "stat";
          instant = true;
          exprs = [
            {
              expr = "time() - apple_device_information_timestamp_seconds";
              legend = "{{device}}";
            }
          ];
          unit = "s";
          thresholds = [
            {
              color = "green";
              value = null;
            }
            {
              color = "orange";
              value = 7200;
            }
            {
              color = "red";
              value = 86400;
            }
          ];
          options = colored;
          w = 6;
        })
        (panel {
          title = "Declarations to fetch";
          type = "stat";
          instant = true;
          exprs = [
            {
              expr = "apple_device_declarations_pending";
              legend = "{{device}}";
            }
          ];
          thresholds = [
            {
              color = "green";
              value = null;
            }
            {
              color = "yellow";
              value = 1;
            }
          ];
          options = colored;
          w = 6;
        })
        (panel {
          title = "Declarations a device rejects";
          type = "table";
          instant = true;
          exprs = [ { expr = "apple_device_declaration_valid == 0"; } ];
          w = 12;
          h = 6;
          options.showHeader = true;
        })
        (panel {
          title = "Metrics";
          type = "stat";
          instant = true;
          exprs = [
            {
              expr = "apple_devices_metrics_errors";
              legend = "sources failing";
            }
            {
              expr = "time() - apple_devices_metrics_timestamp_seconds";
              legend = "since written (s)";
            }
          ];
          w = 12;
          h = 6;
        })
      ];
    };
}
