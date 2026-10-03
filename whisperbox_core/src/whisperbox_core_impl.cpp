// WhisperboxCoreImpl implementation. Engine/crypto/wire are the std-only headers
// (whisperbox_engine.hpp etc., byte-parity with the TS reference). This file wires
// the mutation API + the delivery_module transport (SDS Reliable Channels) over ONE
// shared topic, routing incoming envelopes into the single merged log.
//
// Every delivery call is async / fire-and-forget (a synchronous send on the
// event-loop thread freezes the module on the IPC timeout).
#include "whisperbox_core_impl.h"
#include "logos_sdk.h"   // umbrella: LogosModules + LogosMap(nlohmann::json) + StdLogosResult
#include "qrcodegen.hpp"
#include "logos_sync/catchup.hpp"   // loam-sync RBSR catch-up (fp/ids/need) - replaces the whole-log reseed  // vendored Nayuki QR encoder (host qr core unreachable from a pure-QML view)
#include <QTimer>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cctype>
#include <fstream>
#include <algorithm>
#include <typeinfo>
#include <ctime>
#include <filesystem>
#include <pwd.h>
#include <unistd.h>

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

// Crash-safe file write: write <path>.tmp, then rename over <path> (atomic on POSIX). A
// module killed mid-write (Basecamp quitting during sync) leaves the old file intact
// instead of a truncated one that the next start would read as corrupt.
static bool writeAtomic(const std::string& path, const std::string& content) {
    const std::string tmp = path + ".tmp";
    {
        std::ofstream f(tmp, std::ios::trunc | std::ios::binary);
        if (!f) return false;
        f << content;
        f.flush();
        if (!f) return false;
    }
    return std::rename(tmp.c_str(), path.c_str()) == 0;
}
// Move an unreadable file aside (never overwrite it): the data may still be recoverable.
static void quarantine(const std::string& path) {
    const std::string to = path + ".corrupt-" + std::to_string((long long)std::time(nullptr));
    std::rename(path.c_str(), to.c_str());
    fprintf(stderr, "WHISPERBOX moved unreadable %s to %s\n", path.c_str(), to.c_str());
}

