// WhisperboxCoreImpl implementation. Engine/crypto/wire are the std-only headers
// (whisperbox_engine.hpp etc., byte-parity with the TS reference). This file wires
// the mutation API + the delivery_module transport (SDS Reliable Channels) over ONE
// shared topic, routing incoming envelopes into the single merged log.
//
// Every delivery call is async / fire-and-forget (a synchronous send on the
// event-loop thread freezes the module on the IPC timeout).
#include "whisperbox_core_impl.h"
#include "logos_sdk.h"   // umbrella: LogosModules + LogosMap(nlohmann::json) + StdLogosResult
#include "qrcodegen.hpp"  // vendored Nayuki QR encoder (host qr core unreachable from a pure-QML view)
#include <QTimer>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cctype>
#include <fstream>
#include <algorithm>
#include <typeinfo>

using whisperbox::json;
using whisperbox::OrderedJson;
using whisperbox::lc;
using whisperbox::TOPIC;
using whisperbox::FORM_PUBLISH;
using whisperbox::RESPONSE_SUBMIT;
using whisperbox::RESPONSE_CONFIRM;
using whisperbox::FORM_CLOSE;

static long long nowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
}
static std::string trim(const std::string& s) {
    size_t a = s.find_first_not_of(" \t\r\n"); if (a == std::string::npos) return "";
    size_t b = s.find_last_not_of(" \t\r\n"); return s.substr(a, b - a + 1);
}
// The delivery send() payload must be a JSON byte ARRAY under the current cpp-sdk
// (a JSON string throws in the marshaling); this produces the same wire bytes.
static LogosMap bytesPayload(const std::string& s) {
    LogosMap a = LogosMap::array(); for (unsigned char c : s) a.push_back((unsigned)c); return a;
}
static bool isHex(const std::string& s, size_t len) {
    if (s.size() != len) return false;
    for (char c : s) if (!std::isxdigit((unsigned char)c)) return false;
    return true;
}

WhisperboxCoreImpl::~WhisperboxCoreImpl() {
    // Parentless QTimer (LogosModuleContext is NOT a QObject in this builder rev)
    // — stop + delete explicitly.
    if (m_hubTimer) { m_hubTimer->stop(); delete m_hubTimer; m_hubTimer = nullptr; }
}

// ── lifecycle ────────────────────────────────────────────────────────────────────
void WhisperboxCoreImpl::onContextReady() {
    fprintf(stderr, "WHISPERBOX onContextReady enter\n");
    try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    setupDataDir();
    fprintf(stderr, "WHISPERBOX dataDir=%s\n", m_dataDir.c_str());
    loadIdentity();
    fprintf(stderr, "WHISPERBOX identity valid=%d addr=%s\n", (int)m_signId.valid, m_signId.address.c_str());
    m_clock = whisperbox::Clock(m_deviceId);
    loadLog();
    fprintf(stderr, "WHISPERBOX log events=%zu\n", m_log.size());
    m_clock.primeFrom(m_log);
    loadWatched();
    bootstrapDelivery();
    fprintf(stderr, "WHISPERBOX delivery bootstrapped nodeReady=%d\n", (int)m_nodeReady);
    // Hub tick: retry node start until ready, then a rate-limited periodic seed so
    // late joiners on a sparse mesh still converge (idempotent — peers dedup by id).
    m_hubTimer = new QTimer();
    QObject::connect(m_hubTimer, &QTimer::timeout, [this] {
        std::lock_guard<std::recursive_mutex> lk(m_mtx);
        if (!m_nodeReady) bootstrapDelivery();
        else {
            if (nowMs() - m_lastSeedMs >= 60000 && !m_log.empty()) seedBroadcast();
            // Catchup retries while the log is still empty: 3s, 10s, 25s after the
            // node-up request, then every 60s (self-heals late joiners on a sparse mesh).
            if (m_log.empty() && m_nodeReady) {
                static const long long kBackoffMs[] = {3000, 10000, 25000};
                long long delay = m_syncReqTries <= 3 ? kBackoffMs[m_syncReqTries - 1] : 60000;
                if (nowMs() - m_lastSyncReqMs >= delay) requestSync();
            }
            // Distributed-debugging: counters on stderr every 30s ("watch counters").
            if (nowMs() - m_lastStatMs >= 30000) {
                m_lastStatMs = nowMs();
                fprintf(stderr, "WHISPERBOX stat node=%d log=%zu rxRaw=%ld rxSeen=%ld rxNew=%ld rxDup=%ld tx=%ld\n",
                        (int)m_nodeReady, m_log.size(), m_rxRaw, m_rxSeen, m_rxNew, m_rxDup, m_txTotal);
            }
        }
    });
    m_hubTimer->start(1000);
    publishState();
    fprintf(stderr, "WHISPERBOX onContextReady done\n");
    } catch (const std::exception& e) {
        fprintf(stderr, "WHISPERBOX onContextReady EXCEPTION: %s\n", e.what());
    } catch (...) {
        fprintf(stderr, "WHISPERBOX onContextReady UNKNOWN EXCEPTION\n");
    }
}

