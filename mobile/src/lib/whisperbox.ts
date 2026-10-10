// The app service: the WhisperBox SDK's RN adapter (../packages/rn) wired to this app's
// loam-transport. Network = the device-wide Loam node (shared, default) or an embedded
// node fallback; the protocol is identical either way.
import * as transport from "./loam-transport";
import { crumb, initCrashLog } from "./crashlog";
import { createWhisperbox, getAppId, parseLink } from "../../../packages/rn";

export const APP_ID = getAppId();   // xyz.vpavlin.whisperbox (the SDK default)
export { parseLink };

const wb = createWhisperbox({ transport, log: crumb });
export const client: any = wb.client;
export const net = wb.net;
export const setSharedNode = wb.setSharedNode;
export const pullHistory = wb.pullHistory;

let booted: Promise<void> | null = null;
export function boot(): Promise<void> {
  if (!booted) booted = (async () => { await initCrashLog(); await wb.boot(); })();
  return booted;
}
