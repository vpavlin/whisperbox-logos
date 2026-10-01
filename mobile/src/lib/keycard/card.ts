// WhisperBox x Keycard - the card logic, independent of NFC. Exports per-form keys from the
// card's EIP-1581 subtree (the only keys a Keycard lets out; ADR 0001). Runs against any
// keycard-sdk CardChannel: the NFC channel on the phone (nfc.ts), or the real applet in a
// simulator in tests (test/keycard-sim.test.mjs).
//
// Derived from scala's loam-keycard (keycard.ts), with these differences, all verified
// against the applet source + simulator (applets 3.1.2 and 4.0):
//  - keycard-sdk 4.0.1 (scala pins 3.1.9, which cannot even parse a 4.0 card's SELECT answer).
//    4.x cards have no pairing (certificate-based secure channel); 3.x cards still pair.
//  - EXPORT KEY instead of SIGN. Applets 3.1 and 4.x return ONLY the private key (tag 0x81)
//    for a private export, no public key, so the pub is computed here and never read from
//    the card.
//  - A blank card is REFUSED up front. keycard-sdk's runOnSecureChannel initialises any
//    uninitialised card it meets with the PIN it was given and a random PUK nobody sees.
//  - A card without a key is refused too (we never pass a mnemonic, so nothing is loaded).
//  - Errors come back as readable messages (wrong PIN + tries left, not authentic, ...).
import { KeycardManager, LOADED } from "keycard-sdk/dist/keycard-manager.js";
import { Commandset } from "keycard-sdk/dist/commandset.js";
import { ApplicationInfo } from "keycard-sdk/dist/application-info.js";
import { BIP32KeyPair } from "keycard-sdk/dist/bip32key.js";
import { CardIOError } from "keycard-sdk/dist/apdu-exception.js";
import { keycardFormKeyPath, identityFromPriv, toHex } from "../../../../packages/contract/src/crypto-portable.mjs";

// The Keycard CA public key (card-authenticity cert). Same value as scala / the choppu example /
// keycard-cli use to check that a card is genuine.
export const KEYCARD_CA = new Uint8Array([
  0x02, 0x9a, 0xb9, 0x9e, 0xe1, 0xe7, 0xa7, 0x1b, 0xdf, 0x45, 0xb3, 0xf9, 0xc5, 0x8c, 0x99, 0x86,
  0x6f, 0xf1, 0x29, 0x4d, 0x2c, 0x1e, 0x30, 0x4e, 0x22, 0x8a, 0x86, 0xe1, 0x0c, 0x33, 0x43, 0x50, 0x1c,
]);
export const DEFAULT_PAIRING = "KeycardDefaultPairing";

export interface CardAccess {
  pin: string;
  pairingPassword?: string;
  /** Override the CA keys (tests only: a simulated card carries a test-CA certificate). */
  caPublicKeys?: Uint8Array[];
}
export interface FormKey { formId: string; path: string; privHex: string; pubHex: string }
export interface ExportResult { keys: FormKey[]; instanceUID: string; appVersion: string }

const hex = (b: any): string => (b ? toHex(b instanceof Uint8Array ? b : Uint8Array.from(Object.values(b) as number[])) : "");

export class CardError extends Error {
  code: string;
  constructor(message: string, code: string) { super(message); this.name = "CardError"; this.code = code; }
}

/** Parse an EXPORT KEY response (A1 { 80 pub? } { 81 priv } { 82 chain? }) into a validated key. */
export function parseExportedPriv(tlv: Uint8Array): Uint8Array {
  let priv: any;
  try { priv = BIP32KeyPair.fromTLV(tlv).privateKey; } catch { throw new CardError("Unexpected answer from the card", "parse"); }
  if (!priv) throw new CardError("The card did not hand out the key (is this path exportable?)", "no-priv");
  let p = priv instanceof Uint8Array ? priv : Uint8Array.from(Object.values(priv) as number[]);
  if (p.length === 33 && p[0] === 0) p = p.subarray(1);
  if (p.length < 32) { const o = new Uint8Array(32); o.set(p, 32 - p.length); p = o; }
  if (p.length !== 32 || !identityFromPriv(p)) throw new CardError("The card returned an invalid key", "bad-key");
  return p;
}