// ── data dir + persistence (~/.whisperbox-core, $WHISPERBOX_CORE_DATA override) ──
void WhisperboxCoreImpl::setupDataDir() {
    if (const char* ov = std::getenv("WHISPERBOX_CORE_DATA")) { m_dataDir = ov; }
    else {
        const char* home = std::getenv("HOME");
        m_dataDir = std::string(home ? home : ".") + "/.whisperbox-core";
    }
    system(("mkdir -p '" + m_dataDir + "' 2>/dev/null").c_str());
}
std::string WhisperboxCoreImpl::randomHex(int bytes) {
    // CSPRNG — never rand(): an unseeded rand() is deterministic per process,
    // which minted byte-identical "fresh" identities in two separate runs.
    whisperbox::Bytes b(bytes);
    for (int tries = 0; tries < 10 && bytes > 0 && RAND_bytes(b.data(), bytes) != 1; ++tries) {}
    return whisperbox::toHex(b);
}
void WhisperboxCoreImpl::loadIdentity() {
    std::ifstream f(m_dataDir + "/identity.json");
    if (f) {
        try {
            json o = json::parse(std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>()));
            m_signId = whisperbox::identityFromPriv(whisperbox::fromHex(o.value("privHex", "")));
            if (m_signId.valid) return;
        } catch (...) { /* fall through to generate */ }
    }
    // First run: generate a keypair.
    std::string priv = randomHex(32);
    m_signId = whisperbox::identityFromPriv(whisperbox::fromHex(priv));
    if (!m_signId.valid) { fprintf(stderr, "WHISPERBOX identity generation failed\n"); return; }
    saveIdentity();
    fprintf(stderr, "WHISPERBOX new identity %s\n", m_signId.address.c_str());
}
void WhisperboxCoreImpl::saveIdentity() {
    json o = {{"privHex", whisperbox::toHex(m_signId.priv)}, {"pubHex", m_signId.pubHex}, {"address", m_signId.address}};
    std::ofstream f(m_dataDir + "/identity.json", std::ios::trunc); if (f) f << o.dump();
}
void WhisperboxCoreImpl::loadLog() {
    std::ifstream f(m_dataDir + "/events.json");
    if (!f) return;
    try {
        json a = json::parse(std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>()));
        if (a.is_array()) for (auto& e : a) if (e.is_object() && e.contains("id")) m_log.push_back(e);
    } catch (...) { fprintf(stderr, "WHISPERBOX events.json corrupt — starting empty\n"); }
}
void WhisperboxCoreImpl::saveLog() {
    std::ofstream f(m_dataDir + "/events.json", std::ios::trunc); if (f) f << json(m_log).dump();
}
void WhisperboxCoreImpl::loadWatched() {
    m_watched.clear();
    std::ifstream f(m_dataDir + "/watched.json"); if (!f) return;
    try {
        json a = json::parse(std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>()));
        if (a.is_array()) for (auto& x : a) if (x.is_string()) m_watched.insert(lc(x.get<std::string>()));
    } catch (...) { /* ignore */ }
}
void WhisperboxCoreImpl::saveWatched() {
    json a = json::array(); for (auto& id : m_watched) a.push_back(id);
    std::ofstream f(m_dataDir + "/watched.json", std::ios::trunc); if (f) f << a.dump();
}

