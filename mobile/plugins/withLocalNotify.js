/**
 * withLocalNotify — local-only notifications ("new answers", "the creator replied").
 *
 * Replaces expo-notifications, which bundles Firebase Cloud Messaging (+ Firebase
 * Installations, the Play install referrer and ~17 launcher-badge permissions) even when
 * push is never used. WhisperBox has no push server: the app watches its own synced state
 * and posts notifications itself, so none of that is needed (and Firebase code keeps an
 * app out of the official F-Droid repo).
 *
 * Copies native/localnotify (a tiny Kotlin module + a status-bar icon) into android/ on
 * every prebuild, registers the package, and declares POST_NOTIFICATIONS (Android 13+).
 */
const { withDangerousMod, withMainApplication, withAndroidManifest } = require("@expo/config-plugins");
const fs = require("fs");
const path = require("path");

const PACKAGE_IMPORT = "xyz.vpavlin.whisperbox.notify.LocalNotifyPackage";

function copyDir(src, dst) {
  fs.mkdirSync(dst, { recursive: true });
  for (const e of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, e.name), d = path.join(dst, e.name);
    if (e.isDirectory()) copyDir(s, d); else fs.copyFileSync(s, d);
  }
}

const withFiles = (config) =>
  withDangerousMod(config, ["android", async (cfg) => {
    const stage = path.join(cfg.modRequest.projectRoot, "native", "localnotify");
    const app = path.join(cfg.modRequest.platformProjectRoot, "app/src/main");
    copyDir(path.join(stage, "android", "java"), path.join(app, "java"));
    copyDir(path.join(stage, "res"), path.join(app, "res"));
    return cfg;
  }]);

const withPackage = (config) =>
  withMainApplication(config, (cfg) => {
    let src = cfg.modResults.contents;
    if (!src.includes(PACKAGE_IMPORT)) {
      const before = src;
      src = src.replace(/PackageList\(this\)\.packages\.apply\s*\{/,
        `PackageList(this).packages.apply {\n          // Local notifications (no Firebase) — manual package, not autolinkable.\n          add(${PACKAGE_IMPORT}())`);
      if (src === before) throw new Error("withLocalNotify: MainApplication package list not found");
      cfg.modResults.contents = src;
    }
    return cfg;
  });

const withPermission = (config) =>
  withAndroidManifest(config, (cfg) => {
    const m = cfg.modResults.manifest;
    m["uses-permission"] = m["uses-permission"] || [];
    const name = "android.permission.POST_NOTIFICATIONS";
    if (!m["uses-permission"].some((p) => p.$["android:name"] === name)) m["uses-permission"].push({ $: { "android:name": name } });
    return cfg;
  });

module.exports = (config) => withPermission(withPackage(withFiles(config)));
