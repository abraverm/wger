{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.wger;
  settingsFormat = pkgs.formats.json {};

  # Generate settings loader that applies json-provided djangoSettings and wgerSettings
  wgerSettingsJSON = pkgs.writeText "wger-settings.json" (builtins.toJSON cfg.wgerSettings);
  djangoSettingsJSON = pkgs.writeText "django-settings.json" (builtins.toJSON cfg.djangoSettings);

  settingsPy = pkgs.writeText "settings.py" ''
    from wger.settings_global import *
    import json
    import os

    def _subst(v):
        if isinstance(v, str) and v.startswith("$"):
            return os.environ.get(v[1:], v)
        if isinstance(v, str) and v.startswith("file:"):
            try:
                with open(v[5:], "r") as f:
                    return f.read().strip()
            except Exception:
                return v
        return v

    with open("${djangoSettingsJSON}") as f:
        for k, v in json.load(f).items():
            globals()[k] = _subst(v)

    with open("${wgerSettingsJSON}") as f:
        for k, v in json.load(f).items():
            WGER_SETTINGS[k] = _subst(v)
  '';
  settingsDir = pkgs.writeTextDir "settings.py" (builtins.readFile settingsPy);

  python = pkgs.python312 or pkgs.python3;
  siteDir = python.sitePackages;

  gunicornEnv = python.withPackages (ps: with ps; [gunicorn]);

  serviceUser = cfg.user;
  serviceGroup = cfg.group;

  settingsPath = "${settingsDir}/settings.py";

  runGunicorn = ''
    PYTHONPATH="${cfg.package}/${siteDir}:${settingsDir}" \
      ${gunicornEnv}/bin/gunicorn wger.wsgi:application --bind ${cfg.address}:${builtins.toString cfg.port}
  '';
in {
  options.services.wger = {
    enable = mkEnableOption "Wger fitness manager";

    package = mkOption {
      type = types.package;
      description = "Wger application environment (e.g. from uv2nix). Must include the 'wger' console script and Python libs.";
    };

    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address for the Gunicorn server.";
    };

    port = mkOption {
      type = types.port;
      default = 28391;
      description = "Port for the Gunicorn server.";
    };

    user = mkOption {
      type = types.str;
      default = "wger";
      description = "User running the service.";
    };

    group = mkOption {
      type = types.str;
      default = "wger";
      description = "Group running the service.";
    };

    dataDir = mkOption {
      type = types.str; # was types.path; use string path to be created at runtime
      default = "/var/lib/wger";
      description = "Persistent data directory.";
    };

    mediaDir = mkOption {
      type = types.str; # was types.path; dynamic path under dataDir
      default = "${cfg.dataDir}/media"; # don't wrap with mkDefault inside default
      description = "Media directory for uploaded files.";
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Environment file for secrets as in systemd.exec(5).";
    };

    configureRedis = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to configure a dedicated Redis instance and Django CACHES.";
    };

    configurePostgres = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to provision a PostgreSQL database and point Django to it.";
    };

    djangoSettings = mkOption {
      type = types.submodule {freeformType = settingsFormat.type;};
      default = {};
      description = "Django settings overlay (globals). Values starting with '$' are read from env, 'file:' read from file.";
    };

    wgerSettings = mkOption {
      type = types.submodule {freeformType = settingsFormat.type;};
      default = {};
      description = "Settings for WGER_SETTINGS dict. Values starting with '$' are read from env, 'file:' read from file.";
    };

    nginx = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable a basic nginx vhost proxy.";
      };
      serverName = mkOption {
        type = types.str;
        default = "";
        description = "Server name for nginx vhost (required when enabled).";
      };
      enableACME = mkOption {
        type = types.bool;
        default = true;
      };
      forceSSL = mkOption {
        type = types.bool;
        default = true;
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      users.users.${serviceUser} = {
        isSystemUser = true;
        group = serviceGroup;
        home = cfg.dataDir;
      };
      users.groups.${serviceGroup} = {};

      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 ${serviceUser} ${serviceGroup} - -"
        "d ${cfg.mediaDir} 0750 ${serviceUser} ${serviceGroup} - -"
      ];

      # Defaults
      services.wger.wgerSettings = {
        EMAIL_FROM = mkDefault "wger Workout Manager <wger@example.com>";
        ALLOW_REGISTRATION = mkDefault true;
        ALLOW_GUEST_USERS = mkDefault true;
        ALLOW_UPLOAD_VIDEOS = mkDefault false;
        MIN_ACCOUNT_AGE_TO_TRUST = mkDefault 21;
        EXERCISE_CACHE_TTL = mkDefault 3600;
      };

      services.wger.djangoSettings =
        {
          DEBUG = mkDefault false;
          MEDIA_ROOT = mkDefault cfg.mediaDir;
          MEDIA_URL = mkDefault "/media/";
        }
        // (mkIf cfg.configureRedis {
          CACHES = {
            default = {
              BACKEND = "django_redis.cache.RedisCache";
              LOCATION = mkIf cfg.configureRedis (
                if config.services.redis.servers?wger.unixSocket
                then "unix://" + config.services.redis.servers.wger.unixSocket
                else "redis://127.0.0.1:6379/0"
              );
              TIMEOUT = 1296000; # 15 days
              OPTIONS = {CLIENT_CLASS = "django_redis.client.DefaultClient";};
            };
          };
        })
        // (mkIf cfg.configurePostgres {
          DATABASES = {
            default = {
              ENGINE = "django.db.backends.postgresql";
              NAME = serviceUser;
              USER = serviceUser;
              PASSWORD = "";
              HOST = "/run/postgresql";
              PORT = "";
            };
          };
        });

      # Main service
      systemd.services.wger = {
        description = "wger fitness manager";
        wantedBy = ["multi-user.target"];
        after =
          [
            "network.target"
          ]
          ++ lib.optionals cfg.configurePostgres [
            "postgresql.service"
          ]
          ++ lib.optionals cfg.configureRedis ["redis-wger.service"];
        requires = lib.optional cfg.configurePostgres "postgresql.service";

        environment = {
          WGER_SETTINGS = settingsPath;
          # Ensure proper database connection environment
          PGHOST = mkIf cfg.configurePostgres "/run/postgresql";
          PGDATABASE = mkIf cfg.configurePostgres serviceUser;
          PGUSER = mkIf cfg.configurePostgres serviceUser;
        };

        preStart = ''
          ${lib.optionalString cfg.configurePostgres ''
            echo "Waiting for PostgreSQL to be ready..."
            for i in $(seq 1 60); do
              ${pkgs.postgresql}/bin/pg_isready -h /run/postgresql && break
              sleep 1
            done

            echo "Waiting for PostgreSQL role ${serviceUser} to be created..."
            for i in $(seq 1 120); do
              if ${pkgs.postgresql}/bin/psql -tA -h /run/postgresql -c "SELECT 1 FROM pg_roles WHERE rolname='${serviceUser}'" | grep -q 1; then
                echo "Role ${serviceUser} exists."
                break
              fi
              sleep 0.5
            done
          ''}
          # Run database migrations (now that DB/role should exist)
          ${cfg.package}/bin/wger migrate-db --settings-path ${settingsPath}
        '';

        script = runGunicorn;

        serviceConfig =
          {
            User = serviceUser;
            Group = serviceGroup;
            Restart = "on-failure";
            RestartSec = 5;
            WorkingDirectory = cfg.dataDir;
          }
          // (lib.optionalAttrs (cfg.environmentFile != null) {EnvironmentFile = cfg.environmentFile;});
      };
    }

    (mkIf cfg.configurePostgres {
      services.postgresql = {
        enable = true;
        ensureDatabases = [serviceUser];
        ensureUsers = [
          {
            name = serviceUser;
            ensureDBOwnership = true;
          }
        ];
      };
    })

    (mkIf cfg.configureRedis {
      services.redis.servers.wger = {
        enable = true;
        user = serviceUser;
      };
    })

    (mkIf cfg.nginx.enable {
      assertions = [
        {
          assertion = cfg.nginx.serverName != "";
          message = "services.wger.nginx.serverName must be set when nginx is enabled";
        }
      ];
      services.nginx.enable = true;
      services.nginx.virtualHosts."${cfg.nginx.serverName}" = {
        enableACME = cfg.nginx.enableACME;
        forceSSL = cfg.nginx.forceSSL;
        locations."/".proxyPass = "http://${cfg.address}:${toString cfg.port}";
        # Optionally serve media
        locations."/media".root = cfg.mediaDir;
      };
    })
  ]);
}