// ── delivery bootstrap (mirrors qaku: logos.test fleet pinned, async only) ───────
void WhisperboxCoreImpl::bootstrapDelivery() {
    if (m_nodeReady || m_deliveryStarting) return;
    if (!m_signId.valid) { setStatus("No identity"); return; }
    m_deliveryStarting = true;
    // Register BOTH receive paths BEFORE createNode (qaku lesson): the channel path
    // is authoritative (unwrapped payload); the raw relay path fires too with SDS
    // wire frames — ingest best-effort, silent on failure.
    auto toWire = [](const LogosMap& v) -> std::string {
        if (v.is_string()) return v.get<std::string>();
        if (v.is_array()) { std::string s; s.reserve(v.size()); for (const auto& c : v) if (c.is_number_integer()) s.push_back((char)c.get<int>()); return s; }
        if (v.is_object() && v.contains("_bytes") && v["_bytes"].is_string()) return v["_bytes"].get<std::string>();
        return std::string();
    };
    bool subMsg = modules().delivery_module.onMessageReceived(
        [this, toWire](const std::string&, const std::string& contentTopic, const LogosMap& payload, int64_t) {
            fprintf(stderr, "WHISPERBOX onMessageReceived topic=%s size=%zu\n", contentTopic.c_str(), payload.size());
            if (contentTopic != TOPIC) return;
            std::string p = toWire(payload);
            if (p.empty() && payload.is_object() && payload.contains("payload")) p = toWire(payload["payload"]);
            if (!p.empty()) ingestEnvelopeText(p, /*channelPath=*/false);
        });
    bool subCh = modules().delivery_module.onChannelMessageReceived(
        [this, toWire](const std::string& channelId, const std::string&, const LogosMap& payload, int64_t) {
            fprintf(stderr, "WHISPERBOX onChannelMessageReceived channel=%s size=%zu\n", channelId.c_str(), payload.size());
            if (channelId != TOPIC) return;
            std::string p = toWire(payload);
            if (p.empty() && payload.is_object() && payload.contains("payload")) p = toWire(payload["payload"]);
            if (!p.empty()) ingestEnvelopeText(p, /*channelPath=*/true);
        });
    fprintf(stderr, "WHISPERBOX event subs msg=%d ch=%d\n", (int)subMsg, (int)subCh);
    setStatus("Connecting...");
    // RELAY node with the logos.test fleet entry nodes PINNED (qaku lesson: bare
    // {mode:Core,preset} gives ZERO bootstrap nodes — "Connected" but meshes with
    // nothing). Keep in lockstep with qaku's mobile ENTRY_NODES.
    LogosMap cfg = {
        {"logLevel", "INFO"}, {"mode", "Core"}, {"preset", "logos.test"}, {"relay", true},
        {"entryNodes", LogosMap::array({
            "/dns4/node-01.do-ams3.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmQ9X2xDfPG3uL77V9piYDhjq14JhKCtcmNYsTMKNqrKCj",
            "/dns4/node-02.do-ams3.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmB8NYprrfQrgWVzsJtYWkfjsXbmJEGNMG6othXsQ53BwG",
            "/dns4/node-01.gc-us-central1-a.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmF8WtwGPmeGHgYAX2277jHgy5cW9F7zsB8EqUjBZQAZQ3",
            "/dns4/node-02.gc-us-central1-a.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmUuXhUW9bdJpzN1kfDziFiUZo4bszTk66cvr7uuyCHXR7",
            "/dns4/node-01.ac-cn-hongkong-c.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmL3oU95jh1BZHozn3uNhx8HEneirgr8M1jEAapzXGDqRF",
            "/dns4/node-02.ac-cn-hongkong-c.logos.test.status.im/tcp/30303/p2p/16Uiu2HAm28CoBZjpyxsanC8tQpbvZ7bZJnVYuB1EgFzb571qpWsV",
        })},
    };
    if (const char* ov = std::getenv("WHISPERBOX_DELIVERY_CFG")) {
        auto j = json::parse(ov, nullptr, false);
        if (j.is_object()) for (auto it = j.begin(); it != j.end(); ++it) cfg[it.key()] = it.value();
    }
    std::string cfgStr = cfg.dump();
    fprintf(stderr, "WHISPERBOX bootstrapDelivery cfg=%s\n", cfgStr.c_str());
    auto startNode = [this, cfgStr]() {
        modules().delivery_module.createNodeAsync(cfgStr, [this](StdLogosResult r) {
            if (!r.success) { m_deliveryStarting = false; setStatus("Delivery error (createNode): " + r.error); return; }
            modules().delivery_module.startAsync([this](StdLogosResult r2) {
                if (!r2.success) { m_deliveryStarting = false; setStatus("Delivery error (start): " + r2.error); return; }
                std::lock_guard<std::recursive_mutex> lk(m_mtx);
                m_nodeReady = true;
                joinTransport();
                seedBroadcast();   // serve our log if we have one
                requestSync();     // AND pull: cold start with empty log needs history
                setStatus("Connected");
                publishState();
            });
        });
    };
    startNode();
}

void WhisperboxCoreImpl::joinTransport() {
    if (!m_nodeReady || m_subscribed) return;
    // SDS Reliable Channels: subscribe THEN channelCreate (channelCreate does not
    // itself subscribe the content topic). channelId == contentTopic == TOPIC.
    modules().delivery_module.subscribeAsync(TOPIC, [](StdLogosResult){});
    modules().delivery_module.channelCreateAsync(TOPIC, TOPIC, m_deviceId, [](StdLogosResult){});
    m_subscribed = true;
}

void WhisperboxCoreImpl::seedBroadcast() {
    if (!m_nodeReady || m_log.empty()) return;
    for (const auto& e : m_log) broadcastEvent(e);
    m_lastSeedMs = nowMs();
}

// Ask peers for the full log (cold-start catchup). Peers answer with a full-log
// seedBroadcast (rate-limited 3s on their side); idempotent — everyone dedups by id.
void WhisperboxCoreImpl::requestSync() {
    if (!m_nodeReady) return;
    std::string text = whisperbox::eventToJsonText(whisperbox::envSyncReq(m_deviceId));
    deliverySend(TOPIC, whisperbox::b64encode(text));
    m_lastSyncReqMs = nowMs();
    m_syncReqTries++;
    fprintf(stderr, "WHISPERBOX requestSync try=%d\n", m_syncReqTries);
}

bool WhisperboxCoreImpl::deliverySend(const std::string& topic, const std::string& b64Text) {
    if (!m_nodeReady) return false;
    // SINGLE-base64 (qaku's proven shape): hand the transport the base64 TEXT as
    // bytes; delivery_module base64-encodes once more on the wire. Robust to either
    // IPC shape: JSON byte ARRAY (repr 1) or string (repr 2); probe once, cache.
    auto attempt = [&](int repr) -> bool {
        try {
            LogosMap p = (repr == 1) ? bytesPayload(b64Text) : LogosMap(b64Text);
            modules().delivery_module.channelSendAsync(topic, p, [](StdLogosResult){});
            return true;
        } catch (...) { return false; }
    };
    if (m_sendRepr == 1 || m_sendRepr == 2) { if (attempt(m_sendRepr)) return true; m_sendRepr = 0; }
    if (attempt(1)) { m_sendRepr = 1; return true; }
    if (attempt(2)) { m_sendRepr = 2; return true; }
    fprintf(stderr, "WHISPERBXTX deliverySend: no working payload representation\n");
    return false;
}