static std::string sha16(const std::string& s) {
    // ONE named string: building Bytes from two separate temporaries' begin()/end()
    // mixes iterators of different objects (UB -> std::length_error in practice).
    whisperbox::Bytes b(s.begin(), s.end());
    return whisperbox::toHex(whisperbox::sha256(b).data(), 8);
}
// Pre-0.2 receipt id: deterministic hash of (form, respondent). Kept only to
// confirm/recognise LEGACY responses — it is linkable (anyone can recompute it
// for a candidate address), which is why 0.2 seals a random id instead.
static std::string legacyConfirmId(const std::string& formId, const std::string& respondent) {
    return sha16(lc(formId) + "|" + lc(respondent));
}
static std::string confirmIdOf(const json& r, const std::string& formId) {
    if (r.contains("confirmationId") && r["confirmationId"].is_string() && !r["confirmationId"].get<std::string>().empty())
        return r["confirmationId"].get<std::string>();
    return legacyConfirmId(formId, r.value("respondent", ""));
}
static bool containsStr(const json& arr, const std::string& v) {
    if (!arr.is_array()) return false;
    for (const auto& x : arr) if (x.is_string() && x.get<std::string>() == v) return true;
    return false;
}
static bool emptyAnswer(const json& v) {
    if (v.is_null()) return true;
    if (v.is_string()) return trim(v.get<std::string>()).empty();
    if (v.is_array()) return v.empty();
    return false;
}
// Inner signature over the DECRYPTED content (whitelist != none):
// canonical "whisperbox-inner-v1|{formId,respondent,submittedAt,answers}",
// ECDSA low-S, and address(pub) must equal respondent.
static bool verifyInnerResponse(const json& pseudo) {
    const json p = pseudo.value("payload", json::object());
    auto str = [&p](const char* k) { return p.contains(k) && p[k].is_string() ? p[k].get<std::string>() : std::string(); };   // null-safe ("pub": null on unsigned answers)
    std::string pubHex = str("pub"), sigHex = str("signature");
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
}
static std::string isoUtc(long long ms) {
    if (ms <= 0) return "";
    time_t t = (time_t)(ms / 1000); struct tm tmv; gmtime_r(&t, &tmv);
    char buf[32]; strftime(buf, sizeof buf, "%Y-%m-%dT%H:%M:%SZ", &tmv);
    return buf;
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
    // Per-install device id (HLC dev + SDS senderId + SYNC_REQ "from"). It MUST be
    // unique: with a shared default every peer ignored the others' SYNC_REQ as its
    // own and SDS dropped their channel frames as self-echo.
    {
        std::ifstream df(m_dataDir + "/device_id.txt");
        std::string d; if (df) std::getline(df, d);
        d = trim(d);
        if (d.empty() || d == "whisperbox-core") {
            d = "wb-" + randomHex(6);
            writeAtomic(m_dataDir + "/device_id.txt", d);
        }
        m_deviceId = d;
    }
    fprintf(stderr, "WHISPERBOX deviceId=%s\n", m_deviceId.c_str());
    m_clock = whisperbox::Clock(m_deviceId);
    loadLog();
    fprintf(stderr, "WHISPERBOX log events=%zu\n", m_log.size());
    m_clock.primeFrom(m_log);
    loadWatched();
    loadMySubmissions();
    loadLocalPrefs();
    loadPins();
    bootstrapDelivery();
    fprintf(stderr, "WHISPERBOX delivery bootstrapped nodeReady=%d\n", (int)m_nodeReady);
    // Hub tick: retry node start until ready, then a rate-limited periodic seed so
    // late joiners on a sparse mesh still converge (idempotent — peers dedup by id).
    m_hubTimer = new QTimer();
    QObject::connect(m_hubTimer, &QTimer::timeout, [this] {
        std::lock_guard<std::recursive_mutex> lk(m_mtx);
        if (!m_nodeReady) bootstrapDelivery();
        else {
            // Catch-up schedule: an RBSR round at 3s, 10s, 25s after node-up (the first
            // answer may come from a peer holding only part of the log), then every 60s.
            // A round is ONE bounded fingerprint message; peers reply with the exact delta
            // (never the whole log). The first rounds also carry a SYNC_REQ for 0.1.x peers.
            static const long long kBackoffMs[] = {3000, 10000, 25000};
            long long delay = m_syncReqTries <= 3 ? kBackoffMs[m_syncReqTries - 1] : 60000;
            if (nowMs() - m_lastSyncReqMs >= delay) {
                if (m_syncReqTries <= 3) requestSync(); else { m_lastSyncReqMs = nowMs(); m_syncReqTries++; }
                catchupRound();
            }
            if (nowMs() - m_lastHousekeepMs >= 5000) { m_lastHousekeepMs = nowMs(); housekeeping(); }
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
// The data folder holds the identity key: losing it silently mints a new identity, and every
// answer sealed to the old one is gone (seen in a real Basecamp: new address on each start).
// So: never a relative path (the host's working dir can be an AppImage mount that changes
// every launch), resolve home from the user database (HOME may be unset in a module host),
// prove the folder is writable, and adopt existing data from any known location.
static std::string realHome() {
    // Tests: stand-in for the user database (never touch the real home from a test).
    if (const char* t = std::getenv("WHISPERBOX_TEST_REAL_HOME")) return t;
    if (struct passwd* pw = getpwuid(getuid())) if (pw->pw_dir && *pw->pw_dir) return pw->pw_dir;
    const char* h = std::getenv("HOME");
    return (h && *h == '/') ? h : "";
}
static bool dirWritable(const std::string& d) {
    if (d.empty() || d[0] != '/') return false;
    std::error_code ec;
    std::filesystem::create_directories(d, ec);
    const std::string probe = d + "/.write-test";
    { std::ofstream f(probe, std::ios::trunc); if (!f) return false; f << "ok"; f.flush(); if (!f) return false; }
    std::filesystem::remove(probe, ec);
    return true;
}
static bool hasIdentityFile(const std::string& d) {
    std::error_code ec;
    return !d.empty() && std::filesystem::is_regular_file(d + "/identity.json", ec) && std::filesystem::file_size(d + "/identity.json", ec) > 0;
}
void WhisperboxCoreImpl::setupDataDir() {
    m_storageOk = true; m_storageNote.clear();
    if (const char* ov = std::getenv("WHISPERBOX_CORE_DATA")) {
        m_dataDir = ov;
        if (!dirWritable(m_dataDir)) { m_storageOk = false; m_storageNote = "Can't save to " + m_dataDir; }
        return;
    }
    std::vector<std::string> cands;
    const std::string rh = realHome();
    if (!rh.empty()) cands.push_back(rh + "/.whisperbox-core");                       // survives reinstall
    if (const char* eh = std::getenv("HOME"))
        if (*eh == '/' && std::string(eh) + "/.whisperbox-core" != (cands.empty() ? "" : cands[0])) cands.push_back(std::string(eh) + "/.whisperbox-core");
    if (!instancePersistencePath().empty()) cands.push_back(instancePersistencePath()); // host-owned; wiped on uninstall
    m_dataDir.clear();
    for (const auto& c : cands) if (dirWritable(c)) { m_dataDir = c; break; }
    if (m_dataDir.empty()) {
        m_storageOk = false;
        m_dataDir = cands.empty() ? std::string("/tmp/whisperbox-core-") + std::to_string(getuid()) : cands[0];
        m_storageNote = "Can't save anything (tried " + std::to_string(cands.size()) + " folders) - forms and your identity will not survive a restart";
        fprintf(stderr, "WHISPERBOX STORAGE NOT WRITABLE: %s\n", m_storageNote.c_str());
        return;
    }
    // Adopt an identity (and the rest) kept elsewhere instead of minting a new one.
    if (!hasIdentityFile(m_dataDir)) {
        for (const auto& c : cands) {
            if (c == m_dataDir || !hasIdentityFile(c)) continue;
            std::error_code ec;
            for (const char* fn : {"identity.json", "device_id.txt", "events.json", "watched.json", "my_submissions.json", "pins.json"})
                if (std::filesystem::exists(c + "/" + fn, ec))
                    std::filesystem::copy_file(c + "/" + fn, m_dataDir + "/" + fn, std::filesystem::copy_options::skip_existing, ec);
            fprintf(stderr, "WHISPERBOX adopted data from %s\n", c.c_str());
            m_storageNote = "Moved your data from " + c;
            break;
        }
    }
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
        } catch (...) { /* unreadable */ }
        // The file exists but is unreadable: it holds the ONLY key that opens every answer
        // sealed to this creator. Move it aside (recoverable) - never overwrite it.
        f.close();
        quarantine(m_dataDir + "/identity.json");
    }
    // First run (or the old file was quarantined): generate a keypair.
    std::string priv = randomHex(32);
    m_signId = whisperbox::identityFromPriv(whisperbox::fromHex(priv));
    if (!m_signId.valid) { fprintf(stderr, "WHISPERBOX identity generation failed\n"); return; }
    saveIdentity();
    fprintf(stderr, "WHISPERBOX new identity %s\n", m_signId.address.c_str());
}
void WhisperboxCoreImpl::saveIdentity() {
    json o = {{"privHex", whisperbox::toHex(m_signId.priv)}, {"pubHex", m_signId.pubHex}, {"address", m_signId.address}};
    writeAtomic(m_dataDir + "/identity.json", o.dump());
}
void WhisperboxCoreImpl::loadLog() {
    std::ifstream f(m_dataDir + "/events.json");
    if (!f) return;
    try {
        json a = json::parse(std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>()));
        if (a.is_array()) for (auto& e : a) if (e.is_object() && e.contains("id")) m_log.push_back(e);
    } catch (...) {
        // Never let the next save overwrite it: keep the unreadable file for recovery.
        f.close();
        quarantine(m_dataDir + "/events.json");
        m_log.clear();
    }
    // Repair logs written by <= 0.1.x: (1) drop UNSIGNED form.publish placeholders
    // left by importForm — they shadowed the creator's signed event forever (same
    // id, first copy wins) so the form never got its questions/key; (2) re-sort
    // (the old incremental merge inserted out of HLC order).
    size_t before = m_log.size();
    std::vector<json> kept;
    for (auto& e : m_log) {
        if (e.value("type", "") == FORM_PUBLISH && (!e.contains("sig") || !e["sig"].is_string() || e["sig"].get<std::string>().empty())) continue;
        kept.push_back(e);
    }
    std::vector<std::vector<json>> logs; logs.push_back(kept);
    std::vector<json> repaired = whisperbox::mergeWhisperbox(logs);
    bool changed = repaired.size() != before || json(repaired).dump() != json(m_log).dump();
    m_log = std::move(repaired);
    if (changed) { fprintf(stderr, "WHISPERBOX log repaired %zu -> %zu events\n", before, m_log.size()); saveLog(); }
}
void WhisperboxCoreImpl::saveLog() {
    writeAtomic(m_dataDir + "/events.json", json(m_log).dump());
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
    writeAtomic(m_dataDir + "/watched.json", a.dump());
}
void WhisperboxCoreImpl::loadPins() {
    m_pinned.clear();
    std::ifstream f(m_dataDir + "/pins.json"); if (!f) return;
    try {
        json o = json::parse(std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>()));
        if (o.is_object()) for (auto it = o.begin(); it != o.end(); ++it) if (it.value().is_string()) m_pinned[lc(it.key())] = lc(it.value().get<std::string>());
    } catch (...) { /* ignore */ }
}
void WhisperboxCoreImpl::savePins() {
    json o = json::object(); for (auto& kv : m_pinned) o[kv.first] = kv.second;
    writeAtomic(m_dataDir + "/pins.json", o.dump());
}
void WhisperboxCoreImpl::loadMySubmissions() {
    m_mySubmissions.clear(); m_myConfirmIds.clear();
    std::ifstream f(m_dataDir + "/my_submissions.json"); if (!f) return;
    try {
        json a = json::parse(std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>()));
        // <= 0.1.x: ["formId", ...] (legacy receipt id); 0.2+: {"formId": "<confirmationId>"}
        if (a.is_array()) for (auto& x : a) if (x.is_string()) m_mySubmissions.insert(lc(x.get<std::string>()));
        if (a.is_object()) for (auto it = a.begin(); it != a.end(); ++it) {
            m_mySubmissions.insert(lc(it.key()));
            if (it.value().is_string() && !it.value().get<std::string>().empty()) m_myConfirmIds[lc(it.key())] = it.value().get<std::string>();
        }
    } catch (...) { /* ignore */ }
}
void WhisperboxCoreImpl::loadLocalPrefs() {
    m_hidden.clear(); m_myAnswers.clear(); m_drafts.clear(); m_answerDrafts.clear(); m_autoReceipts.clear(); m_seen.clear();
    try {
        std::ifstream sn(m_dataDir + "/seen.json");
        if (sn) { json o = json::parse(std::string((std::istreambuf_iterator<char>(sn)), std::istreambuf_iterator<char>()));
                  if (o.is_object()) for (auto it = o.begin(); it != o.end(); ++it) if (it.value().is_number_integer()) m_seen[lc(it.key())] = it.value().get<long long>(); }
    } catch (...) { /* ignore */ }
    try {
        std::ifstream d(m_dataDir + "/drafts.json");
        if (d) { json o = json::parse(std::string((std::istreambuf_iterator<char>(d)), std::istreambuf_iterator<char>()));
                 if (o.contains("forms") && o["forms"].is_object()) for (auto it = o["forms"].begin(); it != o["forms"].end(); ++it) m_drafts[it.key()] = it.value();
                 if (o.contains("answers") && o["answers"].is_object()) for (auto it = o["answers"].begin(); it != o["answers"].end(); ++it) m_answerDrafts[lc(it.key())] = it.value();
                 if (o.contains("autoReceipts") && o["autoReceipts"].is_array()) for (auto& x : o["autoReceipts"]) if (x.is_string()) m_autoReceipts.insert(lc(x.get<std::string>())); }
    } catch (...) { fprintf(stderr, "WHISPERBOX drafts.json unreadable - starting without drafts\n"); }
    try {
        std::ifstream h(m_dataDir + "/hidden.json");
        if (h) { json a = json::parse(std::string((std::istreambuf_iterator<char>(h)), std::istreambuf_iterator<char>()));
                 if (a.is_array()) for (auto& x : a) if (x.is_string()) m_hidden.insert(lc(x.get<std::string>())); }
    } catch (...) { /* ignore */ }
    try {
        std::ifstream m(m_dataDir + "/my_answers.json");
        if (m) { json o = json::parse(std::string((std::istreambuf_iterator<char>(m)), std::istreambuf_iterator<char>()));
                 if (o.is_object()) for (auto it = o.begin(); it != o.end(); ++it) m_myAnswers[lc(it.key())] = it.value(); }
    } catch (...) { /* ignore */ }
}
void WhisperboxCoreImpl::saveDrafts() {
    json o = json::object();
    json d = json::object(); for (auto& kv : m_drafts) d[kv.first] = kv.second;
    json a = json::object(); for (auto& kv : m_answerDrafts) a[kv.first] = kv.second;
    json r = json::array(); for (auto& id : m_autoReceipts) r.push_back(id);
    o["forms"] = d; o["answers"] = a; o["autoReceipts"] = r;
    writeAtomic(m_dataDir + "/drafts.json", o.dump());
}
void WhisperboxCoreImpl::saveSeen() {
    json o = json::object(); for (auto& kv : m_seen) o[kv.first] = kv.second;
    writeAtomic(m_dataDir + "/seen.json", o.dump());
}
// Mark every response of a form as seen (creator opened it).
std::string WhisperboxCoreImpl::markSeen(std::string formId) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    formId = lc(trim(formId));
    OrderedJson state = whisperbox::computeState(m_log, m_signId.address, nullptr, m_pinned);
    OrderedJson cv = decryptView(state);
    long long n = cv["responses"].contains(formId) ? (long long)cv["responses"][formId].size() : 0;
    if (!m_seen.count(formId) || m_seen[formId] != n) { m_seen[formId] = n; saveSeen(); publishState(); }
    return json({{"ok", true}, {"formId", formId}, {"seen", n}}).dump();
}
void WhisperboxCoreImpl::saveHidden() {
    json a = json::array(); for (auto& id : m_hidden) a.push_back(id);
    writeAtomic(m_dataDir + "/hidden.json", a.dump());
}
void WhisperboxCoreImpl::saveMyAnswers() {
    json o = json::object(); for (auto& kv : m_myAnswers) o[kv.first] = kv.second;
    writeAtomic(m_dataDir + "/my_answers.json", o.dump());
}
void WhisperboxCoreImpl::saveMySubmissions() {
    json o = json::object();
    for (auto& id : m_mySubmissions) o[id] = m_myConfirmIds.count(id) ? m_myConfirmIds[id] : std::string();
    writeAtomic(m_dataDir + "/my_submissions.json", o.dump());
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
        auto onUp = [this]() {
            std::lock_guard<std::recursive_mutex> lk(m_mtx);
            m_nodeReady = true;
            joinTransport();
            requestSync();     // legacy (0.1.x) peers answer with their log
            catchupRound();    // RBSR peers reconcile the exact delta both ways
            setStatus("Connected");
            publishState();
        };
        modules().delivery_module.createNodeAsync(cfgStr, [this, onUp](StdLogosResult r) {
            if (!r.success) {
                // Basecamp runs ONE delivery_module for every app: when scala / kym / qaku (or
                // loam_core on their behalf) already created the node, createNode answers
                // "Context already initialized". That node is ours too - join it; never start
                // it a second time (the owner did). Was: reported as an error + retried forever,
                // so WhisperBox never connected when another Logos app started first.
                if (r.error.find("already initialized") != std::string::npos) {
                    fprintf(stderr, "WHISPERBOX delivery node already running (another app) - joining it\n");
                    onUp();
                    return;
                }
                m_deliveryStarting = false; setStatus("Delivery error (createNode): " + r.error); return;
            }
            modules().delivery_module.startAsync([this, onUp](StdLogosResult r2) {
                if (!r2.success) { m_deliveryStarting = false; setStatus("Delivery error (start): " + r2.error); return; }
                onUp();
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

// One RBSR round: publish a bounded fingerprint over our id-set. Peers respond() with
// splits / exact id lists / need, converging on the id-exact delta in both directions.
void WhisperboxCoreImpl::catchupRound() {
    if (!m_nodeReady) return;
    std::vector<logos_sync::Event> evs; evs.reserve(m_log.size());
    // RBSR items are event KEYS (id, or id#signer for signed events) so two signers'
    // events under one id both reconcile - same key function as the merge.
    for (const auto& e : m_log) { logos_sync::Event x; x.id = whisperbox::eventKey(e); evs.push_back(std::move(x)); }
    sendControl(logos_sync::catchup::buildInitial(evs, m_deviceId));
}
void WhisperboxCoreImpl::sendControl(const json& msg) {
    const std::string b64 = whisperbox::b64encode(msg.dump());
    try {
        std::vector<uint8_t> raw(b64.begin(), b64.end());
        modules().delivery_module.sendAsync(TOPIC, raw, [](StdLogosResult){});
    } catch (...) { /* best-effort */ }
    if (deliverySend(TOPIC, b64)) m_txTotal++;
}

// Ask peers for state (flagged rbsr: 0.2+ peers ignore it and reconcile via RBSR;
// 0.1.x peers answer with a full-log seedBroadcast, rate-limited 3s on their side).
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
        if (type == "RBSR") {
            std::vector<logos_sync::Event> evs; evs.reserve(m_log.size());
            std::map<std::string, const json*> byId;
            for (const auto& e : m_log) {
                logos_sync::Event x; x.id = whisperbox::eventKey(e); byId[x.id] = &e; evs.push_back(std::move(x));
            }
            env.erase("type");
            auto step = logos_sync::catchup::respond(evs, env, m_deviceId);
            for (const auto& r : step.replies) sendControl(r);
            for (const auto& sv : step.serve) { auto it = byId.find(sv.id); if (it != byId.end()) broadcastEvent(*it->second); }
            m_rbsrRx++;
            return true;
        }
        if (type == "SYNC_REQ") {
            // Flagged rbsr = a peer that reconciles via RBSR; re-serving the whole log too
            // would be pure flood. Unflagged = a 0.1.x peer that only knows SYNC_REQ.
            if (env.contains("rbsr")) return true;
            if (env.value("from", "") != m_deviceId && nowMs() - m_lastSyncReserveMs >= 3000) {
                m_lastSyncReserveMs = nowMs();
                m_legacyReseeds++;
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
    if (type == RESPONSE_CONFIRM || type == FORM_CLOSE || type == whisperbox::FORM_REOPEN || type == whisperbox::FORM_UPDATE) {
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
    OrderedJson state = whisperbox::computeState(m_log, me, verify, m_pinned);

    // Creator view: decrypt the response pool with our key, then mark each
    // response confirmed by matching its receipt id against the public set
    // (module layer, NOT the engine - keeps the TS/C++ engine parity intact).
    json creatorViewJson;
    if (state["creator"] != nullptr && m_signId.valid) {
        OrderedJson cv = decryptView(state);
        for (auto it = cv["responses"].begin(); it != cv["responses"].end(); ++it) {
            const std::string fid = it.key();
            const json confs = cv["confirmations"].contains(fid) ? json(cv["confirmations"][fid]) : json::array();
            for (auto& r : it.value()) {
                if (!r.is_object()) continue;
                r["confirmed"] = containsStr(confs, confirmIdOf(r, fid));
            }
        }
        creatorViewJson = json::parse(cv.dump());
    }

    // Per-form flags for THIS device (module layer): has the local identity
    // answered / been confirmed / may it answer at all.
    bool seenDirty = false;
    long long newTotal = 0;
    for (auto it = state["forms"].begin(); it != state["forms"].end(); ++it) {
        const std::string fid = it.key();
        auto& f = it.value();
        const bool mine = m_signId.valid && f["creator"].get<std::string>() == m_signId.address;
        const bool submitted = m_mySubmissions.count(fid) > 0;
        bool confirmed = false;
        if (submitted && m_signId.valid) {
            std::string cid = m_myConfirmIds.count(fid) ? m_myConfirmIds[fid] : legacyConfirmId(fid, m_signId.address);
            confirmed = containsStr(f["confirmations"], cid);
        }
        std::string wlType = f["whitelist"].is_object() ? f["whitelist"].value("type", "none") : "none";
        bool allowed = true;
        if (wlType == "addresses") {
            auto list = whisperbox::whitelistAddresses(f["whitelist"]);
            allowed = m_signId.valid && std::find(list.begin(), list.end(), m_signId.address) != list.end();
        } else if (wlType != "none") allowed = false;   // nft: unsupported in v1
        const bool contested = f.contains("contested") && f["contested"].is_boolean() && f["contested"].get<bool>();
        const std::string pin = m_pinned.count(fid) ? m_pinned[fid] : std::string();
        const bool linkMismatch = !pin.empty() && pin != f["creator"].get<std::string>();
        const bool trusted = !linkMismatch && (!contested || pin == f["creator"].get<std::string>());
        f["contested"] = contested;
        f["pinnedCreator"] = pin.empty() ? json(nullptr) : json(pin);
        f["linkMismatch"] = linkMismatch;
        f["mine"] = mine;
        f["mySubmitted"] = submitted;
        if (mine) {   // "N new" since the creator last looked
            long long n = (creatorViewJson.is_object() && creatorViewJson.contains("responses") && creatorViewJson["responses"].contains(fid))
                          ? (long long)creatorViewJson["responses"][fid].size() : 0;
            if (!m_seen.count(fid)) { m_seen[fid] = n; seenDirty = true; }   // first sight: nothing is "new"
            f["newResponses"] = std::max(0LL, n - m_seen[fid]);
            if (!m_hidden.count(fid)) newTotal += std::max(0LL, n - m_seen[fid]);
        }
        if (submitted && f.contains("allowEdits") && f["allowEdits"].is_boolean() && f["allowEdits"].get<bool>() && m_myAnswers.count(fid)) {
            const long long first = m_myAnswers[fid].value("firstSubmittedAt", m_myAnswers[fid].value("submittedAt", 0LL));
            const long long until = first + (f["editWindowMinutes"].is_number() ? f["editWindowMinutes"].get<long long>() : 15) * 60000LL;
            f["editUntil"] = until;
            f["canEdit"] = !confirmed && f["status"].get<std::string>() == "open" && nowMs() < until;
        }
        f["hidden"] = m_hidden.count(fid) > 0;
        f["autoReceipts"] = m_autoReceipts.count(fid) > 0;
        if (m_answerDrafts.count(fid)) f["answerDraft"] = m_answerDrafts[fid];
        if (m_myAnswers.count(fid)) f["myAnswers"] = m_myAnswers[fid];
        f["myConfirmed"] = confirmed;
        f["allowed"] = allowed;
        f["canRespond"] = trusted && !mine && !submitted && allowed && f["status"].get<std::string>() == "open"
                          && f["publicKey"].is_string() && !f["publicKey"].get<std::string>().empty();
    }

    OrderedJson snap = OrderedJson::object();
    snap["v"] = 1;
    snap["identity"] = m_signId.valid
        ? json({{"address", m_signId.address}, {"pubHex", m_signId.pubHex}}) : nullptr;
    if (seenDirty) saveSeen();
    snap["deviceId"] = m_deviceId;
    snap["newResponses"] = newTotal;   // across my (non-hidden) forms
    snap["storage"] = json({{"dir", m_dataDir}, {"ok", m_storageOk}, {"note", m_storageNote}});
    snap["nodeReady"] = m_nodeReady;
    snap["state"] = state;
    snap["creatorView"] = creatorViewJson.is_null() ? nullptr : creatorViewJson;
    json watchedArr = json::array(); for (auto& id : m_watched) watchedArr.push_back(id);
    snap["watched"] = watchedArr;
    json pendingArr = json::array();
    for (auto& id : m_watched) if (!state["forms"].contains(id)) pendingArr.push_back(id);
    snap["pendingForms"] = pendingArr;
    json hiddenArr = json::array(); for (auto& id : m_hidden) hiddenArr.push_back(id);
    snap["hidden"] = hiddenArr;
    json draftsArr = json::array(); for (auto& kv : m_drafts) draftsArr.push_back(kv.second);
    snap["drafts"] = draftsArr;
    json subArr = json::array(); for (auto& id : m_mySubmissions) subArr.push_back(id);
    snap["mySubmissions"] = subArr;
    snap["diagnostics"] = json({
        {"rxRaw", m_rxRaw}, {"rxSeen", m_rxSeen}, {"rxNew", m_rxNew}, {"rxDup", m_rxDup},
        {"txTotal", m_txTotal}, {"admDropSig", m_admDropSig}, {"admDropType", m_admDropType},
        {"rbsrRx", m_rbsrRx}, {"legacyReseeds", m_legacyReseeds},
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

// ── decrypt (per-form keys) ──────────────────────────────────────────────────────
// Decrypt + interpret the response pool for me as creator. One place for the open/verify
// hooks shared by snapshot, getDecryptedResponses, exportCsv, confirm. Each of my forms is
// sealed to its OWN key (derived from the identity; legacy forms: the identity key). A blob
// doesn't say which form it answers (that would publish per-form answer counts), so it is
// trial-opened against my keys; results are cached and a miss is retried only when the key
// set grows. The key that opens a blob must be the sealing key of the form it claims.
OrderedJson WhisperboxCoreImpl::decryptView(const OrderedJson& state) {
    std::map<std::string, const whisperbox::SignId*> keys; // sealing pubHex -> key
    if (state.contains("forms")) for (auto it = state["forms"].begin(); it != state["forms"].end(); ++it) {
        const auto& f = it.value();
        if (f.value("creator", "") != m_signId.address) continue;
        const std::string pub = f.value("publicKey", "");
        if (pub.empty()) continue;
        if (pub == m_signId.pubHex) { keys[pub] = &m_signId; continue; }
        auto c = m_formKeyCache.find(it.key());
        if (c == m_formKeyCache.end()) c = m_formKeyCache.emplace(it.key(), whisperbox::deriveFormKey(m_signId, it.key())).first;
        if (c->second.valid && c->second.pubHex == pub) keys[pub] = &c->second;
    }
    auto open = [&](const std::string& hexBlob) -> json {
        auto c = m_openCache.find(hexBlob);
        if (c != m_openCache.end() && (!c->second.dec.is_null() || c->second.nKeys == keys.size())) return c->second.dec;
        json dec;
        const whisperbox::Bytes blob = whisperbox::fromHex(hexBlob);
        for (const auto& kv : keys) {
            whisperbox::Bytes pt;
            try { pt = whisperbox::eciesOpen(kv.second->priv, blob); } catch (...) { continue; }
            try { dec = json::parse(std::string(pt.begin(), pt.end())); } catch (...) { dec = json(); break; }
            const std::string fid = dec.is_object() ? lc(dec.value("formId", "")) : "";
            if (fid.empty() || !state["forms"].contains(fid) || state["forms"][fid].value("publicKey", "") != kv.first) dec = json();
            break;
        }
        m_openCache[hexBlob] = Opened{dec, keys.size()};
        return dec;
    };
    return whisperbox::creatorView(state, m_signId.address, open, verifyInnerResponse);
}

// ── create / edit ───────────────────────────────────────────────────────────────
// The definition fields a creator sets on publish and may change with form.update
// (the fold normalizes them the same way: whisperbox_engine.hpp applyEditableFields).
static OrderedJson editableFromDef(const json& def) {
    OrderedJson p = OrderedJson::object();
    p["title"] = def.contains("title") && def["title"].is_string() ? def["title"].get<std::string>() : std::string();
    p["description"] = def.contains("description") && def["description"].is_string() ? def["description"].get<std::string>() : std::string();
    p["expiresAt"] = def.contains("expiresAt") && def["expiresAt"].is_number() ? def["expiresAt"] : json(nullptr);
    p["questions"] = def.contains("questions") && def["questions"].is_array() ? def["questions"] : json::array();
    p["whitelist"] = def.contains("whitelist") && def["whitelist"].is_object() ? def["whitelist"] : json({{"type", "none"}, {"value", ""}});
    if (def.contains("maxResponses") && def["maxResponses"].is_number_integer() && def["maxResponses"].get<long long>() > 0) p["maxResponses"] = def["maxResponses"];
    if (def.value("showResponseCount", false) == true) p["showResponseCount"] = true;
    if (def.contains("thankYou") && def["thankYou"].is_string() && !def["thankYou"].get<std::string>().empty()) p["thankYou"] = def["thankYou"];
    if (def.value("shuffleQuestions", false) == true) p["shuffleQuestions"] = true;
    if (def.value("allowEdits", false) == true) {
        p["allowEdits"] = true;
        p["editWindowMinutes"] = def.contains("editWindowMinutes") && def["editWindowMinutes"].is_number_integer() && def["editWindowMinutes"].get<long long>() > 0 ? def["editWindowMinutes"] : json(15);
    }
    return p;
}

// Edit a published form (creator). The full new definition replaces the old one on every
// device (latest update wins); id / creator / key / creation time never change. Keep the
// ids of existing questions - answers are stored by question id.
std::string WhisperboxCoreImpl::updateForm(std::string formId, std::string defJson) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(trim(formId));
    json def;
    try { def = json::parse(trim(defJson)); } catch (...) { out["ok"] = false; out["error"] = "bad defJson"; return out.dump(); }
    if (!def.is_object()) { out["ok"] = false; out["error"] = "def must be an object"; return out.dump(); }
    if (def.contains("questions") && !def["questions"].is_array()) { out["ok"] = false; out["error"] = "questions must be an array"; return out.dump(); }
    OrderedJson state = whisperbox::computeState(m_log, m_signId.address, nullptr, m_pinned);
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (state["forms"][formId]["creator"].get<std::string>() != m_signId.address) { out["ok"] = false; out["error"] = "not the creator"; return out.dump(); }
    OrderedJson p = OrderedJson::object();
    p["formId"] = formId; p["author"] = m_signId.address; p["form"] = editableFromDef(def);
    json e = buildEvent(whisperbox::FORM_UPDATE, whisperbox::formUpdateId(formId, randomHex(6)), p, /*sign=*/true);
    adoptLocal(e); broadcastEvent(e); publishState();
    out["ok"] = true; out["formId"] = formId;
    return out.dump();
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
    p["creator"] = m_signId.address;
    // Sealing key = this form's OWN key, derived from the identity (whisperbox_identity.hpp).
    p["publicKey"] = whisperbox::deriveFormKey(m_signId, formId).pubHex;
    p["createdAt"] = nowMs();
    OrderedJson ed = editableFromDef(def);
    for (auto it = ed.begin(); it != ed.end(); ++it) p[it.key()] = it.value();

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
    OrderedJson state = whisperbox::computeState(m_log, m_signId.address, nullptr, m_pinned);
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (state["forms"][formId]["creator"].get<std::string>() != m_signId.address) { out["ok"] = false; out["error"] = "not the creator"; return out.dump(); }

    OrderedJson p = OrderedJson::object();
    p["formId"] = formId;
    p["expiresAt"] = nullptr;
    p["author"] = m_signId.address;
    json e = buildEvent(FORM_CLOSE, whisperbox::formCloseId(formId, randomHex(6)), p, /*sign=*/true);
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
    OrderedJson state = whisperbox::computeState(m_log, m_signId.address, nullptr, m_pinned);
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (state["forms"][formId]["creator"].get<std::string>() != m_signId.address) { out["ok"] = false; out["error"] = "not the creator"; return out.dump(); }

    // The receipt id is the one the respondent SEALED inside its response (random,
    // unlinkable); legacy responses fall back to the old (form, respondent) hash.
    // Same id every time -> re-confirmation is idempotent under union-by-id.
    OrderedJson cv = decryptView(state);
    std::string confirmationId;
    if (cv["responses"].contains(formId))
        for (const auto& r : cv["responses"][formId])
            if (lc(r.value("respondent", "")) == respondentAddr) { confirmationId = confirmIdOf(json::parse(r.dump()), formId); break; }
    if (confirmationId.empty()) { out["ok"] = false; out["error"] = "no decrypted response from that respondent"; return out.dump(); }

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

    OrderedJson state = whisperbox::computeState(m_log, m_signId.address, nullptr, m_pinned);
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    const auto& f = state["forms"][formId];
    if (f["status"].get<std::string>() != "open") { out["ok"] = false; out["error"] = "form is closed"; return out.dump(); }
    if (f.contains("expiresAt") && f["expiresAt"].is_number() && nowMs() > f["expiresAt"].get<long long>()) { out["ok"] = false; out["error"] = "this form closed at its end date"; return out.dump(); }
    // Answer edits: the same respondent may resubmit while the form allows it - within the
    // edit window after the FIRST answer and before the creator's receipt (the creator's
    // view enforces the same rule on every replica; this just refuses early).
    const bool allowEdits = f.contains("allowEdits") && f["allowEdits"].is_boolean() && f["allowEdits"].get<bool>();
    bool isEdit = false;
    long long firstAt = 0;
    if (m_mySubmissions.count(formId)) {
        if (!allowEdits) { out["ok"] = false; out["error"] = "you already answered this form"; return out.dump(); }
        firstAt = m_myAnswers.count(formId) ? m_myAnswers[formId].value("firstSubmittedAt", m_myAnswers[formId].value("submittedAt", 0LL)) : 0;
        const long long win = (f["editWindowMinutes"].is_number() ? f["editWindowMinutes"].get<long long>() : 15) * 60000LL;
        const std::string cid0 = m_myConfirmIds.count(formId) ? m_myConfirmIds[formId] : std::string();
        if (!cid0.empty() && containsStr(f["confirmations"], cid0)) { out["ok"] = false; out["error"] = "the creator already sent you a receipt - your answer is final"; return out.dump(); }
        if (firstAt <= 0 || nowMs() - firstAt > win) { out["ok"] = false; out["error"] = "the time to edit your answer is over"; return out.dump(); }
        isEdit = true;
    }
    {
        const std::string creator = f["creator"].get<std::string>();
        const std::string pin = m_pinned.count(formId) ? m_pinned[formId] : std::string();
        const bool contested = f.contains("contested") && f["contested"].is_boolean() && f["contested"].get<bool>();
        if (!pin.empty() && pin != creator) { out["ok"] = false; out["error"] = "this form's creator doesn't match the link you opened - refusing to send answers"; return out.dump(); }
        if (contested && pin != creator) { out["ok"] = false; out["error"] = "two different people published a form with this id - open it from the creator's link to answer"; return out.dump(); }
    }
    if (!f["publicKey"].is_string() || f["publicKey"].get<std::string>().empty()) { out["ok"] = false; out["error"] = "form not synced yet - try again in a moment"; return out.dump(); }
    {
        std::string wl = f["whitelist"].is_object() ? f["whitelist"].value("type", "none") : "none";
        if (wl == "addresses") {
            auto list = whisperbox::whitelistAddresses(f["whitelist"]);
            if (std::find(list.begin(), list.end(), m_signId.address) == list.end()) { out["ok"] = false; out["error"] = "this form only accepts listed addresses"; return out.dump(); }
        } else if (wl != "none") { out["ok"] = false; out["error"] = "whitelist type '" + wl + "' is not supported"; return out.dump(); }
    }
    {   // every answer must fit its question (types, ranges, required) - the creator can't ask again
        std::map<std::string, json> byQ;
        for (const auto& a : answers) if (a.is_object()) byQ[a.value("questionId", "")] = a.contains("value") ? a["value"] : json();
        for (const auto& q : f["questions"]) {
            auto it = byQ.find(q.value("id", ""));
            std::string e = whisperbox::validateAnswer(json::parse(q.dump()), it == byQ.end() ? json() : it->second);
            if (!e.empty()) { out["ok"] = false; out["error"] = q.value("text", q.value("id", "")) + ": " + e; return out.dump(); }
        }
    }

    // The FULL response JSON is sealed to the creator — nothing appears in plaintext.
    long long submittedAt = nowMs();
    OrderedJson resp = OrderedJson::object();
    resp["formId"] = formId;
    resp["respondent"] = m_signId.address;
    resp["submittedAt"] = submittedAt;
    resp["answers"] = answers;
    // Random receipt id, sealed: the creator echoes it publicly on confirm; only
    // this device (which keeps it) can tell the receipt is its own.
    // an edit keeps the original receipt id (a receipt locks "this person's answer")
    const std::string confirmationId = isEdit && m_myConfirmIds.count(formId) ? m_myConfirmIds[formId] : randomHex(8);
    resp["confirmationId"] = confirmationId;
    std::string wlType = f["whitelist"].value("type", "none");
    if (wlType != "none" || allowEdits) {   // editable forms: signed, so nobody can "edit" someone else's answer
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
        m_mySubmissions.insert(formId);   // local, private: "I already answered this"
        m_myConfirmIds[formId] = confirmationId;
        saveMySubmissions();
        m_myAnswers[formId] = json({{"answers", answers}, {"submittedAt", submittedAt}, {"firstSubmittedAt", isEdit ? firstAt : submittedAt}});
        saveMyAnswers();
        if (m_answerDrafts.erase(formId)) saveDrafts();
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
    OrderedJson state = whisperbox::computeState(m_log, m_signId.address, nullptr, m_pinned);
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (state["forms"][formId]["creator"].get<std::string>() != m_signId.address) { out["ok"] = false; out["error"] = "not the creator"; return out.dump(); }

    OrderedJson view = decryptView(state);
    if (view["responses"].contains(formId))
        for (auto& r : view["responses"][formId]) r["confirmed"] = containsStr(state["forms"][formId]["confirmations"], confirmIdOf(json::parse(r.dump()), formId));
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
    m_mySubmissions.erase(formId);
    saveMySubmissions();
    m_myAnswers.erase(formId);
    saveMyAnswers();
    publishState();
    json out = {{"ok", true}, {"formId", formId}};
    return out.dump();
}

// Hide a form from my lists (any form: mine, answered, opened). Local only - the form
// stays in the shared log, my keys and answers stay, and unhideForm brings it back.
std::string WhisperboxCoreImpl::hideForm(std::string formId) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    formId = lc(trim(formId));
    if (formId.empty()) return json({{"ok", false}, {"error", "formId required"}}).dump();
    m_hidden.insert(formId);
    saveHidden();
    publishState();
    return json({{"ok", true}, {"formId", formId}}).dump();
}
// Re-open a closed form (creator). Answers sealed while it was closed stay dropped.
std::string WhisperboxCoreImpl::reopenForm(std::string formId) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(trim(formId));
    OrderedJson state = whisperbox::computeState(m_log, m_signId.address, nullptr, m_pinned);
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    const auto& f = state["forms"][formId];
    if (f["creator"].get<std::string>() != m_signId.address) { out["ok"] = false; out["error"] = "not the creator"; return out.dump(); }
    if (f["status"].get<std::string>() == "open") { out["ok"] = false; out["error"] = "form is already open"; return out.dump(); }
    if (f.contains("expiresAt") && f["expiresAt"].is_number() && nowMs() > f["expiresAt"].get<long long>()) { out["ok"] = false; out["error"] = "its end date has passed - duplicate it as a new form"; return out.dump(); }
    if (f.contains("maxResponses") && f["maxResponses"].is_number()) {
        OrderedJson cv = decryptView(state);
        if (cv["responses"].contains(formId) && (long long)cv["responses"][formId].size() >= f["maxResponses"].get<long long>()) {
            out["ok"] = false; out["error"] = "it reached its answer limit - duplicate it as a new form"; return out.dump(); }
    }
    OrderedJson p = OrderedJson::object();
    p["formId"] = formId; p["author"] = m_signId.address;
    json e = buildEvent(whisperbox::FORM_REOPEN, whisperbox::formReopenId(formId, randomHex(6)), p, /*sign=*/true);
    adoptLocal(e); broadcastEvent(e); publishState();
    out["ok"] = true; out["formId"] = formId;
    return out.dump();
}

// Receipts for every decrypted, not-yet-confirmed response of a form, as few events as
// possible (100 receipt ids per event keeps each well inside one message).
std::string WhisperboxCoreImpl::confirmAll(std::string formId) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(trim(formId));
    OrderedJson state = whisperbox::computeState(m_log, m_signId.address, nullptr, m_pinned);
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (state["forms"][formId]["creator"].get<std::string>() != m_signId.address) { out["ok"] = false; out["error"] = "not the creator"; return out.dump(); }
    OrderedJson cv = decryptView(state);
    const json confs = json::parse(state["forms"][formId]["confirmations"].dump());
    std::vector<std::string> todo;
    if (cv["responses"].contains(formId))
        for (const auto& r : cv["responses"][formId]) {
            std::string cid = confirmIdOf(json::parse(r.dump()), formId);
            if (!cid.empty() && !containsStr(confs, cid)) todo.push_back(cid);
        }
    int events = 0;
    for (size_t i = 0; i < todo.size(); i += 100) {
        std::vector<std::string> chunk(todo.begin() + i, todo.begin() + std::min(todo.size(), i + 100));
        OrderedJson p = OrderedJson::object();
        p["formId"] = formId; p["confirmationIds"] = chunk; p["author"] = m_signId.address;
        json e = buildEvent(RESPONSE_CONFIRM, whisperbox::responseConfirmBatchId(formId, chunk), p, /*sign=*/true);
        adoptLocal(e); broadcastEvent(e); events++;
    }
    if (events) publishState();
    out["ok"] = true; out["formId"] = formId; out["confirmed"] = (int)todo.size(); out["events"] = events;
    return out.dump();
}

std::string WhisperboxCoreImpl::setAutoReceipts(std::string formId, std::string on) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    formId = lc(trim(formId));
    const bool enable = trim(on) == "1" || trim(on) == "true";
    if (enable) m_autoReceipts.insert(formId); else m_autoReceipts.erase(formId);
    saveDrafts();
    publishState();
    if (enable) confirmAll(formId);   // catch up on what's already in
    return json({{"ok", true}, {"formId", formId}, {"autoReceipts", enable}}).dump();
}

// Form drafts: {id?, def, publishAt?(ms|null)}. Saved locally only; publishDraft (or the
// scheduler, once publishAt has passed and the node is up) turns one into a real form.
std::string WhisperboxCoreImpl::saveDraft(std::string draftJson) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json d;
    try { d = json::parse(trim(draftJson)); } catch (...) { return json({{"ok", false}, {"error", "bad draftJson"}}).dump(); }
    if (!d.is_object() || !d.contains("def") || !d["def"].is_object()) return json({{"ok", false}, {"error", "draft needs a def object"}}).dump();
    std::string id = d.value("id", "");
    if (id.empty()) id = "draft-" + randomHex(4);
    json rec = {{"id", id}, {"def", d["def"]}, {"updatedAt", nowMs()},
                {"publishAt", d.contains("publishAt") && d["publishAt"].is_number() ? d["publishAt"] : json(nullptr)}};
    m_drafts[id] = rec;
    saveDrafts();
    publishState();
    return json({{"ok", true}, {"draftId", id}}).dump();
}
std::string WhisperboxCoreImpl::deleteDraft(std::string draftId) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    m_drafts.erase(trim(draftId));
    saveDrafts();
    publishState();
    return json({{"ok", true}}).dump();
}
std::string WhisperboxCoreImpl::publishDraft(std::string draftId) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    return publishDraftLocked(trim(draftId));
}
std::string WhisperboxCoreImpl::publishDraftLocked(const std::string& draftId) {
    auto it = m_drafts.find(draftId);
    if (it == m_drafts.end()) return json({{"ok", false}, {"error", "unknown draft"}}).dump();
    json r = json::parse(createForm(it->second["def"].dump()));
    if (r.value("ok", false)) { m_drafts.erase(draftId); saveDrafts(); publishState(); }
    return r.dump();
}
// Half-filled answers for a form, restored when it is opened again. "" / [] clears.
std::string WhisperboxCoreImpl::saveAnswerDraft(std::string formId, std::string answersJson) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    formId = lc(trim(formId));
    json a;
    try { a = trim(answersJson).empty() ? json::array() : json::parse(trim(answersJson)); } catch (...) { return json({{"ok", false}, {"error", "bad answersJson"}}).dump(); }
    if (!a.is_array() || a.empty()) m_answerDrafts.erase(formId); else m_answerDrafts[formId] = a;
    saveDrafts();
    return json({{"ok", true}}).dump();   // no publishState: called while typing
}

// Every 5 s while online: publish due scheduled drafts, close my forms at their cap or end
// date, send receipts for forms with automatic receipts.
void WhisperboxCoreImpl::housekeeping() {
    if (!m_nodeReady || !m_signId.valid) return;
    std::vector<std::string> due;
    for (auto& kv : m_drafts) if (kv.second.contains("publishAt") && kv.second["publishAt"].is_number() && kv.second["publishAt"].get<long long>() <= nowMs()) due.push_back(kv.first);
    for (auto& id : due) { json r = json::parse(publishDraftLocked(id)); fprintf(stderr, "WHISPERBOX scheduled draft %s -> %s\n", id.c_str(), r.dump().c_str()); }

    OrderedJson state = whisperbox::computeState(m_log, m_signId.address, nullptr, m_pinned);
    bool anyMine = false;
    for (auto it = state["forms"].begin(); it != state["forms"].end(); ++it) if (it.value()["creator"].get<std::string>() == m_signId.address) { anyMine = true; break; }
    if (!anyMine) return;
    OrderedJson cv = decryptView(state);
    for (auto it = state["forms"].begin(); it != state["forms"].end(); ++it) {
        const auto& f = it.value();
        if (f["creator"].get<std::string>() != m_signId.address) continue;
        const std::string fid = it.key();
        if (f["status"].get<std::string>() == "open") {
            size_t n = cv["responses"].contains(fid) ? cv["responses"][fid].size() : 0;
            bool full = f.contains("maxResponses") && f["maxResponses"].is_number() && (long long)n >= f["maxResponses"].get<long long>();
            bool ended = f.contains("expiresAt") && f["expiresAt"].is_number() && nowMs() > f["expiresAt"].get<long long>();
            if (full || ended) { closeForm(fid); fprintf(stderr, "WHISPERBOX auto-closed %s (%s)\n", fid.c_str(), full ? "answer cap" : "end date"); }
        }
        if (m_autoReceipts.count(fid) && cv["responses"].contains(fid)) {
            const json confs = json::parse(f["confirmations"].dump());
            for (const auto& r : cv["responses"][fid])
                if (!containsStr(confs, confirmIdOf(json::parse(r.dump()), fid))) { confirmAll(fid); break; }
        }
    }
}

std::string WhisperboxCoreImpl::unhideForm(std::string formId) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    formId = lc(trim(formId));
    m_hidden.erase(formId);
    saveHidden();
    publishState();
    return json({{"ok", true}, {"formId", formId}}).dump();
}

std::string WhisperboxCoreImpl::importIdentity(std::string privHex) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!isHex(trim(privHex), 64)) { out["ok"] = false; out["error"] = "privHex must be 64 hex chars"; return out.dump(); }
    m_signId = whisperbox::identityFromPriv(whisperbox::fromHex(trim(privHex)));
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "invalid scalar (0, >= n, or bad point)"; return out.dump(); }
    m_formKeyCache.clear(); m_openCache.clear(); // keys derive from the identity
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
    writeAtomic(m_dataDir + "/device_id.txt", m_deviceId);
    json out = {{"ok", true}, {"deviceId", m_deviceId}};
    return out.dump();
}

