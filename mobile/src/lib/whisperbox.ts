// The app service: one WhisperboxClient (the shared protocol from ../packages) wired to
// loam-transport. Network = the device-wide Loam node (shared, default) or an embedded
// node fallback; the protocol is identical either way.
import * as transport from "./loam-transport";
import * as SecureStore from "expo-secure-store";
import { fileStore, secretStore } from "./store";
// @ts-ignore - plain ESM shared with the desktop reference + tests
import { WhisperboxClient, TOPIC, parseLink } from "../../../packages/client/src/client.mjs";

export const APP_ID = "xyz.vpavlin.whisperbox";
export { parseLink };

export const client: any = new WhisperboxClient({
  store: fileStore,
  secrets: secretStore,
  send: (bytes: Uint8Array) => transport.publishSealed(TOPIC, bytes),
});

export const net = { status: "Starting…", started: false, error: "", shared: true };
let ticker: ReturnType<typeof setInterval> | null = null;
let booted: Promise<void> | null = null;

/** Boot order matters (loam-integrate-app §2): read the shared-node preference and call
 *  preferServiceBackend BEFORE anything else touches the transport. */
export function boot(): Promise<void> {
  if (booted) return booted;
  booted = (async () => {
    await client.init();
    try { net.shared = (await SecureStore.getItemAsync("wb-shared-node")) !== "0"; } catch { net.shared = true; }
    transport.preferServiceBackend(net.shared, APP_ID);
    try {
      await transport.start({
        deviceId: client.deviceId,
        topics: [TOPIC],
        onReceive: (topic: string, candidates: Uint8Array[]) => topic === TOPIC && client.ingest(candidates),
        onStatus: (s: string) => { net.status = s; client.emit(); },
      });
      net.started = true; net.status = "Connected";
      client.onConnected();
      transport.storeSync((t: string, c: Uint8Array[]) => t === TOPIC && client.ingest(c)).catch(() => {});
    } catch (e: any) {
      net.error = String(e?.message || e); net.status = "Offline"; client.emit();
    }
    ticker = setInterval(() => client.tick(), 1000);
  })();
  return booted;
}

/** Applies on next launch (the backend choice is locked at start). */
export async function setSharedNode(on: boolean) {
  await SecureStore.setItemAsync("wb-shared-node", on ? "1" : "0");
  net.shared = on;
}

export function pullHistory() {
  if (!net.started) return Promise.resolve();
  client.resync();
  return transport.storeSync((t: string, c: Uint8Array[]) => t === TOPIC && client.ingest(c)).then(() => client.emit());
}
