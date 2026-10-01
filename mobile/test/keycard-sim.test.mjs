// The REAL Keycard applet (status-keycard, compiled from source at a release tag) running in
// jCardSim, driven by the REAL keycard-sdk through src/lib/keycard/card.ts. Only the NFC
// transport is replaced (CardServer: one APDU hex line in, one response line out).
// Run: KC_SIM="<cmd that starts the card server>" node --experimental-strip-types --test test/keycard-sim.test.mjs
// The card is provisioned like a factory card (identity certificate signed by a CA), with a
// TEST CA instead of Keycard's, so authenticity checking is real, not skipped.
import test from "node:test";
import assert from "node:assert";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { KeycardManager, LOADED } from "keycard-sdk/dist/keycard-manager.js";
import { APDUResponse } from "keycard-sdk/dist/apdu-response.js";
import { HDKey } from "@scure/bip32";
import { Certificate } from "keycard-sdk/dist/certificate.js";
import { BIP32KeyPair } from "keycard-sdk/dist/bip32key.js";
import { IdentCommandset } from "keycard-sdk/dist/ident-comandset.js";
import { secp256k1 } from "@noble/curves/secp256k1.js";
import { mnemonicToSeedSync } from "@scure/bip39";
import { exportFormKeys, CardError, isLostContact } from "../src/lib/keycard/card.ts";
import { CardIOError } from "keycard-sdk/dist/apdu-exception.js";
import * as C from "../../packages/contract/src/crypto-portable.mjs";
import { WhisperboxClient } from "../../packages/client/src/client.mjs";

const SIM = process.env.KC_SIM;
const MNEMONIC = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const PIN = "123456", PAIRING = "KeycardDefaultPairing";

// A CardChannel over the simulator process.
function simCard() {
  const [cmd, ...args] = SIM.split(" ");
  const p = spawn(cmd, args, { stdio: ["pipe", "pipe", "inherit"] });
  const rl = createInterface({ input: p.stdout });
  const waiting = [];
  rl.on("line", (l) => waiting.shift()?.(l.trim()));
  return {
    sent: [],
    isConnected: () => true,
    send(c) {
      const bytes = c.serialize();
      this.sent.push({ ins: bytes[1], p1: bytes[2], p2: bytes[3] });
      return new Promise((res) => { waiting.push((h) => res(new APDUResponse(C.fromHex(h)))); p.stdin.write(C.toHex(bytes) + "\n"); });
    },
    close: () => p.kill(),
  };
}
const memPairings = () => { const m = new Map(); return { getPairing: async (u) => m.get(String(u)) ?? null, putPairing: async (u, p) => { m.set(String(u), p); }, deletePairing: async (u) => { m.delete(String(u)); } }; };
// Test CA: the simulated card's identity certificate is signed by this, so pass its pub as the CA.
const TEST_CA_PRIV = C.fromHex("11".repeat(32));
const TEST_CA_PUB = secp256k1.getPublicKey(TEST_CA_PRIV, true);
const SIM_ACCESS = (pin = PIN) => ({ pin, pairingPassword: PAIRING, caPublicKeys: [TEST_CA_PUB] });
async function provisionCert(card) {
  const cert = Certificate.createCertificate(new BIP32KeyPair(TEST_CA_PRIV, null, null), Certificate.generateIdentKeyPair());
  const ic = new IdentCommandset(card);
  (await ic.select());
  (await ic.storeData(cert.toStoreData())).checkOK();
}

// Set the card up the way the Keycard app would: PIN/PUK/pairing + a known recovery phrase.
async function setUpCard(card, km) {
  const r = await km.runOnSecureChannel(card, LOADED, { newPin: PIN, newPuk: "123456789012", newPairingPassword: PAIRING, pairingPassword: PAIRING, mnemonic: MNEMONIC, caPublicKeys: [TEST_CA_PUB], skipVerificationUID: [] }, async () => "ok");
  assert.strictEqual(r.status, "success", JSON.stringify(r.data?.message || r));
}
const expectedKey = (path) => C.toHex(HDKey.fromMasterSeed(mnemonicToSeedSync(MNEMONIC)).derive(path).privateKey);

