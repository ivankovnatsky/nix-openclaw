{
  config,
  lib,
  pkgs,
}:

let
  cfg = config.programs.openclaw;
  homeDir = config.home.homeDirectory;
  autoExcludeTools = lib.optionals config.programs.git.enable [ "git" ];
  effectiveExcludeTools = lib.unique (cfg.excludeTools ++ autoExcludeTools);
  toolOverrides = {
    toolNamesOverride = cfg.toolNames;
    excludeToolNames = effectiveExcludeTools;
  };
  toolOverridesEnabled = cfg.toolNames != null || effectiveExcludeTools != [ ];
  toolSets = import ../../../tools/extended.nix ({ inherit pkgs; } // toolOverrides);
  defaultPackage =
    if toolOverridesEnabled && cfg.package == pkgs.openclaw then
      (pkgs.openclawPackages.withTools toolOverrides).openclaw
    else
      cfg.package;
  appPackage = if cfg.appPackage != null then cfg.appPackage else defaultPackage;
  generatedConfigOptions = import ../../../generated/openclaw-config-options.nix { lib = lib; };
  pluginCatalog = import ./plugin-catalog.nix;

  bundledPluginSources =
    let
      stepieteRev = "c110209720cbc6c87fccb6c1e1c2b79b1d719245";
      stepieteNarHash = "sha256-1Vo7rcLGdKaqj39J3HhBKh8IbljSjgCUhinCFJbDPl8=";
      stepiete =
        tool:
        "github:openclaw/nix-steipete-tools?dir=tools/${tool}&rev=${stepieteRev}&narHash=${stepieteNarHash}";
    in
    lib.mapAttrs (_name: plugin: plugin.source or (stepiete plugin.tool)) pluginCatalog;

  bundledPlugins = lib.filter (p: p != null) (
    lib.mapAttrsToList (
      name: source:
      let
        pluginCfg = cfg.bundledPlugins.${name};
      in
      if (pluginCfg.enable or false) then
        {
          inherit source;
          config = pluginCfg.config or { };
        }
      else
        null
    ) bundledPluginSources
  );

  effectivePlugins = cfg.customPlugins ++ bundledPlugins;

  resolvePath = p: if lib.hasPrefix "~/" p then "${homeDir}/${lib.removePrefix "~/" p}" else p;

  toRelative = p: if lib.hasPrefix "${homeDir}/" p then lib.removePrefix "${homeDir}/" p else p;

  isUnderHome = p: lib.hasPrefix "${homeDir}/" p;

in
{
  inherit
    cfg
    homeDir
    toolOverrides
    toolOverridesEnabled
    toolSets
    defaultPackage
    appPackage
    generatedConfigOptions
    bundledPluginSources
    bundledPlugins
    effectivePlugins
    resolvePath
    toRelative
    isUnderHome
    ;
}