// ── event lifecycle ──────────────────────────────────────────────────────────────
json WhisperboxCoreImpl::buildEvent(const std::string& type, const std::string& id, const json& payload, bool sign) {
    json e = json::object();
    e["v"] = 1;
    e["id"] = id;
    e["type"] = type;
    e["hlc"] = m_clock.send(nowMs());
    e["dev"] = m_deviceId;
    e["payload"] = payload;
    if (sign) {
        // signEvent adds pub/sig (whisperbox_identity.hpp); canonical message binds
        // type+HLC+dev+id+cjson(payload). Never throws for a valid identity.
        whisperbox::signEventJson(e, m_signId);
    }
    return e;
}

void WhisperboxCoreImpl::adoptLocal(json e) {
    if (whisperbox::mergeOne(m_log, e)) {
        m_clock.receive(e.value("hlc", json::object()));
        saveLog();
    }
}

void WhisperboxCoreImpl::broadcastEvent(const json& e) {
    // Guarded: calling delivery methods BEFORE the node is up fails with
    // "no provider registered" and can wedge the FFI result plumbing so the
    // createNode/start callbacks never fire (observed live — node up, module stuck).
    // The event stays in the local log; reseed/SYNC_REQ delivers it later.
    if (!m_nodeReady) return;
    std::string text = whisperbox::eventToJsonText(whisperbox::envEvent(e));
    const std::string b64 = whisperbox::b64encode(text);
    // PRIMARY: relay publish — reaches every subscriber of the topic via the relay
    // infrastructure; needs NO direct peer discovery (the original whisperbox Waku
    // model). Channel send alone only works once peers have discovered each other.
    try {
        std::vector<uint8_t> raw(b64.begin(), b64.end());
        modules().delivery_module.sendAsync(TOPIC, raw, [](StdLogosResult){});
    } catch (...) { /* relay path best-effort; channel path + reseed still converge */ }
    // SECONDARY: SDS channel send — fast path when a direct connection exists.
    if (deliverySend(TOPIC, b64)) m_txTotal++;
}

// ── ingest (receive path) ────────────────────────────────────────────────────────
void WhisperboxCoreImpl::ingestEnvelopeText(const std::string& text, bool channelPath) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    m_rxRaw++;
    if (channelPath) m_rxSeen++;
    // The wire payload is base64 text; a peer may single- OR double-encode. Try the
    // double-peel first, then a single peel (qaku convention).
    auto tryText = [this](const std::string& t) -> bool {
        json env = whisperbox::parseEnvelope(t);
        if (!env.is_object()) return false;
        const std::string type = env["type"].get<std::string>();
        if (type == "SYNC_REQ") {
            if (env.value("from", "") != m_deviceId && nowMs() - m_lastSyncReserveMs >= 3000) {
                m_lastSyncReserveMs = nowMs();
                seedBroadcast();   // re-serve the whole log (idempotent — peers dedup)
            }
            return true;
        }
        if (type == "EVENT" && env.contains("event")) {
            json e = env["event"];
            if (!admitEvent(e)) return true;   // dropped by admission (counted), not a decode failure
            bool isNew = whisperbox::mergeOne(m_log, e);
            if (isNew) {
                m_rxNew++;
                m_clock.receive(e.value("hlc", json::object()));
                saveLog();
                publishState();
            } else m_rxDup++;
            return true;
        }
        return false;
    };
    std::string once = whisperbox::b64decode(text);
    if (tryText(whisperbox::b64decode(once))) return;   // double peel
    if (tryText(once)) return;                           // single peel
    if (channelPath) fprintf(stderr, "WHISPERBOXRX ingest OPENFAIL plen=%zu\n", text.size());
}

// Admission gates at merge (PLAN 3.4): drop violators, counted, not fatal.
bool WhisperboxCoreImpl::admitEvent(const json& e) {
    const std::string type = e.value("type", "");
    if (type == FORM_PUBLISH) {
        // Creator-gated by signature: must verify AND the recovered address must be
        // payload.creator (verifyEvent does both). Unsigned publishes are dropped —
        // forms are public, but authorship is not optional.
        if (!whisperbox::verifyEventJson(e)) { m_admDropSig++; return false; }
        return true;
    }
    if (type == RESPONSE_CONFIRM || type == FORM_CLOSE) {
        if (!whisperbox::verifyEventJson(e)) { m_admDropSig++; return false; }
        return true;   // not-creator is also dropped at fold time (engine, counted there)
    }
    if (type == RESPONSE_SUBMIT) {
        // OPAQUE: an event-level pub/sig here would leak the respondent's identity —
        // reject such events outright (privacy invariant).
        if (e.contains("pub") && !e["pub"].is_null() && !e["pub"].get<std::string>().empty()) { m_admDropSig++; return false; }
        if (!e.contains("payload") || !e["payload"].contains("encryptedPayload")) { m_admDropType++; return false; }
        return true;
    }
    m_admDropType++;
    return false;
}

// ── snapshot / state ─────────────────────────────────────────────────────────────
std::string WhisperboxCoreImpl::setStatus(std::string s) {
    m_status = s;
    emit statusChanged(s);
    return s;
}