std::string WhisperboxCoreImpl::shareUri(std::string formId) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    formId = lc(formId);
    OrderedJson state = whisperbox::computeState(m_log, m_signId.valid ? m_signId.address : "", nullptr, m_pinned);
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
    // Short share URI: form id only. The canonical signed FORM_PUBLISH event
    // carries the full def over Waku (public topic, re-broadcast + catchup); the
    // importer adopts by id optimistically and fills in when sync lands. Keeps
    // the QR at version 1-2 (scannable) instead of embedding the whole def.
    std::string uri = "whisperbox://form?id=" + formId + "&by=" + f["creator"].get<std::string>();
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
    std::string input = trim(defJson);
    if (input.rfind("whisperbox://", 0) == 0) {
        // URI forms: short "whisperbox://form?id=<id>" (def arrives via Waku sync)
        // or legacy "whisperbox://form?<b64-def>" (full def embedded). Legacy b64
        // of a JSON object always starts with 'e', so the "id=" prefix is unambiguous.
        size_t q = input.find('?');
        std::string query = (q != std::string::npos) ? input.substr(q + 1) : "";
        if (query.rfind("id=", 0) == 0) {
            // "id=<form>[&by=<creator address>]" - `by` pins the creator the link came from.
            def = json::object();
            size_t pos = 0;
            while (pos <= query.size()) {
                size_t amp = query.find('&', pos);
                std::string kv = query.substr(pos, amp == std::string::npos ? std::string::npos : amp - pos);
                size_t eq = kv.find('=');
                if (eq != std::string::npos) {
                    std::string k = kv.substr(0, eq), v = trim(kv.substr(eq + 1));
                    if (k == "id") def["id"] = v;
                    else if (k == "by") def["creator"] = v;
                }
                if (amp == std::string::npos) break;
                pos = amp + 1;
            }
        } else {
            try { def = json::parse(whisperbox::b64decode(query)); }
            catch (...) { out["ok"] = false; out["error"] = "bad URI payload"; return out.dump(); }
        }
    } else {
        try { def = json::parse(input); }
        catch (...) { out["ok"] = false; out["error"] = "bad defJson"; return out.dump(); }
    }
    if (!def.is_object() || !def.contains("id")) {
        out["ok"] = false; out["error"] = "def must include id (use shareUri output)"; return out.dump();
    }
    // publicKey is optional: short-URI imports get it from the canonical event.
    std::string formId = lc(def.value("id", ""));
    if (formId.empty()) { out["ok"] = false; out["error"] = "missing id"; return out.dump(); }

    // No local placeholder event: an unsigned form.publish with the canonical id
    // would shadow the creator's signed event forever (union-by-id keeps the first
    // copy). Watch the id and pull; the view shows it as pending until it lands.
    OrderedJson state = whisperbox::computeState(m_log, m_signId.valid ? m_signId.address : "", nullptr, m_pinned);
    const bool have = state["forms"].contains(formId);
    if (!have && m_nodeReady) { requestSync(); catchupRound(); }
    m_watched.insert(formId);
    saveWatched();
    // Pin the creator the link vouches for: answers will only ever be sealed to a form
    // whose (signed) creator matches it - protects against form-id squatting.
    std::string by = lc(def.value("creator", ""));
    if (by.size() == 42 && by.rfind("0x", 0) == 0) { m_pinned[formId] = by; savePins(); }
    publishState();
    out["ok"] = true; out["formId"] = formId; out["pending"] = !have;
    return out.dump();
}

