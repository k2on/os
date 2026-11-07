# Backups for ark services, with restic.
#
# A service says what to keep by declaring `backup` on its ark.services
# spec (lib/services.nix), as an attrset or as a function of the same args
# as its nixos module ({ service, config, pkgs, ... }):
#
#   ark.services.git = {
#     backup = {
#       name = "git";                    # repository and job name, defaults to the service's
#       paths = [ "/var/lib/gitea/repositories" ];
#       exclude = [ ... ];               # restic exclude patterns
#       postgres = [ "git" ];            # databases dumped to /var/backup/<name>/<db>.sql, kept too
#       stop = [ "gitea.service" ];      # stopped for the copy, so files and dumps are one moment
#       schedule = "03:30";              # OnCalendar, defaults to daily
#     };
#     nixos = ...;
#   };
#
# The host says, once, where backups go:
#
#   ark.backup.locations = {
#     local.repository = "/mnt/hdd/restic";
#     remote.repository = "rest:http://backup:8000";
#   };
#
# and gets a restic job per service per location,
# restic-backups-<name>-<location>, into <repository>/<name>. A service's
# jobs run together and share one preparation, ark-backup-<name>.service:
# it stops the units that were running and dumps the databases, and once
# the last job is done (StopWhenUnneeded) starts those units again, also
# when the dump or a job failed.
#
# `ark-restore <name> [location]` puts the latest snapshot back from a
# location (the first by name when not given): it stops the units,
# restores the files, loads the dumps and starts the units.
{ lib, config, ... }:
{
  den.aspects.ark-backups.nixos =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.ark.backup;
      backups = lib.attrValues cfg.services;

      dumpDir = b: "/var/backup/${b.name}";
      prepareUnit = b: "ark-backup-${b.name}";
      needsPrepare = b: b.stop != [ ] || b.postgres != [ ];
      # Which of a service's units were running, to start only those again.
      stoppedFile = b: "/run/ark-backup-${b.name}.stopped";

      jobs = lib.concatMap (
        b:
        lib.mapAttrsToList (loc: l: {
          inherit b l loc;
          name = "${b.name}-${loc}";
        }) cfg.locations
      ) backups;

      pgDump = "${config.services.postgresql.package}/bin/pg_dump";
      psql = "${config.services.postgresql.package}/bin/psql";

      restore = pkgs.writeShellApplication {
        name = "ark-restore";
        runtimeInputs = [
          pkgs.restic
          pkgs.util-linux
          config.systemd.package
        ];
        text = ''
          [ "$(id -u)" = 0 ] || exec /run/wrappers/bin/sudo "$0" "$@"

          usage() {
            echo "usage: ark-restore <${
              lib.concatMapStringsSep "|" (b: b.name) backups
            }> [${lib.concatStringsSep "|" (lib.attrNames cfg.locations)}]" >&2
            exit 1
          }
          [ $# -ge 1 ] || usage
          name=$1
          loc=''${2:-${lib.head (lib.attrNames cfg.locations ++ [ "" ])}}

          case "$loc" in
          ${lib.concatStrings (
            lib.mapAttrsToList (loc: l: ''
              ${loc})
                base=${lib.escapeShellArg l.repository}
                passwordFile=${lib.escapeShellArg l.passwordFile}
                ;;
            '') cfg.locations
          )}
          *) usage ;;
          esac

          case "$name" in
          ${lib.concatMapStrings (
            b:
            lib.concatLines (
              [ "${b.name})" ]
              ++ map (s: "  ${s}") (
                map (u: "systemctl stop ${lib.escapeShellArg u}") b.stop
                ++ [
                  ''restic -r "$base/${b.name}" --password-file "$passwordFile" restore latest --target /''
                ]
                ++ map (db: "runuser -u postgres -- ${psql} --dbname=${db} < ${dumpDir b}/${db}.sql") b.postgres
                ++ map (u: "systemctl start ${lib.escapeShellArg u}") b.stop
                ++ [ ";;" ]
              )
            )
          ) backups}
          *) usage ;;
          esac
        '';
      };
    in
    {
      options.ark.backup = {
        locations = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options.repository = lib.mkOption {
                type = lib.types.str;
                example = "rest:http://backup:8000";
                description = "Where the repositories go, each at <repository>/<name>: a directory, rest:..., or anything restic takes.";
              };
              options.passwordFile = lib.mkOption {
                type = lib.types.str;
                default = config.sops.secrets.restic-password.path;
                defaultText = lib.literalExpression "config.sops.secrets.restic-password.path";
              };
            }
          );
          default = { };
          description = "Where this host's backups go, by name: every service with a backup gets a job for each.";
        };
        services = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, ... }:
              {
                options = {
                  name = lib.mkOption {
                    type = lib.types.str;
                    default = name;
                    description = "The repository and job name.";
                  };
                  paths = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                  };
                  exclude = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                  };
                  postgres = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                    description = "Databases dumped to /var/backup/<name>/<db>.sql before the copy.";
                  };
                  stop = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                    description = "Units stopped while the dumps and the copy are made.";
                  };
                  schedule = lib.mkOption {
                    type = lib.types.str;
                    default = "daily";
                    description = "When the jobs run, as OnCalendar.";
                  };
                };
              }
            )
          );
          default = { };
          description = "What each service keeps, from the `backup` on its ark.services spec.";
        };
      };

      config = lib.mkIf (backups != [ ]) {
        warnings =
          lib.optional (cfg.locations == { })
            "ark.backup: ${toString (lib.attrNames cfg.services)} have backups, but this host sets no ark.backup.locations, so none run.";

        services.restic.backups = lib.listToAttrs (
          map (
            j:
            lib.nameValuePair j.name {
              repository = "${j.l.repository}/${j.b.name}";
              inherit (j.l) passwordFile;
              initialize = true;
              paths = j.b.paths ++ lib.optional (j.b.postgres != [ ]) (dumpDir j.b);
              inherit (j.b) exclude;
              timerConfig = {
                OnCalendar = j.b.schedule;
                Persistent = true;
              };
            }
          ) jobs
        );

        systemd.services =
          lib.listToAttrs (
            map (
              j:
              lib.nameValuePair "restic-backups-${j.name}" (
                lib.mkMerge [
                  (lib.mkIf (needsPrepare j.b) {
                    requires = [ "${prepareUnit j.b}.service" ];
                    after = [ "${prepareUnit j.b}.service" ];
                  })
                  # When it last succeeded, for monitoring (aspects/metrics.nix,
                  # services/dash): only reached when the backup did.
                  {
                    serviceConfig.ExecStartPost = [
                      (pkgs.writeShellScript "restic-${j.name}-metric" ''
                        f=${config.ark.metrics.textfileDir}/restic-${j.name}.prom
                        printf 'restic_backup_last_success_timestamp_seconds{backup="%s",location="%s"} %s\n' \
                          ${j.b.name} ${j.loc} "$(date +%s)" > "$f.tmp"
                        mv "$f.tmp" "$f"
                      '')
                    ];
                  }
                ]
              )
            ) jobs
          )
          // lib.listToAttrs (
            map (
              b:
              lib.nameValuePair (prepareUnit b) {
                description = "Stop ${b.name} and dump its databases for its backups";
                unitConfig.StopWhenUnneeded = true;
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                path = [
                  config.systemd.package
                  pkgs.util-linux
                ];
                script = ''
                  : > ${stoppedFile b}
                  for unit in ${lib.escapeShellArgs b.stop}; do
                    if systemctl is-active --quiet "$unit"; then
                      echo "$unit" >> ${stoppedFile b}
                      systemctl stop "$unit"
                    fi
                  done

                  mkdir -p ${dumpDir b}
                  ${lib.concatMapStrings (db: ''
                    runuser -u postgres -- ${pgDump} --clean --if-exists --dbname=${db} > ${dumpDir b}/${db}.sql
                  '') b.postgres}
                '';
                # ExecStopPost: runs too when the script above failed.
                postStop = ''
                  if [ -f ${stoppedFile b} ]; then
                    xargs -r systemctl start < ${stoppedFile b}
                    rm -f ${stoppedFile b}
                  fi
                '';
              }
            ) (lib.filter needsPrepare backups)
          );

        # restic itself, for looking into a repository by hand.
        environment.systemPackages = [
          restore
          pkgs.restic
        ];
      };
    };

  # Active on every host; inert where no service has a backup.
  den.schema.host.includes = [ config.den.aspects.ark-backups ];
}