test("keycard: export form keys from the real applet", { skip: !SIM && "set KC_SIM" }, async (t) => {
  const card = simCard();
  t.after(() => card.close());
  await provisionCert(card);


  await t.test("a blank card is refused and NOT initialised", async () => {
    const km = new KeycardManager(memPairings());
    await assert.rejects(exportFormKeys(km, card, SIM_ACCESS(), ["form-a"]), (e) => e instanceof CardError && e.code === "blank");
    assert.ok(!card.sent.some((s) => s.ins === 0xfe), "no INIT command was sent");
  });

  const km = new KeycardManager(memPairings());
  await setUpCard(card, km);
  const ids = ["form-639a2554", "form-b0b", "Form-UPPER"];

  await t.test("a card certified by an unknown CA is not trusted (fresh phone, no pairing yet)", async () => {
    const wrongCa = secp256k1.getPublicKey(C.fromHex("22".repeat(32)), true);
    await assert.rejects(exportFormKeys(new KeycardManager(memPairings()), card, { ...SIM_ACCESS(), caPublicKeys: [wrongCa] }, [ids[0]]),
      (e) => e instanceof CardError && e.code === "authentic", "rejected as not genuine");
  });

  await t.test("one session exports every key = standard BIP32 from the phrase", async () => {
    const before = card.sent.length;
    const r = await exportFormKeys(km, card, SIM_ACCESS(), ids);
    assert.strictEqual(r.keys.length, 3);
    for (const k of r.keys) {
      assert.strictEqual(k.path, C.keycardFormKeyPath(k.formId));
      assert.strictEqual(k.privHex, expectedKey(k.path), "card key == BIP32(seed, path)");
      assert.strictEqual(k.pubHex, C.identityFromPriv(k.privHex).pubHex);
    }
    assert.strictEqual(new Set(r.keys.map((k) => k.pubHex)).size, 3, "distinct keys per form");
    // Applet 3.x secure channel leaves the header readable: check EXPORT KEY's P1/P2 directly.
    // 4.x wraps every command in a secured envelope (INS 0x?) - there the BIP32 match above is the check.
    const exports = card.sent.slice(before).filter((s) => s.ins === 0xc2);
    if (exports.length) {
      assert.strictEqual(exports.length, 3);
      for (const s of exports) assert.deepStrictEqual([s.p1, s.p2], [0x01, 0x00], "EXPORT KEY: derive from master, private");
    }
    const again = await exportFormKeys(km, card, SIM_ACCESS(), [ids[0]]);
    assert.strictEqual(again.keys[0].privHex, r.keys[0].privHex, "deterministic across sessions");
  });

  await t.test("card pulled away mid-session: retryable error, no re-pairing, next tap works", async (t) => {
    let puts = 0;
    const base = memPairings();
    const store = { ...base, putPairing: async (u, p) => { puts++; return base.putPairing(u, p); } };
    const kmF = new KeycardManager(store);
    await exportFormKeys(kmF, card, SIM_ACCESS(), [ids[0]]);            // first use (3.x: pairs once)
    const pairedOnce = puts;
    let total = 0;
    await exportFormKeys(kmF, { isConnected: () => true, send(c) { total++; return card.send(c); } }, SIM_ACCESS(), ids);
    for (let cut = 1; cut <= total; cut++) {                             // card leaves at EVERY APDU of a session
      let n = 0;
      const yanked = { isConnected: () => n < cut, send(c) { if (++n >= cut) return Promise.reject(new CardIOError("Tag was lost")); return card.send(c); } };
      await assert.rejects(exportFormKeys(kmF, yanked, SIM_ACCESS(), ids), (e) => isLostContact(e), `cut at APDU ${cut}`);
      const r = await exportFormKeys(kmF, card, SIM_ACCESS(), ids);      // tap again
      assert.strictEqual(r.keys[0].privHex, expectedKey(C.keycardFormKeyPath(ids[0])));
    }
    assert.strictEqual(puts, pairedOnce, "a lost tap never re-pairs (3.x cards have only 5 pairing slots)");
    t.diagnostic(`session = ${total} APDUs, yanked at each one`);
  });

  await t.test("wrong PIN: readable error with tries left; key not exported", async () => {
    await assert.rejects(exportFormKeys(km, card, SIM_ACCESS("000000"), ["form-x"]), (e) => e.code === "pin" && /2 tries left/.test(e.message));
    await exportFormKeys(km, card, SIM_ACCESS(), ["form-x"]); // correct PIN resets the counter
  });

  await t.test("the card refuses keys outside EIP-1581 (sanity: our path is the exportable one)", async () => {
    await km.runOnSecureChannel(card, LOADED, { pin: PIN, pairingPassword: PAIRING, caPublicKeys: [TEST_CA_PUB], skipVerificationUID: [] }, async (cs) => {
      const bad = await cs.exportKey(0, false, "m/44'/60'/0'/0/0", false);
      assert.notStrictEqual(bad.sw, 0x9000, "wallet key is not exportable");
      const short = await cs.exportKey(0, false, "m/43'/60'/1581'", false);
      assert.notStrictEqual(short.sw, 0x9000, "the 1581' root itself is not exportable");
      return null;
    });
  });

  await t.test("end to end: Keycard-keyed form, answer, decrypt, reinstall, restore by tap", async () => {
    const mem = () => { const m = new Map(); return { get: async (k) => m.get(k) ?? null, set: async (k, v) => { m.set(k, v); } }; };
    const wire = [];
    const creatorStore = mem(), creatorSecrets = mem();
    const a = new WhisperboxClient({ store: creatorStore, secrets: creatorSecrets, send: async (b) => { wire.push(b); } });
    const b = new WhisperboxClient({ store: mem(), send: async (x) => { wire.push(x); } });
    await a.init(); await b.init(); a.onConnected(); b.onConnected();
    const pump = () => { while (wire.length) { const m = wire.shift(); a.ingest([m]); b.ingest([m]); } };

    const fid = a.newFormId();
    const [k] = (await exportFormKeys(km, card, SIM_ACCESS(), [fid])).keys;
    assert.ok((await a.addFormKey(fid, k.privHex)).ok);
    assert.ok(a.createForm({ id: fid, title: "Card form", questions: [{ id: "q1", type: "text", text: "?", required: true }] }, { publicKey: k.pubHex }).ok);
    pump();
    assert.strictEqual(b.snapshot().state.forms[fid].publicKey, k.pubHex, "respondents seal to the CARD key");
    assert.notStrictEqual(k.pubHex, C.deriveFormKey(a.identity, fid).pubHex, "not the soft-derived key");
    assert.ok(b.submitResponse(fid, [{ questionId: "q1", value: "sealed to a card" }]).ok); pump();
    assert.strictEqual(a.snapshot().creatorView.responses[fid][0].answers[0].value, "sealed to a card");
    assert.ok(!a.createForm({ id: "form-nokey", title: "x" }, { publicKey: k.pubHex }).ok, "refuses to publish with a key it doesn't hold");

    // Reinstall: same identity + log, form keys gone (SecureStore wiped).
    const fresh = mem(); await fresh.set("wb-identity", await creatorSecrets.get("wb-identity"));
    const a2 = new WhisperboxClient({ store: creatorStore, secrets: fresh, send: async () => {} });
    await a2.init();
    let s = a2.snapshot();
    assert.ok(s.state.forms[fid].keyMissing, "flags the form whose key is missing");
    assert.strictEqual((s.creatorView.responses[fid] || []).length, 0);
    const restored = await exportFormKeys(km, card, SIM_ACCESS(), a2.formsMissingKeys());
    for (const rk of restored.keys) assert.ok((await a2.addFormKey(rk.formId, rk.privHex)).ok);
    s = a2.snapshot();
    assert.ok(!s.state.forms[fid].keyMissing);
    assert.strictEqual(s.creatorView.responses[fid][0].answers[0].value, "sealed to a card", "answers open again after one tap");
    assert.ok(!(await a2.addFormKey(fid, C.generateIdentity().priv.reduce((h, x) => h + x.toString(16).padStart(2, "0"), ""))).ok, "a key from a different card is rejected");
  });
});