OrderedJson WhisperboxCoreImpl::buildSnapshot() {
    const std::string me = m_signId.valid ? m_signId.address : "";
    // Engine fold (log level): verify hook for signed gated events.
    auto verify = [](const json& e) { return whisperbox::verifyEventJson(e); };
    OrderedJson state = whisperbox::computeState(m_log, me, verify);

    // Creator view: decrypt the response pool with our key.
    json creatorViewJson;
    if (state["creator"] != nullptr && m_signId.valid) {
        auto open = [this](const std::string& hexBlob) -> json {
            try {
                whisperbox::Bytes blob = whisperbox::fromHex(hexBlob);
                whisperbox::Bytes pt = whisperbox::eciesOpen(m_signId.priv, blob);
                return json::parse(std::string(pt.begin(), pt.end()));
            } catch (...) { return json(); }
        };
        auto verifyResponse = [](const json& pseudo) -> bool {
            // Inner signature over the DECRYPTED content (whitelist != none):
            // canonical "whisperbox-inner-v1|formId|respondent|submittedAt|cjson(answers)",
            // ECDSA low-S, and address(pub) must equal respondent.
            const json p = pseudo.value("payload", json::object());
            std::string pubHex = p.value("pub", "");
            std::string sigHex = p.value("signature", "");
            if (pubHex.empty() || sigHex.empty()) return false;
            long long submittedAt = p.value("submittedAt", 0LL);
            OrderedJson m = OrderedJson::object();
            m["formId"] = lc(p.value("formId", ""));
            m["respondent"] = lc(p.value("respondent", ""));
            m["submittedAt"] = submittedAt;
            m["answers"] = p.value("answers", json::array());
            std::string msg = "whisperbox-inner-v1|" + m.dump();
            whisperbox::Bytes digest = whisperbox::sha256(whisperbox::Bytes(msg.begin(), msg.end()));
            if (!whisperbox::ecdsaVerify(whisperbox::fromHex(pubHex), digest, whisperbox::fromHex(sigHex))) return false;
            whisperbox::Bytes h = whisperbox::sha256(whisperbox::fromHex(pubHex));
            return ("0x" + whisperbox::toHex(h.data(), 32).substr(24, 40)) == lc(p.value("respondent", ""));
        };
        creatorViewJson = whisperbox::creatorView(state, me, open, verifyResponse);
    }

    OrderedJson snap = OrderedJson::object();
    snap["v"] = 1;
    snap["identity"] = m_signId.valid
        ? json({{"address", m_signId.address}, {"pubHex", m_signId.pubHex}}) : nullptr;
    snap["deviceId"] = m_deviceId;
    snap["nodeReady"] = m_nodeReady;
    snap["state"] = state;
    snap["creatorView"] = creatorViewJson.is_null() ? nullptr : creatorViewJson;
    json watchedArr = json::array(); for (auto& id : m_watched) watchedArr.push_back(id);
    snap["watched"] = watchedArr;
    snap["diagnostics"] = json({
        {"rxRaw", m_rxRaw}, {"rxSeen", m_rxSeen}, {"rxNew", m_rxNew}, {"rxDup", m_rxDup},
        {"txTotal", m_txTotal}, {"admDropSig", m_admDropSig}, {"admDropType", m_admDropType},
    });
    return snap;
}

void WhisperboxCoreImpl::publishState() {
    OrderedJson snap = buildSnapshot();
    m_snapshot = snap.dump();
    emit stateChanged(m_snapshot);
}

std::string WhisperboxCoreImpl::snapshot() {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    publishState();
    return m_snapshot;
}
std::string WhisperboxCoreImpl::status() {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    return m_status;
}

// ── create ───────────────────────────────────────────────────────────────────────
std::string WhisperboxCoreImpl::createForm(std::string defJson) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    json def;
    try { def = json::parse(trim(defJson)); } catch (...) { out["ok"] = false; out["error"] = "bad defJson"; return out.dump(); }
    if (!def.is_object()) { out["ok"] = false; out["error"] = "def must be an object"; return out.dump(); }
    std::string formId = lc(def.value("id", ""));
    if (formId.empty()) formId = "form-" + randomHex(4);
    if (def.contains("questions") && !def["questions"].is_array()) { out["ok"] = false; out["error"] = "questions must be an array"; return out.dump(); }

    OrderedJson p = OrderedJson::object();
    p["id"] = formId;
    p["title"] = def.value("title", "");
    p["description"] = def.value("description", "");
    p["creator"] = m_signId.address;
    p["publicKey"] = m_signId.pubHex;
    p["createdAt"] = nowMs();
    p["expiresAt"] = def.contains("expiresAt") ? def["expiresAt"] : nullptr;
    p["questions"] = def.value("questions", json::array());
    p["whitelist"] = def.value("whitelist", json({{"type", "none"}, {"value", ""}}));

    json e = buildEvent(FORM_PUBLISH, whisperbox::formPublishId(formId), p, /*sign=*/true);
    adoptLocal(e);
    broadcastEvent(e);
    publishState();
    out["ok"] = true; out["formId"] = formId; out["event"] = e;
    return out.dump();
}

std::string WhisperboxCoreImpl::closeForm(std::string formId) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(formId);
    OrderedJson state = whisperbox::computeState(m_log, m_signId.address);
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (state["forms"][formId]["creator"].get<std::string>() != m_signId.address) { out["ok"] = false; out["error"] = "not the creator"; return out.dump(); }

    OrderedJson p = OrderedJson::object();
    p["formId"] = formId;
    p["expiresAt"] = nullptr;
    p["author"] = m_signId.address;
    json e = buildEvent(FORM_CLOSE, whisperbox::formCloseId(formId), p, /*sign=*/true);
    adoptLocal(e);
    broadcastEvent(e);
    publishState();
    out["ok"] = true; out["formId"] = formId;
    return out.dump();
}