/**
 * One secure-channel session: verify PIN, export the key of every form in `formIds`.
 * Never initialises, never loads a key, never changes anything on the card.
 */
export async function exportFormKeys(kManager: KeycardManager, channel: any, access: CardAccess, formIds: string[]): Promise<ExportResult> {
  // Refuse a blank card BEFORE runOnSecureChannel, which would initialise it.
  // (keycard-sdk 4 also verifies a 4.x card's certificate right here, in SELECT)
  let info: ApplicationInfo;
  try { info = new ApplicationInfo((await new Commandset(channel, access.caPublicKeys ?? [KEYCARD_CA]).select()).checkOK().data); }
  catch (e: any) { throw toCardError(e); }
  if (!info.initializedCard) throw new CardError("This Keycard is not set up yet. Set it up (PIN + recovery phrase) in the Keycard app first.", "blank");
  const instanceUID = hex(info.instanceUID);

  let res: any;
  try {
    res = await kManager.runOnSecureChannel(channel, LOADED, {
      pin: access.pin,
      pairingPassword: access.pairingPassword || DEFAULT_PAIRING,
      caPublicKeys: access.caPublicKeys ?? [KEYCARD_CA],
      skipVerificationUID: [],
    } as any, async (cmdSet: Commandset) => {
      const out: { formId: string; path: string; tlv: Uint8Array }[] = [];
      for (const formId of formIds) {
        const path = keycardFormKeyPath(formId);
        const r: any = await cmdSet.exportKey(0, false, path, false);
        if (r.sw !== 0x9000) throw new CardError(`The card refused to export ${path} (SW ${r.sw.toString(16)})`, "refused");
        out.push({ formId, path, tlv: r.data });
      }
      return out;
    });
  } catch (e: any) {
    throw toCardError(e);
  }
  if (!res || res.status !== "success") throw toCardError({ cardData: res?.data, message: res?.data?.message });
  const raw: any[] = res.data.cbFuncResponse || [];
  const keys: FormKey[] = raw.map((x: any) => {
    const tlv = x.tlv instanceof Uint8Array ? x.tlv : Uint8Array.from(Object.values(x.tlv || {}) as number[]);
    const id = identityFromPriv(parseExportedPriv(tlv))!;
    return { formId: x.formId, path: x.path, privHex: toHex(id.priv), pubHex: id.pubHex };
  });
  if (keys.length !== formIds.length) throw new CardError("The card did not export every key", "partial");
  return { keys, instanceUID, appVersion: String(info.appVersion ?? "") };
}

/** The card left the field mid-session (retryable by tapping again), as opposed to a refusal. */
export function isLostContact(e: any): boolean {
  return e instanceof CardError && e.code === "contact";
}

function toCardError(e: any): CardError {
  if (e instanceof CardError) return e;
  if (e instanceof CardIOError || /CardIO ?Error|Lost contact|moved away|Tag (was lost|disconnected)/i.test(String(e?.message || e)))
    return new CardError("Lost contact with the card - hold it still against the phone and tap again", "contact");
  const d = e?.cardData || {};
  const msg = String(e?.message || e || "");
  // keycard-sdk error codes (keycard-manager.js)
  switch (d.type ?? e?.errorCode) {
    case 0xca91: return new CardError(typeof d.pinRetry === "number" ? `Wrong PIN - ${d.pinRetry} ${d.pinRetry === 1 ? "try" : "tries"} left before the card locks` : "Wrong PIN", "pin");
    case 0xcaa4: return new CardError("This card could not be verified as a genuine Keycard", "authentic");
    case 0xca61: return new CardError("Could not pair with the card - wrong pairing password, or all pairing slots are used", "pairing");
    case 0xca13: return new CardError("This Keycard has no key on it yet. Load or create one in the Keycard app first.", "no-key");
  }
  if (/certificate verification failed|not authentic|unknown CA/i.test(msg)) return new CardError("This card could not be verified as a genuine Keycard", "authentic");
  const inner = /CardError: (.*)$/.exec(msg);
  return new CardError(inner ? inner[1] : msg || "Keycard error", "card");
}
