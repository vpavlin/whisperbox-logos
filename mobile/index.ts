// Entropy first: @noble (identity keys, ECIES nonces, receipt ids) draws from
// crypto.getRandomValues, which Hermes does not have. Must load before anything else.
import "react-native-get-random-values";
// Hermes has no Node Buffer; loam-sync's catch-up fingerprint (reconcile.js) hex-encodes with
// Buffer.from(..).toString("hex"). Without this every catch-up round throws (seen on device).
import { Buffer } from "buffer";
if (typeof (globalThis as any).Buffer === "undefined") (globalThis as any).Buffer = Buffer;
import { installGlobalHandler } from "./src/lib/crashlog";
installGlobalHandler(); // uncaught JS errors -> on-screen report instead of a crash
import { registerRootComponent } from "expo";
import App from "./App";
registerRootComponent(App);