std::string WhisperboxCoreImpl::confirmResponse(std::string formId, std::string respondentAddr) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(formId);
    respondentAddr = lc(respondentAddr);
    OrderedJson state = whisperbox::computeState(m_log, m_signId.address);
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (state["forms"][formId]["creator"].get<std::string>() != m_signId.address) { out["ok"] = false; out["error"] = "not the creator"; return out.dump(); }

    // confirmationId is a deterministic function of (form, respondent) so re-
    // confirmation is idempotent under union-by-id merge.
    whisperbox::Bytes h = whisperbox::sha256(whisperbox::Bytes((formId + "|" + respondentAddr).begin(), (formId + "|" + respondentAddr).end()));
    std::string confirmationId = whisperbox::toHex(h.data(), 8);

    OrderedJson p = OrderedJson::object();
    p["formId"] = formId;
    p["confirmationId"] = confirmationId;
    p["author"] = m_signId.address;
    json e = buildEvent(RESPONSE_CONFIRM, whisperbox::responseConfirmId(formId, confirmationId), p, /*sign=*/true);
    adoptLocal(e);
    broadcastEvent(e);
    publishState();
    out["ok"] = true; out["formId"] = formId; out["confirmationId"] = confirmationId;
    return out.dump();
}

// ── respond ──────────────────────────────────────────────────────────────────────
std::string WhisperboxCoreImpl::submitResponse(std::string formId, std::string answersJson) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(formId);
    json answers;
    try { answers = json::parse(trim(answersJson)); } catch (...) { out["ok"] = false; out["error"] = "bad answersJson"; return out.dump(); }
    if (!answers.is_array()) { out["ok"] = false; out["error"] = "answers must be an array of {questionId,value}"; return out.dump(); }

    OrderedJson state = whisperbox::computeState(m_log, m_signId.address);
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    const auto& f = state["forms"][formId];
    if (f["status"].get<std::string>() != "open") { out["ok"] = false; out["error"] = "form is closed"; return out.dump(); }

    // The FULL response JSON is sealed to the creator — nothing appears in plaintext.
    long long submittedAt = nowMs();
    OrderedJson resp = OrderedJson::object();
    resp["formId"] = formId;
    resp["respondent"] = m_signId.address;
    resp["submittedAt"] = submittedAt;
    resp["answers"] = answers;
    std::string wlType = f["whitelist"].value("type", "none");
    if (wlType != "none") {
        // Inner signature over the canonical content (verified by the creator when
        // whitelist != none): address(pub) must equal respondent.
        OrderedJson m = OrderedJson::object();
        m["formId"] = formId;
        m["respondent"] = m_signId.address;
        m["submittedAt"] = submittedAt;
        m["answers"] = answers;
        std::string msg = "whisperbox-inner-v1|" + m.dump();
        whisperbox::Bytes digest = whisperbox::sha256(whisperbox::Bytes(msg.begin(), msg.end()));
        resp["signature"] = whisperbox::toHex(whisperbox::ecdsaSignLowS(m_signId.priv, digest));
        resp["pub"] = m_signId.pubHex;
    } else {
        resp["signature"] = nullptr;
        resp["pub"] = nullptr;
    }

    std::string creatorPubHex = f["publicKey"].get<std::string>();
    try {
        const std::string ptText = resp.dump();   // ONE dump — two temporaries would mix iterators
        whisperbox::Bytes pt(ptText.begin(), ptText.end());
        whisperbox::Bytes sealed = whisperbox::eciesSeal(whisperbox::fromHex(creatorPubHex), pt);
        std::string sealedHex = whisperbox::toHex(sealed);
        json p = {{"encryptedPayload", sealedHex}};
        json e = buildEvent(RESPONSE_SUBMIT, whisperbox::responseSubmitId(sealedHex), p, /*sign=*/false);
        adoptLocal(e);
        broadcastEvent(e);
        publishState();
        out["ok"] = true; out["eventId"] = e["id"].get<std::string>();
    } catch (const std::exception& ex) {
        fprintf(stderr, "WHISPERBOX submit EXCEPTION (%s): %s\n", typeid(ex).name(), ex.what());
        out["ok"] = false; out["error"] = std::string("seal failed: ") + ex.what();
    }
    return out.dump();
}

std::string WhisperboxCoreImpl::getDecryptedResponses(std::string formId) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(formId);
    OrderedJson state = whisperbox::computeState(m_log, m_signId.address);
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (state["forms"][formId]["creator"].get<std::string>() != m_signId.address) { out["ok"] = false; out["error"] = "not the creator"; return out.dump(); }

    auto open = [this](const std::string& hexBlob) -> json {
        try {
            whisperbox::Bytes pt = whisperbox::eciesOpen(m_signId.priv, whisperbox::fromHex(hexBlob));
            return json::parse(std::string(pt.begin(), pt.end()));
        } catch (...) { return json(); }
    };
    auto verifyResponse = [](const json& pseudo) -> bool {
        const json p = pseudo.value("payload", json::object());
        std::string pubHex = p.value("pub", ""), sigHex = p.value("signature", "");
        if (pubHex.empty() || sigHex.empty()) return false;
        OrderedJson m = OrderedJson::object();
        m["formId"] = lc(p.value("formId", ""));
        m["respondent"] = lc(p.value("respondent", ""));
        m["submittedAt"] = p.value("submittedAt", 0LL);
        m["answers"] = p.value("answers", json::array());
        std::string msg = "whisperbox-inner-v1|" + m.dump();
        whisperbox::Bytes digest = whisperbox::sha256(whisperbox::Bytes(msg.begin(), msg.end()));
        if (!whisperbox::ecdsaVerify(whisperbox::fromHex(pubHex), digest, whisperbox::fromHex(sigHex))) return false;
        whisperbox::Bytes h = whisperbox::sha256(whisperbox::fromHex(pubHex));
        return ("0x" + whisperbox::toHex(h.data(), 32).substr(24, 40)) == lc(p.value("respondent", ""));
    };
    OrderedJson view = whisperbox::creatorView(state, m_signId.address, open, verifyResponse);
    out["ok"] = true;
    out["responses"] = view["responses"].contains(formId) ? json(view["responses"][formId]) : json::array();
    return out.dump();
}

