// The one Keycard request the app makes: "get me the keys of these forms". Shows the PIN sheet
// (App.tsx <KeycardSheet>), runs one NFC tap, returns the keys. The PIN lives only in the
// sheet's state for the duration of the request - never stored.
import * as SecureStore from "expo-secure-store";
import { DEFAULT_PAIRING, type FormKey } from "./card";

export type CardRequest = {
  formIds: string[];
  title: string;
  resolve: (keys: FormKey[]) => void;
  reject: (e: Error) => void;
};
let show: ((r: CardRequest | null) => void) | null = null;
export function registerSheet(fn: ((r: CardRequest | null) => void) | null) { show = fn; }

export function requestCardKeys(formIds: string[], title: string): Promise<FormKey[]> {
  return new Promise((resolve, reject) => {
    if (!show) { reject(new Error("Keycard sheet not mounted")); return; }
    show({ formIds, title, resolve, reject });
  });
}

// Settings: seal new forms with the Keycard by default; the card's pairing password (3.x cards).
export async function getKeycardPrefs(): Promise<{ useForNewForms: boolean; pairing: string }> {
  let use = false, pairing = DEFAULT_PAIRING;
  try { use = (await SecureStore.getItemAsync("wb-kc-new-forms")) === "1"; } catch { /* */ }
  try { pairing = (await SecureStore.getItemAsync("wb-kc-pairing")) || DEFAULT_PAIRING; } catch { /* */ }
  return { useForNewForms: use, pairing };
}
export async function setKeycardPrefs(p: { useForNewForms?: boolean; pairing?: string }) {
  if (p.useForNewForms !== undefined) await SecureStore.setItemAsync("wb-kc-new-forms", p.useForNewForms ? "1" : "0");
  if (p.pairing !== undefined) await SecureStore.setItemAsync("wb-kc-pairing", p.pairing || DEFAULT_PAIRING, { keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY });
}
