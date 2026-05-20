const { withXcodeProject } = require("expo/config-plugins");

const XCODE_LINK_WORKAROUNDS = {
  ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS: "NO",
  ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS: "NO",
  ENABLE_DEBUG_DYLIB: "NO",
};

module.exports = function withXcodeAssetSymbolWorkaround(config) {
  return withXcodeProject(config, (config) => {
    const buildConfigurations = config.modResults.pbxXCBuildConfigurationSection();

    for (const buildConfiguration of Object.values(buildConfigurations)) {
      if (!buildConfiguration || typeof buildConfiguration !== "object") {
        continue;
      }

      if (!buildConfiguration.buildSettings) {
        continue;
      }

      for (const [setting, value] of Object.entries(XCODE_LINK_WORKAROUNDS)) {
        buildConfiguration.buildSettings[setting] = value;
      }
    }

    return config;
  });
};