// ── manage ───────────────────────────────────────────────────────────────────────
std::string WhisperboxCoreImpl::joinForm(std::string formId) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    formId = lc(formId);
    m_watched.insert(formId);
    saveWatched();
    publishState();
    json out = {{"ok", true}, {"formId", formId}};
    return out.dump();
}

std::string WhisperboxCoreImpl::deleteLocalForm(std::string formId) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    formId = lc(formId);
    m_watched.erase(formId);
    saveWatched();
    publishState();
    json out = {{"ok", true}, {"formId", formId}};
    return out.dump();
}

std::string WhisperboxCoreImpl::importIdentity(std::string privHex) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!isHex(trim(privHex), 64)) { out["ok"] = false; out["error"] = "privHex must be 64 hex chars"; return out.dump(); }
    m_signId = whisperbox::identityFromPriv(whisperbox::fromHex(trim(privHex)));
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "invalid scalar (0, >= n, or bad point)"; return out.dump(); }
    saveIdentity();
    publishState();
    out["ok"] = true; out["address"] = m_signId.address;
    return out.dump();
}

std::string WhisperboxCoreImpl::setDeviceId(std::string deviceId) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    deviceId = trim(deviceId);
    if (deviceId.empty()) { json o = {{"ok", false}, {"error", "empty deviceId"}}; return o.dump(); }
    m_deviceId = deviceId;
    m_clock = whisperbox::Clock(m_deviceId);   // HLC dev identity changes with the device id
    std::ofstream f(m_dataDir + "/device_id.txt", std::ios::trunc); if (f) f << m_deviceId;
    json out = {{"ok", true}, {"deviceId", m_deviceId}};
    return out.dump();
}

std::string WhisperboxCoreImpl::shareUri(std::string formId) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    formId = lc(formId);
    OrderedJson state = whisperbox::computeState(m_log, m_signId.valid ? m_signId.address : "");
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    const auto& f = state["forms"][formId];
    OrderedJson def = OrderedJson::object();
    def["id"] = f["id"];
    def["title"] = f["title"];
    def["description"] = f["description"];
    def["creator"] = f["creator"];
    def["publicKey"] = f["publicKey"];
    def["createdAt"] = f["createdAt"];
    def["expiresAt"] = f["expiresAt"];
    def["questions"] = f["questions"];
    def["whitelist"] = f["whitelist"];
    std::string uri = "whisperbox://form?" + whisperbox::b64encode(def.dump());
    out["ok"] = true; out["uri"] = uri;
    return out.dump();
}

std::string WhisperboxCoreImpl::shareQr(std::string formId) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    json u;
    try { u = json::parse(shareUri(formId)); } catch (...) { out["ok"] = false; out["error"] = "shareUri failed"; return out.dump(); }
    if (!u.value("ok", false)) { out = u; return out.dump(); }
    const std::string uri = u["uri"].get<std::string>();
    try {
        const qrcodegen::QrCode qr =
            qrcodegen::QrCode::encodeText(uri.c_str(), qrcodegen::QrCode::Ecc::MEDIUM);
        const int n = qr.getSize();
        json cells = json::array();
        for (int y = 0; y < n; ++y)
            for (int x = 0; x < n; ++x) cells.push_back(qr.getModule(x, y));
        out["ok"] = true; out["n"] = n; out["cells"] = std::move(cells); out["text"] = uri;
    } catch (const std::exception& e) {
        out["ok"] = false; out["error"] = std::string("qr encode failed: ") + e.what();
    }
    return out.dump();
}