std::string WhisperboxCoreImpl::exportCsv(std::string formId) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(formId);
    OrderedJson state = whisperbox::computeState(m_log, m_signId.address, nullptr, m_pinned);
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (state["forms"][formId]["creator"].get<std::string>() != m_signId.address) { out["ok"] = false; out["error"] = "not the creator"; return out.dump(); }

    OrderedJson view = decryptView(state);

    auto csvCell = [](const std::string& v) {
        if (v.find_first_of(",\"\r\n") != std::string::npos) {
            std::string o = "\""; for (char c : v) { if (c == '"') o += "\"\""; else o += c; } return o + "\"";
        }
        return v;
    };
    // Choice answers travel as option INDICES (hub + every view); render the
    // option text so the spreadsheet is readable. Checkbox -> "a; b".
    auto cellOf = [](const json& q, const json& v) -> std::string {
        const json opts = q.contains("options") && q["options"].is_array() ? q["options"] : json::array();
        auto one = [&opts](const json& x) -> std::string {
            if (x.is_number_integer()) {
                long long k = x.get<long long>();
                if (k >= 0 && k < (long long)opts.size() && opts[k].is_string()) return opts[k].get<std::string>();
            }
            if (x.is_string()) return x.get<std::string>();
            if (x.is_boolean()) return x.get<bool>() ? "Yes" : "No";   // yes/no question
            if (x.is_object() && x.contains("other") && x["other"].is_string()) return "Other: " + x["other"].get<std::string>();
            if (x.is_number_float() && x.get<double>() == std::floor(x.get<double>())) return std::to_string((long long)x.get<double>());
            return x.is_null() ? "" : x.dump();
        };
        if (v.is_array()) {
            std::string o;
            for (const auto& x : v) { if (!o.empty()) o += "; "; o += one(x); }
            return o;
        }
        return one(v);
    };
    const auto& f = state["forms"][formId];
    const json confs = f["confirmations"];
    std::vector<std::string> header = {"respondent", "submittedAt", "confirmed"};
    std::vector<json> qs;
    for (const auto& q : f["questions"]) { header.push_back(q.value("text", q.value("id", ""))); qs.push_back(json::parse(q.dump())); }
    auto line = [&](const std::vector<std::string>& cells) {
        std::string l; for (size_t k = 0; k < cells.size(); ++k) { if (k) l += ","; l += csvCell(cells[k]); } return l + "\n";
    };
    std::string csv = line(header);
    if (view["responses"].contains(formId)) {
        for (const auto& ro : view["responses"][formId]) {
            json r = json::parse(ro.dump());
            std::map<std::string, json> byQ;
            for (const auto& a : r["answers"]) if (a.is_object()) byQ[a.value("questionId", "")] = a.contains("value") ? a["value"] : json();
            std::vector<std::string> row = {r.value("respondent", ""),
                isoUtc(r.contains("submittedAt") && r["submittedAt"].is_number() ? r["submittedAt"].get<long long>() : 0),
                containsStr(confs, confirmIdOf(r, formId)) ? "yes" : "no"};
            for (const auto& q : qs) { std::string qid = q.value("id", ""); row.push_back(byQ.count(qid) ? cellOf(q, byQ[qid]) : ""); }
            csv += line(row);
        }
    }
    out["ok"] = true; out["csv"] = csv;
    return out.dump();
}

std::string WhisperboxCoreImpl::resync() {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    if (!m_nodeReady) { json o = {{"ok", false}, {"error", "node not ready"}}; return o.dump(); }
    // Ask peers for state AND re-serve ours (idempotent both ways).
    requestSync();
    catchupRound();
    publishState();
    json out = {{"ok", true}, {"logSize", (int)m_log.size()}};
    return out.dump();
}
