// Metro config: bundle the SHARED protocol packages from the repo (../packages) and
// loam-sync's catch-up (../third_party/loam-sync/dist) so the phone runs the exact code
// the desktop core is tested against - no vendored fork, no drift.
//  - watchFolders: the two external roots (NOT the repo root - that confuses the crawler).
//  - nodeModulesPaths: resolve their bare imports (@noble/*) from mobile/node_modules.
//  - .mjs is source.
const { getDefaultConfig } = require("expo/metro-config");
const path = require("path");

const projectRoot = __dirname;
const repoRoot = path.resolve(projectRoot, "..");
const config = getDefaultConfig(projectRoot);

config.watchFolders = [path.resolve(repoRoot, "packages"), path.resolve(repoRoot, "third_party/loam-sync/dist")];
config.resolver.sourceExts = Array.from(new Set([...config.resolver.sourceExts, "mjs"]));
config.resolver.nodeModulesPaths = [path.join(projectRoot, "node_modules")];
config.resolver.useWatchman = false;

module.exports = config;