std::string WhisperboxCoreImpl::importForm(std::string defJson) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    json def;
    try { def = json::parse(trim(defJson)); } catch (...) { out["ok"] = false; out["error"] = "bad defJson"; return out.dump(); }
    if (!def.is_object() || !def.contains("id") || !def.contains("publicKey")) {
        out["ok"] = false; out["error"] = "def must include id and publicKey (use shareUri output)"; return out.dump();
    }
    // Accept a raw def object OR a whisperbox://form?<b64> URI.
    std::string uriText = trim(defJson);
    if (uriText.rfind("whisperbox://", 0) == 0) {
        size_t q = uriText.find('?');
        if (q != std::string::npos) {
            try { def = json::parse(whisperbox::b64decode(uriText.substr(q + 1))); }
            catch (...) { out["ok"] = false; out["error"] = "bad URI payload"; return out.dump(); }
        }
    }
    if (!def.is_object() || !def.contains("id") || !def.contains("publicKey")) {
        out["ok"] = false; out["error"] = "def must include id and publicKey"; return out.dump();
    }
    std::string formId = lc(def.value("id", ""));
    if (formId.empty()) { out["ok"] = false; out["error"] = "missing id"; return out.dump(); }

    // Optimistic local adoption so the UI renders before sync catches up. The
    // canonical signed event from the topic wins later under union-by-id (same id).
    OrderedJson state = whisperbox::computeState(m_log, m_signId.valid ? m_signId.address : "");
    if (!state["forms"].contains(formId)) {
        OrderedJson p = OrderedJson::object();
        p["id"] = formId;
        p["title"] = def.value("title", "");
        p["description"] = def.value("description", "");
        p["creator"] = lc(def.value("creator", ""));
        p["publicKey"] = def.value("publicKey", "");
        p["createdAt"] = def.value("createdAt", 0LL);
        p["expiresAt"] = def.contains("expiresAt") ? def["expiresAt"] : nullptr;
        p["questions"] = def.value("questions", json::array());
        p["whitelist"] = def.value("whitelist", json({{"type", "none"}, {"value", ""}}));
        // Unsigned local placeholder (we are not the creator) — admitted locally only.
        OrderedJson e = OrderedJson::object();
        e["v"] = 1; e["id"] = whisperbox::formPublishId(formId); e["type"] = FORM_PUBLISH;
        e["hlc"] = m_clock.send(nowMs()); e["dev"] = m_deviceId; e["payload"] = p;
        adoptLocal(e);
    }
    m_watched.insert(formId);
    saveWatched();
    publishState();
    out["ok"] = true; out["formId"] = formId;
    return out.dump();
}

std::string WhisperboxCoreImpl::exportCsv(std::string formId) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(formId);
    OrderedJson state = whisperbox::computeState(m_log, m_signId.address);
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (state["forms"][formId]["creator"].get<std::string>() != m_signId.address) { out["ok"] = false; out["error"] = "not the creator"; return out.dump(); }

    auto open = [this](const std::string& hexBlob) -> json {
        try {
            whisperbox::Bytes pt = whisperbox::eciesOpen(m_signId.priv, whisperbox::fromHex(hexBlob));
            return json::parse(std::string(pt.begin(), pt.end()));
        } catch (...) { return json(); }
    };
    auto verifyResponse = [](const json& pseudo) -> bool {
        const json p = pseudo.value("payload", json::object());
        std::string pubHex = p.value("pub", ""), sigHex = p.value("signature", "");
        if (pubHex.empty() || sigHex.empty()) return false;
        OrderedJson m = OrderedJson::object();
        m["formId"] = lc(p.value("formId", ""));
        m["respondent"] = lc(p.value("respondent", ""));
        m["submittedAt"] = p.value("submittedAt", 0LL);
        m["answers"] = p.value("answers", json::array());
        std::string msg = "whisperbox-inner-v1|" + m.dump();
        whisperbox::Bytes digest = whisperbox::sha256(whisperbox::Bytes(msg.begin(), msg.end()));
        if (!whisperbox::ecdsaVerify(whisperbox::fromHex(pubHex), digest, whisperbox::fromHex(sigHex))) return false;
        whisperbox::Bytes h = whisperbox::sha256(whisperbox::fromHex(pubHex));
        return ("0x" + whisperbox::toHex(h.data(), 32).substr(24, 40)) == lc(p.value("respondent", ""));
    };
    OrderedJson view = whisperbox::creatorView(state, m_signId.address, open, verifyResponse);

    auto csvCell = [](const std::string& s) {
        if (s.find_first_of(",\"\n") != std::string::npos) {
            std::string o = "\""; for (char c : s) { if (c == '"') o += "\"\""; else o += c; } return o + "\"";
        }
        return s;
    };
    const auto& f = state["forms"][formId];
    std::string csv = "respondent,submittedAt,";
    json qids = json::array();
    for (const auto& q : f["questions"]) { csv += csvCell(q.value("text", q.value("id", ""))) + ","; qids.push_back(q.value("id", "")); }
    csv += "\n";
    if (view["responses"].contains(formId)) {
        for (const auto& r : view["responses"][formId]) {
            csv += csvCell(r["respondent"].get<std::string>()) + "," + std::to_string(r.value("submittedAt", 0LL)) + ",";
            json byQ = json::object();
            for (const auto& a : r["answers"]) byQ[a.value("questionId", "")] = a.value("value", "");
            for (const auto& qid : qids) {
                std::string v = byQ.contains(qid.get<std::string>()) ? json(byQ[qid.get<std::string>()]).dump() : "";
                if (v.rfind("\"", 0) == 0 && v.size() >= 2) v = v.substr(1, v.size() - 2); // strip JSON quoting for plain strings
                csv += csvCell(v) + ",";
            }
            csv += "\n";
        }
    }
    out["ok"] = true; out["csv"] = csv;
    return out.dump();
}

std::string WhisperboxCoreImpl::resync() {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    if (!m_nodeReady) { json o = {{"ok", false}, {"error", "node not ready"}}; return o.dump(); }
    // Ask peers for state AND re-serve ours (idempotent both ways).
    std::string text = whisperbox::eventToJsonText(whisperbox::envSyncReq(m_deviceId));
    if (deliverySend(TOPIC, whisperbox::b64encode(text))) m_txTotal++;
    seedBroadcast();
    publishState();
    json out = {{"ok", true}, {"logSize", (int)m_log.size()}};
    return out.dump();
}
