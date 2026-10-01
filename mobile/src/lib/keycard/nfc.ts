// WhisperBox x Keycard - the NFC transport. Drives one tap: start listening, wait for the card,
// run card.ts on it, stop listening (ALWAYS, on every exit - a reader left listening wedges
// the next tap, seen with scala/the choppu example).
//
// Uses only react-native-keycard's NATIVE module (TurboModule "Keycard"); its JS layer is
// bypassed on purpose: that layer pins keycard-sdk 3.x, so its NFCCardChannel throws a
// different CardIOError class than the 4.x SDK we use - an NFC glitch would then look like a
// failed pairing and the SDK would delete the stored pairing (each re-pair uses one of a
// 3.x card's 5 slots). It also pulls react-native-mmkv in for pairing storage; we keep the
// pairing in SecureStore instead.
import { TurboModuleRegistry } from "react-native";
import * as SecureStore from "expo-secure-store";
import { KeycardManager } from "keycard-sdk/dist/keycard-manager.js";
import { APDUResponse } from "keycard-sdk/dist/apdu-response.js";
import { CardIOError } from "keycard-sdk/dist/apdu-exception.js";
import { exportFormKeys, isLostContact, CardError, type CardAccess, type ExportResult } from "./card";
import { toHex, fromHex } from "../../../../packages/contract/src/crypto-portable.mjs";

type Core = {
  isNFCSupported(): Promise<boolean>; isNFCEnabled(): Promise<boolean>; openNFCSettings(): Promise<boolean>;
  startNFC(prompt: string): Promise<boolean>; stopNFC(): Promise<boolean>;
  send(apdu: string): Promise<{ data: string; state: string }>; isKeycardConnected(): boolean;
  onKeycardConnected(cb: () => void): { remove(): void };
};
// Looked up lazily (at tap time): the module starts NFC reader mode on the current activity
// when it is first created, so it must not be created before there is one.
const core = (): Core | null => { try { return TurboModuleRegistry.get<any>("Keycard") as Core | null; } catch { return null; } };

export async function nfcStatus(): Promise<"ok" | "off" | "unsupported"> {
  const c = core();
  if (!c) return "unsupported";
  try {
    if (!(await c.isNFCSupported())) return "unsupported";
    return (await c.isNFCEnabled()) ? "ok" : "off";
  } catch { return "unsupported"; }
}
export function openNfcSettings() { core()?.openNFCSettings().catch(() => {}); }

// APDU channel over the native module. Checks the card is still there before each command:
// the 1.0.4 native send() dereferences a null tag if the card was pulled away.
function channel(c: Core) {
  return {
    isConnected: () => { try { return c.isKeycardConnected(); } catch { return false; } },
    async send(cmd: { serialize(): Uint8Array }) {
      if (!this.isConnected()) throw new CardIOError(new Error("Card moved away - hold it still against the phone"));
      let r;
      try { r = await c.send(toHex(cmd.serialize())); } catch (e) { throw new CardIOError(e instanceof Error ? e : new Error(String(e))); }
      if (!r || r.state !== "success") throw new CardIOError(new Error("Lost contact with the card - hold it still against the phone"));
      return new APDUResponse(fromHex(r.data));
    },
  };
}

// Pairing (applet 3.x only; 4.x has no pairing) in SecureStore, per card instance.
const pairingStorage = {
  key: (uid: any) => "wb-kc-pair-" + toHex(uid instanceof Uint8Array ? uid : Uint8Array.from(Object.values(uid || {}) as number[])),
  async getPairing(uid: any) { return SecureStore.getItemAsync(this.key(uid)); },
  async putPairing(uid: any, p: string) { await SecureStore.setItemAsync(this.key(uid), p, { keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY }); },
  async deletePairing(uid: any) { await SecureStore.deleteItemAsync(this.key(uid)); },
};
const manager = new KeycardManager(pairingStorage as any);

let cancelActive: (() => void) | null = null;
/** Cancel a tap in progress (the "Hold your Keycard" sheet's Cancel button). */
export function cancelTap() { cancelActive?.(); }

/** One tap: export the keys of `formIds`. Rejects with CardError (readable message). */
export function tapExportFormKeys(access: CardAccess, formIds: string[], prompt = "Hold your Keycard to the back of the phone"): Promise<ExportResult> {
  const c = core();
  if (!c) return Promise.reject(new CardError("Keycard support is not available in this build", "unsupported"));
  return new Promise((resolve, reject) => {
    let done = false, busy = false;
    let sub: { remove(): void } | null = null;
    const timer = setTimeout(() => finish(() => reject(new CardError("No Keycard detected within 60 seconds", "timeout"))), 60_000);
    const finish = (fn: () => void) => {
      if (done) return; done = true;
      clearTimeout(timer); cancelActive = null;
      try { sub?.remove(); } catch { /* */ }
      c.stopNFC().catch(() => {}).finally(fn);
    };
    cancelActive = () => finish(() => reject(new CardError("Cancelled", "cancelled")));
    try {
      sub = c.onKeycardConnected(async () => {
        if (busy || done) return; // one session per tap; a bounce re-fires the event
        busy = true;
        try {
          const r = await exportFormKeys(manager, channel(c), access, formIds);
          finish(() => resolve(r));
        } catch (e: any) {
          // Lost contact mid-session: keep listening so the user can just tap again.
          if (isLostContact(e)) { busy = false; return; }
          finish(() => reject(e instanceof CardError ? e : new CardError(String(e?.message || e), "card")));
        }
      });
      c.startNFC(prompt).catch((e) => finish(() => reject(new CardError(String(e), "nfc"))));
    } catch (e: any) { finish(() => reject(new CardError(String(e?.message || e), "nfc"))); }
  });
}
