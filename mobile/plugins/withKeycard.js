// NFC for Keycard (react-native-keycard). Same as scala's plugin: NFC permission, and the HCE
// feature declared NOT required - F-Droid hides an app from devices lacking a required
// feature, and Keycard is optional (forms work without it).
const { withAndroidManifest } = require("@expo/config-plugins");
module.exports = function withKeycard(config) {
  return withAndroidManifest(config, (cfg) => {
    const m = cfg.modResults.manifest;
    m["uses-permission"] = m["uses-permission"] || [];
    if (!m["uses-permission"].some((p) => p.$ && p.$["android:name"] === "android.permission.NFC"))
      m["uses-permission"].push({ $: { "android:name": "android.permission.NFC" } });
    m["uses-feature"] = m["uses-feature"] || [];
    for (const name of ["android.hardware.nfc", "android.hardware.nfc.hce"]) {
      const f = m["uses-feature"].find((x) => x.$ && x.$["android:name"] === name);
      if (f) f.$["android:required"] = "false";
      else m["uses-feature"].push({ $: { "android:name": name, "android:required": "false" } });
    }
    return cfg;
  });
};
