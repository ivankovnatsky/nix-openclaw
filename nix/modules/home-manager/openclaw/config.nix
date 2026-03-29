{
  config,
  lib,
  pkgs,
  ...
}:

let
  openclawLib = import ./lib.nix { inherit config lib pkgs; };
  cfg = openclawLib.cfg;
  homeDir = openclawLib.homeDir;
  appPackage = openclawLib.appPackage;

  defaultInstance = {
    enable = cfg.enable;
    package = openclawLib.defaultPackage;
    stateDir = cfg.stateDir;
    workspaceDir = cfg.workspaceDir;
    configPath = "${cfg.stateDir}/openclaw.json";
    logPath = "/tmp/openclaw/openclaw-gateway.log";
    gatewayPort = 18789;
    gatewayPath = null;
    gatewayPnpmDepsHash = lib.fakeHash;
    launchd = cfg.launchd;
    systemd = cfg.systemd;
    plugins = openclawLib.effectivePlugins;
    config = { };
    appDefaults = {
      enable = true;
      attachExistingOnly = true;
    };
    app = {
      install = {
        enable = false;
        path = "${homeDir}/Applications/OpenClaw.app";
      };
    };
  };

  instances =
    if cfg.instances != { } then
      cfg.instances
    else
      lib.optionalAttrs cfg.enable { default = defaultInstance; };

  enabledInstances = lib.filterAttrs (_: inst: inst.enable) instances;

  plugins = import ./plugins.nix {
    inherit
      lib
      pkgs
      openclawLib
      enabledInstances
      ;
  };

  files = import ./files.nix {
    inherit
      config
      lib
      pkgs
      openclawLib
      enabledInstances
      plugins
      ;
  };

  stripNulls =
    value:
    if value == null then
      null
    else if builtins.isAttrs value then
      lib.filterAttrs (_: v: v != null) (builtins.mapAttrs (_: stripNulls) value)
    else if builtins.isList value then
      builtins.filter (v: v != null) (map stripNulls value)
    else
      value;

  baseConfig = {
    gateway = {
      mode = "local";
    };
  };

  mkInstanceConfig =
    name: inst:
    let
      gatewayPackage =
        if inst.gatewayPath != null then
          pkgs.callPackage ../../packages/openclaw-gateway.nix {
            gatewaySrc = builtins.path {
              path = inst.gatewayPath;
              name = "openclaw-gateway-src";
            };
            pnpmDepsHash = inst.gatewayPnpmDepsHash;
          }
        else
          inst.package;
      pluginPackages = plugins.pluginPackagesFor name;
      pluginEnvAll = plugins.pluginEnvAllFor name;
      mergedConfig0 = stripNulls (
        lib.recursiveUpdate (lib.recursiveUpdate baseConfig cfg.config) inst.config
      );
      existingWorkspace = (((mergedConfig0.agents or { }).defaults or { }).workspace or null);
      mergedConfig =
        if (cfg.workspace.pinAgentDefaults or true) && existingWorkspace == null then
          lib.recursiveUpdate mergedConfig0 {
            agents = {
              defaults = {
                workspace = inst.workspaceDir;
              };
            };
          }
        else
          mergedConfig0;
      configJson = builtins.toJSON mergedConfig;
      configFile = pkgs.writeText "openclaw-${name}.json" configJson;
      gatewayWrapper = pkgs.writeShellScriptBin "openclaw-gateway-${name}" ''
        set -euo pipefail

        if [ -n "${lib.makeBinPath pluginPackages}" ]; then
          export PATH="${lib.makeBinPath pluginPackages}:$PATH"
        fi

        ${lib.concatStringsSep "\n" (
          map (
            entry:
            let
              isFile = lib.hasSuffix "_FILE" entry.key;
            in
            ''
              if [ -f "${entry.value}" ]; then
                if ${if isFile then "true" else "false"}; then
                  export ${entry.key}="${entry.value}"
                else
                  rawValue="$("${lib.getExe' pkgs.coreutils "cat"}" "${entry.value}")"
                  if [ "''${rawValue#${entry.key}=}" != "$rawValue" ]; then
                    export ${entry.key}="''${rawValue#${entry.key}=}"
                  else
                    export ${entry.key}="$rawValue"
                  fi
                fi
              else
                export ${entry.key}="${entry.value}"
              fi
            ''
          ) pluginEnvAll
        )}

        exec "${gatewayPackage}/bin/openclaw" "$@"
      '';
      appDefaults = lib.optionalAttrs (pkgs.stdenv.hostPlatform.isDarwin && inst.appDefaults.enable) {
        attachExistingOnly = inst.appDefaults.attachExistingOnly;
        gatewayPort = inst.gatewayPort;
        nixMode = inst.appDefaults.nixMode;
      };

      appInstall =
        if !(pkgs.stdenv.hostPlatform.isDarwin && inst.app.install.enable && appPackage != null) then
          null
        else
          {
            name = lib.removePrefix "${homeDir}/" inst.app.install.path;
            value = {
              source = "${appPackage}/Applications/OpenClaw.app";
              recursive = true;
              force = true;
            };
          };

      package = gatewayPackage;
    in
    {
      homeFile = if openclawLib.isUnderHome inst.configPath then {
        name = openclawLib.toRelative inst.configPath;
        value = {
          text = configJson;
        };
      } else null;
      externalConfigFile = if openclawLib.isUnderHome inst.configPath then null else {
        target = inst.configPath;
        text = configJson;
      };
      configFile = configFile;
      configPath = inst.configPath;

      dirs = [
        inst.stateDir
        inst.workspaceDir
        (builtins.dirOf inst.logPath)
      ];

      launchdAgent = lib.optionalAttrs (pkgs.stdenv.hostPlatform.isDarwin && inst.launchd.enable) {
        "${inst.launchd.label}" = {
          enable = true;
          config = {
            Label = inst.launchd.label;
            ProgramArguments = [
              "${gatewayWrapper}/bin/openclaw-gateway-${name}"
              "gateway"
              "--port"
              "${toString inst.gatewayPort}"
            ];
            RunAtLoad = true;
            KeepAlive = true;
            WorkingDirectory = inst.stateDir;
            StandardOutPath = inst.logPath;
            StandardErrorPath = inst.logPath;
            EnvironmentVariables = {
              HOME = homeDir;
              OPENCLAW_CONFIG_PATH = inst.configPath;
              OPENCLAW_STATE_DIR = inst.stateDir;
              OPENCLAW_IMAGE_BACKEND = "sips";
              OPENCLAW_NIX_MODE = "1";
            };
          };
        };
      };

      systemdService = lib.optionalAttrs (pkgs.stdenv.hostPlatform.isLinux && inst.systemd.enable) {
        "${inst.systemd.unitName}" = {
          Unit = {
            Description = "OpenClaw gateway (${name})";
          };
          Service = {
            ExecStart = "${gatewayWrapper}/bin/openclaw-gateway-${name} gateway --port ${toString inst.gatewayPort}";
            WorkingDirectory = inst.stateDir;
            Restart = "always";
            RestartSec = "1s";
            Environment = [
              "HOME=${homeDir}"
              "OPENCLAW_CONFIG_PATH=${inst.configPath}"
              "OPENCLAW_STATE_DIR=${inst.stateDir}"
              "OPENCLAW_NIX_MODE=1"
            ];
            StandardOutput = "append:${inst.logPath}";
            StandardError = "append:${inst.logPath}";
          };
        };
      };

      appDefaults = appDefaults;
      appInstall = appInstall;
      package = package;
    };

  instanceConfigs = lib.mapAttrsToList mkInstanceConfig enabledInstances;
  appInstalls = lib.filter (item: item != null) (map (item: item.appInstall) instanceConfigs);

  appDefaults = lib.foldl' (acc: item: lib.recursiveUpdate acc item.appDefaults) { } instanceConfigs;
  appDefaultsEnabled = lib.filterAttrs (_: inst: inst.appDefaults.enable) enabledInstances;

in
{
  config = lib.mkIf (cfg.enable || cfg.instances != { }) {
    assertions = [
      {
        assertion = lib.length (lib.attrNames appDefaultsEnabled) <= 1;
        message = "Only one OpenClaw instance may enable appDefaults.";
      }
    ]
    ++ files.documentsAssertions
    ++ files.skillAssertions
    ++ plugins.pluginAssertions
    ++ plugins.pluginSkillAssertions;

    home.packages = lib.unique (
      (map (item: item.package) instanceConfigs)
      ++ (lib.optionals cfg.exposePluginPackages plugins.pluginPackagesAll)
    );

    home.file = lib.mkMerge [
      (lib.listToAttrs (lib.filter (item: item != null) (map (item: item.homeFile) instanceConfigs)))
      (lib.optionalAttrs (pkgs.stdenv.hostPlatform.isDarwin && appPackage != null && cfg.installApp) {
        "Applications/OpenClaw.app" = {
          source = "${appPackage}/Applications/OpenClaw.app";
          recursive = true;
          force = true;
        };
      })
      (lib.listToAttrs appInstalls)
      files.documentsFiles
      files.skillFiles
      plugins.pluginConfigFiles
      (lib.optionalAttrs cfg.reloadScript.enable {
        ".local/bin/openclaw-reload" = {
          executable = true;
          source = ../openclaw-reload.sh;
        };
      })
    ];

    home.activation.openclawDocumentGuard = lib.mkIf files.documentsEnabled (
      lib.hm.dag.entryBefore [ "writeBoundary" ] ''
        set -euo pipefail
        ${files.documentsGuard}
      ''
    );

    home.activation.openclawDirs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run --quiet ${lib.getExe' pkgs.coreutils "mkdir"} -p ${
        lib.concatStringsSep " " (lib.concatMap (item: item.dirs) instanceConfigs)
      }
      ${lib.optionalString (plugins.pluginStateDirsAll != [ ])
        "run --quiet ${lib.getExe' pkgs.coreutils "mkdir"} -p ${lib.concatStringsSep " " plugins.pluginStateDirsAll}"
      }
    '';

    home.activation.openclawExternalFiles =
      let
        externalConfigFiles = lib.filter (item: item != null) (map (item: item.externalConfigFile) instanceConfigs);
        allExternal = lib.unique (
          externalConfigFiles
          ++ files.skillFilesExternal
          ++ files.documentsFilesExternal
          ++ plugins.pluginSkillsExternal
          ++ plugins.pluginConfigExternal
        );
        firstInstance = lib.head (lib.attrValues enabledInstances);
        manifestPath = "${firstInstance.stateDir}/.nix-external-files";
        targetPaths = map (e: e.target) allExternal;
        manifestFile = pkgs.writeText "openclaw-external-manifest" (lib.concatStringsSep "\n" targetPaths);
        rm = lib.getExe' pkgs.coreutils "rm";
        mkdir = lib.getExe' pkgs.coreutils "mkdir";
        ln = lib.getExe' pkgs.coreutils "ln";
        dirname = lib.getExe' pkgs.coreutils "dirname";
        mkLink = entry:
          if entry ? text then
            let
              file = pkgs.writeText (builtins.baseNameOf entry.target) entry.text;
            in
            ''
              run --quiet ${mkdir} -p "$(${dirname} "${entry.target}")"
              run --quiet ${rm} -rf "${entry.target}"
              run --quiet ${ln} -sfn ${file} "${entry.target}"
            ''
          else
            ''
              run --quiet ${mkdir} -p "$(${dirname} "${entry.target}")"
              run --quiet ${rm} -rf "${entry.target}"
              run --quiet ${ln} -sfn ${entry.source} "${entry.target}"
            '';
      in
      lib.mkIf (allExternal != [ ]) (
        lib.hm.dag.entryAfter [ "openclawDirs" ] ''
          set -euo pipefail

          # Remove stale external files from previous activation
          if [ -f "${manifestPath}" ]; then
            while IFS= read -r old; do
              [ -z "$old" ] && continue
              found=0
              for cur in ${lib.concatStringsSep " " (map (p: ''"${p}"'') targetPaths)}; do
                if [ "$old" = "$cur" ]; then
                  found=1
                  break
                fi
              done
              if [ "$found" = "0" ] && { [ -e "$old" ] || [ -L "$old" ]; }; then
                run --quiet ${rm} -rf "$old"
              fi
            done < "${manifestPath}"
          fi

          ${lib.concatStringsSep "\n" (map mkLink allExternal)}

          # Write current manifest
          run --quiet ${ln} -sfn ${manifestFile} "${manifestPath}"
        ''
      );

    home.activation.openclawConfigFiles = lib.hm.dag.entryAfter [ "openclawDirs" ] ''
      ${lib.concatStringsSep "\n" (
        map (
          item: "run --quiet ${lib.getExe' pkgs.coreutils "ln"} -sfn ${item.configFile} ${item.configPath}"
        ) instanceConfigs
      )}
    '';

    home.activation.openclawPluginGuard = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      set -euo pipefail
      ${plugins.pluginGuards}
    '';

    home.activation.openclawAppDefaults =
      lib.mkIf (pkgs.stdenv.hostPlatform.isDarwin && appDefaults != { })
        (
          lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            # Nix mode + app defaults (OpenClaw.app)
            /usr/bin/defaults write ai.openclaw.mac openclaw.nixMode -bool ${
              lib.boolToString (appDefaults.nixMode or true)
            }
            /usr/bin/defaults write ai.openclaw.mac openclaw.gateway.attachExistingOnly -bool ${
              lib.boolToString (appDefaults.attachExistingOnly or true)
            }
            /usr/bin/defaults write ai.openclaw.mac gatewayPort -int ${
              toString (appDefaults.gatewayPort or 18789)
            }
          ''
        );

    home.activation.openclawLaunchdRelink = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin (
      lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        /usr/bin/env bash ${../openclaw-launchd-relink.sh}
      ''
    );

    systemd.user.services = lib.mkIf pkgs.stdenv.hostPlatform.isLinux (
      lib.mkMerge (map (item: item.systemdService) instanceConfigs)
    );

    launchd.agents = lib.mkMerge (map (item: item.launchdAgent) instanceConfigs);
  };
}
