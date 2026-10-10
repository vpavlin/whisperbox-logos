// Metro config: bundle the WhisperBox SDK (../packages, a submodule: protocol, templates,
// RN adapter, and loam-sync's catch-up in packages/loam-sync-pkg) so the phone runs the exact
// code the desktop core is tested against - no vendored fork, no drift.
//  - watchFolders: the SDK root (NOT the repo root - that confuses the crawler).
//  - nodeModulesPaths: resolve their bare imports (@noble/*) from mobile/node_modules.
//  - .mjs is source.
const { getDefaultConfig } = require("expo/metro-config");
const path = require("path");

const projectRoot = __dirname;
const repoRoot = path.resolve(projectRoot, "..");
const config = getDefaultConfig(projectRoot);

config.watchFolders = [path.resolve(repoRoot, "packages")];
config.resolver.sourceExts = Array.from(new Set([...config.resolver.sourceExts, "mjs"]));
config.resolver.nodeModulesPaths = [path.join(projectRoot, "node_modules")];
config.resolver.useWatchman = false;

module.exports = config;
