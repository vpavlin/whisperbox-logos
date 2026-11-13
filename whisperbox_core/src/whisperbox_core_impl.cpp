// WhisperboxCoreImpl implementation. Engine/crypto/wire are the std-only headers
// (whisperbox_engine.hpp etc., byte-parity with the TS reference). This file wires
// the mutation API + the loam_core transport (reliable channels over Waku, BLE) over ONE
// shared topic, routing incoming envelopes into the single merged log.
//
// Every delivery call is async / fire-and-forget (a synchronous send on the
// event-loop thread freezes the module on the IPC timeout).
#include "whisperbox_core_impl.h"
#include "logos_sdk.h"   // umbrella: LogosModules + LogosMap(nlohmann::json) + StdLogosResult
#include "logos_lp_client.h"          // RAW delivery_module events (the generated binding zeroes payloads)
#include "loam/delivery_transport.hpp" // Loam's delivery wire, vendored (ADR 0021; src/loam/VENDORED.md)

// delivery_module directly, without loam_core (ADR 0021). Same wire as loam_core and the phones.
struct WhisperboxCoreImpl::Direct {
    std::unique_ptr<logos::LpClient> raw;
    std::vector<logos::LpSubscription> subs;
    std::unique_ptr<loam::delivery::DeliveryTransport<LogosMap>> t;
};
#include "qrcodegen.hpp"
#include "whisperbox_rbsr.hpp"   // catch-up (RBSR v2) over an index, same messages as logos_sync/catchup.hpp
#include "logos_sync/catchup.hpp"   // loam-sync RBSR catch-up (fp/ids/need) - replaces the whole-log reseed  // vendored Nayuki QR encoder (host qr core unreachable from a pure-QML view)
#include <QTimer>
#include <openssl/sha.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cctype>
#include <fstream>
#include <regex>
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

// ── wire v2 helpers (ADR 0024) ──
static const char* kWireShard = "/waku/2/rs/2/1";
static std::string formTopic(const std::string& formId) {
    const std::string in = "whisperbox.bucket.v2" + formId;
    whisperbox::Bytes h = whisperbox::sha256(whisperbox::Bytes(in.begin(), in.end()));
    return std::string("/whisperbox/2/form-") + "0123456789abcdef"[h[0] >> 4] + "/proto";
}
static bool isWireTopic(const std::string& t) { return t.rfind("/whisperbox/2/form-", 0) == 0; }
static long long envLL(const char* name, long long def) {
    if (const char* v = std::getenv(name)) { char* end = nullptr; long long x = std::strtoll(v, &end, 10); if (end && *end == 0 && x > 0) return x; }
    return def;
}
// the form an event belongs to (an answer's form is sealed: its sender knows it, nobody else)
static std::string formIdOf(const json& e) {
    if (!e.contains("payload") || !e["payload"].is_object()) return "";
    const json& p = e["payload"];
    if (e.value("type", "") == whisperbox::FORM_PUBLISH) return lc(p.value("id", ""));
    return lc(p.value("formId", ""));
}

using whisperbox::FORM_PUBLISH;
using whisperbox::RESPONSE_SUBMIT;
using whisperbox::RESPONSE_CONFIRM;
using whisperbox::FORM_CLOSE;

static long long nowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
}
// A frame's network timestamp (ns, as loam_core passes it) in ms, or 0. The sender's node sets it, so
// it is only taken within kMaxClockLeadMs of when we receive the copy, either way: an older one (a
// store copy, or a node stamping 2001) proves nothing and is treated as absent (open-review
// 2026-11-01, FR-6; mirror client.mjs netMsOf).
static long long netMsOf(long long tsNs, long long now, bool fromStore = false) {
    if (tsNs <= 1000000000000000LL) return 0;
    const long long ms = tsNs / 1000000LL;
    if (ms <= 1000000000000LL || ms > now + whisperbox::kMaxClockLeadMs) return 0;
    // A Store copy carries the message's network timestamp from when it was published: that is the
    // time deadlines and closes are judged by, not the sender's own clock in the payload (Václav,
    // 2026-11-13; audit W2-11). A live frame's must be about now.
    if (!fromStore && ms < now - whisperbox::kMaxClockLeadMs) return 0;
    return ms;
}
static std::string trim(const std::string& s) {
    size_t a = s.find_first_not_of(" \t\r\n"); if (a == std::string::npos) return "";
    size_t b = s.find_last_not_of(" \t\r\n"); return s.substr(a, b - a + 1);
}
// JSON that isn't ours (a decrypted answer, reply or quiz key, a link, a caller's argument): parsed
// with the depth and size limit, throwing like json::parse. A response sealed to a form's PUBLIC key
// with 50,000 nested arrays inside crashed the creator's core when it decrypted it (open-review
// 2026-10-30, FR-1): the frame limit only covers the envelope, not what's sealed inside it.
static json parseUntrusted(const std::string& text, size_t maxBytes = whisperbox::kMaxEventBytes) {
    json j = whisperbox::parseLimited(text, whisperbox::kMaxJsonDepth, maxBytes);
    if (j.is_null()) throw std::runtime_error("bad, oversized or too deeply nested JSON");
    return j;
}
static constexpr size_t kMaxLocalJson = 4u << 20;   // a definition or answers from the view/hub
// The log's caps (open-review 2026-11-01, FR-3): answers stop being taken from the network at either;
// forms, closes and receipts (signed) keep a reserve above the byte cap.
static constexpr size_t kMaxLogResponses = 50000;
static constexpr size_t kMaxLogBytes = size_t(256) << 20;
static constexpr size_t kLogReserveBytes = size_t(32) << 20;
// Local lists any module can add to: bounded (open-review 2026-11-03, FR-14)
static constexpr size_t kMaxDrafts = 200, kMaxAnswerDrafts = 1000, kMaxWatched = 10000, kMaxHidden = 10000, kMaxDraftTrash = 20;
static constexpr size_t kMaxDraftsBytes = size_t(16) << 20;
// Our own persisted files get the same depth limit as the network (a corrupt or planted 50k-deep
// drafts.json used to overflow the parser on every start): a generous size, throws when unreadable
// (open-review 2026-11-01, FR-11).
static json parseFile(std::istream& in) {
    json j = whisperbox::parseLimited(std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>()),
                                      whisperbox::kMaxJsonDepth + 2, size_t(256) << 20);
    if (j.is_null()) throw std::runtime_error("unreadable or nested too deep");
    return j;
}

static bool isHex(const std::string& s, size_t len) {
    if (s.size() != len) return false;
    for (char c : s) if (!std::isxdigit((unsigned char)c)) return false;
    return true;
}

// Crash-safe file write: write <path>.tmp, then rename over <path> (atomic on POSIX). A
// module killed mid-write (Basecamp quitting during sync) leaves the old file intact
// instead of a truncated one that the next start would read as corrupt.
// Owner-only: the data dir holds the identity's private key (every form key derives from it) and
// the respondent's own answers in plain text.
static constexpr std::filesystem::perms kPrivateFile = std::filesystem::perms::owner_read | std::filesystem::perms::owner_write;
static constexpr std::filesystem::perms kPrivateDir = std::filesystem::perms::owner_all;
static bool writeAtomic(const std::string& path, const std::string& content) {
    const std::string tmp = path + ".tmp";
    {
        std::ofstream f(tmp, std::ios::trunc | std::ios::binary);
        if (!f) return false;
        std::error_code ec;   // before the content goes in: no moment with a readable copy
        std::filesystem::permissions(tmp, kPrivateFile, std::filesystem::perm_options::replace, ec);
        f << content;
        f.flush();
        if (!f) return false;
    }
    return std::rename(tmp.c_str(), path.c_str()) == 0;
}
// Existing installs wrote everything 0644 (review 2026-10-22): tighten the dir and its files.
static void makePrivate(const std::string& dir) {
    std::error_code ec;
    std::filesystem::permissions(dir, kPrivateDir, std::filesystem::perm_options::replace, ec);
    for (const auto& de : std::filesystem::directory_iterator(dir, ec))
        if (de.is_regular_file(ec)) std::filesystem::permissions(de.path(), kPrivateFile, std::filesystem::perm_options::replace, ec);
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
static bool plausibleFormId(const std::string& id);
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
    std::string msg = "whisperbox-inner-v1|" + whisperbox::esJson(m);   // JSON.stringify, as the phones (FR-12)
    whisperbox::Bytes digest = whisperbox::sha256(whisperbox::Bytes(msg.begin(), msg.end()));
    if (!whisperbox::ecdsaVerify(whisperbox::fromHex(pubHex), digest, whisperbox::fromHex(sigHex))) return false;
    whisperbox::Bytes h = whisperbox::sha256(whisperbox::fromHex(pubHex));
    return ("0x" + whisperbox::toHex(h.data(), 32).substr(24, 40)) == lc(p.value("respondent", ""));
}
static std::string isoUtc(long long ms) {
    if (ms <= 0 || ms > 100000000000000LL) return "";   // gmtime fails past year ~5000 (a sealed, untrusted time)
    time_t t = (time_t)(ms / 1000); struct tm tmv; gmtime_r(&t, &tmv);
    char buf[32]; strftime(buf, sizeof buf, "%Y-%m-%dT%H:%M:%SZ", &tmv);
    return buf;
}

WhisperboxCoreImpl::~WhisperboxCoreImpl() {
    // loam_core keeps our onReceived / onStatusChanged and pending async callbacks after we go: they
    // reach us only through m_life, cleared here (open-review 2026-11-02, FR-8: use-after-free)
    if (m_life) { std::lock_guard<std::mutex> g(m_life->mu); m_life->self = nullptr; }
    m_direct.reset();   // unsubscribes the raw delivery events
    // Parentless QTimer (LogosModuleContext is NOT a QObject in this builder rev)
    // — stop + delete explicitly.
    if (m_flushTimer) { m_flushTimer->stop(); delete m_flushTimer; m_flushTimer = nullptr; }
    if (m_logDirty || !m_journalPending.empty()) flushLog();   // received events not saved yet
    if (m_netDirty) saveNetTimes();
    if (m_firstDirty) saveFirstSeen();
    if (m_draftsDirty) saveDrafts();
    if (m_hubTimer) { m_hubTimer->stop(); delete m_hubTimer; m_hubTimer = nullptr; }
}

// Received events are saved and published at most every 250 ms: a burst used to rewrite events.json
// and rebuild (decrypt) the whole view once per event (open-review 2026-11-01, FR-3). Local actions
// still save and publish at once.
void WhisperboxCoreImpl::scheduleFlush() {
    if (!m_flushTimer) {
        m_flushTimer = new QTimer();
        m_flushTimer->setSingleShot(true);
        m_flushTimer->setInterval(250);
        QObject::connect(m_flushTimer, &QTimer::timeout, [this] { std::lock_guard<std::recursive_mutex> lk(m_mtx); flushNow(); });
    }
    if (!m_flushTimer->isActive()) m_flushTimer->start();
}
void WhisperboxCoreImpl::flushNow() {
    if (m_logDirty) flushLog();
    if (m_netDirty) { m_netDirty = false; saveNetTimes(); }
    if (m_firstDirty) { m_firstDirty = false; saveFirstSeen(); }
    if (m_draftsDirty) saveDrafts();
    if (m_publishDirty) { m_publishDirty = false; publishState(); }
}

// ── lifecycle ────────────────────────────────────────────────────────────────────
void WhisperboxCoreImpl::onContextReady() {
    fprintf(stderr, "WHISPERBOX onContextReady enter\n");
    if (!m_life) { m_life = std::make_shared<Life>(); m_life->self = this; }
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
        static const std::regex devId("^[A-Za-z0-9_-]{1,64}$");   // FR-11: bounded, as peers check it
        if (d.empty() || d == "whisperbox-core" || !std::regex_match(d, devId)) {
            try { d = "wb-" + randomHex(6); } catch (...) { d = "wb-" + std::to_string(nowMs()); }
            writeAtomic(m_dataDir + "/device_id.txt", d);
        }
        m_deviceId = d;
    }
    fprintf(stderr, "WHISPERBOX deviceId=%s\n", m_deviceId.c_str());
    m_clock = whisperbox::Clock(m_deviceId);
    loadLog();
    fprintf(stderr, "WHISPERBOX log events=%zu\n", m_log.size());
    m_clock.primeFrom(m_log, nowMs() + whisperbox::kMaxClockLeadMs);
    loadWatched();
    loadMySubmissions();
    loadLocalPrefs();
    loadPins();
    loadPulls();
    pruneUnwanted();
    // Basecamp 0.3 rejects calls to other modules made inside onContextReady(): the hub tick
    // below starts the transport a second later.
    // Hub tick: retry node start until ready, then a rate-limited periodic seed so
    // late joiners on a sparse mesh still converge (idempotent — peers dedup by id).
    m_hubTimer = new QTimer();
    QObject::connect(m_hubTimer, &QTimer::timeout, [this] {
        std::lock_guard<std::recursive_mutex> lk(m_mtx);
        if (m_via == Via::Direct) directTick();
        if (!m_nodeReady) {
            if (m_via == Via::Unknown) { probeTransport(); return; }
            if (m_via == Via::Direct) { bootstrapDirect(); return; }
            bootstrapDelivery();
            if (m_deliveryStarting && nowMs() - m_lastStatusPollMs >= 3000) {
                m_lastStatusPollMs = nowMs();
                auto life = m_life;
                try { modules().loam_core.statusAsync([life](std::string st) { withSelf(life, [st](WhisperboxCoreImpl* self) { self->onTransportStatus(st); }); }); } catch (...) {}
            }
        } else {
            // wire v2 (ADR 0024): no catch-up rounds; the queue drains within the RLN budget
            drainSendQueue();
            if (nowMs() - m_lastHousekeepMs >= std::min<long long>(5000, envLL("WHISPERBOX_MINUTE_MS", 60000) / 12)) { m_lastHousekeepMs = nowMs(); housekeeping(); wireSchedule(); }
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

// ── data dir + persistence ($WHISPERBOX_CORE_DATA > Basecamp's module folder > ~/.whisperbox-core) ──
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
// Copy every regular file of an old data folder into the new one (never overwriting): the old
// folder stays as it was, as a backup.
static void copyDataFiles(const std::string& from, const std::string& to) {
    std::error_code ec;
    for (const auto& de : std::filesystem::directory_iterator(from, ec)) {
        std::error_code e2;
        if (!de.is_regular_file(e2)) continue;
        const std::string n = de.path().filename().string();
        if (n == ".write-test" || n == "CLAIMED-BY.txt") continue;
        std::filesystem::copy_file(de.path(), to + "/" + n, std::filesystem::copy_options::skip_existing, e2);
    }
}
static std::string normDir(const std::string& p) {
    std::error_code ec;
    std::string n = std::filesystem::weakly_canonical(std::filesystem::path(p), ec).lexically_normal().string();
    if (ec || n.empty()) n = std::filesystem::path(p).lexically_normal().string();
    while (n.size() > 1 && n.back() == '/') n.pop_back();
    return n;
}
// Basecamp's folder for this module is <user-dir>/module_data/whisperbox_core/<id>. When <user-dir> is
// Basecamp's DEFAULT data folder of some home H (no --user-dir given), returns H; else "" (an explicit
// --user-dir profile, or not Basecamp at all).
static std::string defaultProfileHome(const std::string& instDir, const std::string& rh) {
    const std::filesystem::path base = std::filesystem::path(normDir(instDir)).parent_path().parent_path().parent_path();
    if (base.filename() != "LogosBasecamp" || base.parent_path().filename() != "Logos") return "";
    const std::string b = normDir(base.string());
    std::vector<std::string> homes;
    if (!rh.empty()) homes.push_back(rh);
    if (const char* eh = std::getenv("HOME")) if (*eh == '/') homes.push_back(eh);
    for (const auto& h : homes) {
        if (b == normDir(h + "/.local/share/Logos/LogosBasecamp")) return h;                    // Linux
        if (b == normDir(h + "/Library/Application Support/Logos/LogosBasecamp")) return h;     // macOS
    }
    if (const char* x = std::getenv("XDG_DATA_HOME"))
        if (*x == '/' && b == normDir(std::string(x) + "/Logos/LogosBasecamp") && !homes.empty()) return homes.back();
    return "";
}
void WhisperboxCoreImpl::setupDataDir() {
    m_storageOk = true; m_storageNote.clear();
    if (const char* ov = std::getenv("WHISPERBOX_CORE_DATA")) {
        m_dataDir = ov;
        if (!dirWritable(m_dataDir)) { m_storageOk = false; m_storageNote = "Can't save to " + m_dataDir; }
        else makePrivate(m_dataDir);
        return;
    }
    const std::string rh = realHome();
    // Basecamp gives each module a folder under its data directory (--user-dir): one WhisperBox per
    // Basecamp profile, so two profiles never share an identity. It survives restarts, module upgrades
    // and uninstall (the package manager removes only the module's install folder).
    const std::string inst = instancePersistencePath();
    if (!inst.empty() && dirWritable(inst)) {
        m_dataDir = inst;
        if (!hasIdentityFile(m_dataDir)) {
            // First start of this profile on 0.6.1+. Only the DEFAULT profile takes over the data kept in
            // ~/.whisperbox-core by older versions, and only once (CLAIMED-BY.txt); any other profile starts
            // with its own identity instead of copying someone else's.
            const std::string h = defaultProfileHome(inst, rh);
            const std::string old = h.empty() ? "" : h + "/.whisperbox-core";
            if (!old.empty() && hasIdentityFile(old)) {
                std::string claimedBy;
                { std::ifstream c(old + "/CLAIMED-BY.txt"); std::getline(c, claimedBy); }
                // re-claim if the claiming folder lost its identity (module_data wiped by hand): never strand it
                if (claimedBy.empty() || normDir(claimedBy) == normDir(inst) || !hasIdentityFile(claimedBy)) {
                    copyDataFiles(old, m_dataDir);
                    std::ofstream c(old + "/CLAIMED-BY.txt", std::ios::trunc);
                    c << inst << "\n"
                      << "WhisperBox 0.6.1+ keeps its data in the Basecamp folder above. This folder is the copy\n"
                      << "taken at that moment, kept as a backup; WhisperBox in Basecamp no longer reads or writes it.\n";
                    fprintf(stderr, "WHISPERBOX copied data from %s (kept there as a backup)\n", old.c_str());
                    m_storageNote = "Copied your data from " + old + " (kept there as a backup)";
                }
            }
        }
        makePrivate(m_dataDir);
        return;
    }
    // Not in Basecamp (logosctl, other hosts) or its folder isn't writable: ~/.whisperbox-core as before.
    std::vector<std::string> cands;
    if (!rh.empty()) cands.push_back(rh + "/.whisperbox-core");                       // survives reinstall
    if (const char* eh = std::getenv("HOME"))
        if (*eh == '/' && std::string(eh) + "/.whisperbox-core" != (cands.empty() ? "" : cands[0])) cands.push_back(std::string(eh) + "/.whisperbox-core");
    m_dataDir.clear();
    for (const auto& c : cands) if (dirWritable(c)) { m_dataDir = c; break; }
    if (m_dataDir.empty()) {
        m_storageOk = false;
        m_dataDir = !inst.empty() ? inst : (cands.empty() ? std::string("/tmp/whisperbox-core-") + std::to_string(getuid()) : cands[0]);
        m_storageNote = "Can't save anything (tried " + std::to_string(cands.size() + (inst.empty() ? 0 : 1)) + " folders) - forms and your identity will not survive a restart";
        fprintf(stderr, "WHISPERBOX STORAGE NOT WRITABLE: %s\n", m_storageNote.c_str());
        return;
    }
    // Adopt an identity (and the rest) kept elsewhere instead of minting a new one.
    if (!hasIdentityFile(m_dataDir)) {
        for (const auto& c : cands) {
            if (c == m_dataDir || !hasIdentityFile(c)) continue;
            copyDataFiles(c, m_dataDir);
            fprintf(stderr, "WHISPERBOX adopted data from %s\n", c.c_str());
            m_storageNote = "Moved your data from " + c;
            break;
        }
    }
    makePrivate(m_dataDir);
}
std::string WhisperboxCoreImpl::randomHex(int bytes) {
    // CSPRNG — never rand(): an unseeded rand() is deterministic per process,
    // which minted byte-identical "fresh" identities in two separate runs.
    // A failed RAND_bytes used to return zeros silently (open-review 2026-11-01, FR-14): fail instead.
    whisperbox::Bytes b(bytes);
    bool ok = bytes <= 0;
    for (int tries = 0; tries < 10 && !ok; ++tries) ok = RAND_bytes(b.data(), bytes) == 1;
    if (!ok) throw std::runtime_error("the random number generator failed");
    return whisperbox::toHex(b);
}
void WhisperboxCoreImpl::loadIdentity() {
    std::ifstream f(m_dataDir + "/identity.json");
    if (f) {
        try {
            json o = parseFile(f);
            if (whisperbox::vault::isSealedIdentity(o)) {
                // protected by a passphrase: no identity until unlock() (FR-13)
                m_protected = true; m_locked = true;
                m_lockedIdentity = o;
                m_lockedAddress = o.value("address", "");
                return;
            }
            m_signId = whisperbox::identityFromPriv(whisperbox::fromHex(o.value("privHex", "")));
            if (m_signId.valid) return;
        } catch (...) { /* unreadable */ }
        // The file exists but is unreadable: it holds the ONLY key that opens every answer
        // sealed to this creator. Move it aside (recoverable) - never overwrite it.
        f.close();
        quarantine(m_dataDir + "/identity.json");
    }
    // First run (or the old file was quarantined): generate a keypair.
    std::string priv;
    try { priv = randomHex(32); } catch (const std::exception& ex) { fprintf(stderr, "WHISPERBOX identity generation failed: %s\n", ex.what()); return; }
    m_signId = whisperbox::identityFromPriv(whisperbox::fromHex(priv));
    if (!m_signId.valid) { fprintf(stderr, "WHISPERBOX identity generation failed\n"); return; }
    saveIdentity();
    fprintf(stderr, "WHISPERBOX new identity %s\n", m_signId.address.c_str());
}
void WhisperboxCoreImpl::saveIdentity() {
    if (m_protected && m_vaultKey.size() == 32) {   // sealed under the passphrase (FR-13)
        writeAtomic(m_dataDir + "/identity.json", whisperbox::vault::sealIdentity(m_signId.priv, m_signId.address, m_signId.pubHex, m_vaultKey, m_vaultSalt).dump());
        return;
    }
    json o = {{"privHex", whisperbox::toHex(m_signId.priv)}, {"pubHex", m_signId.pubHex}, {"address", m_signId.address}};
    writeAtomic(m_dataDir + "/identity.json", o.dump());
}
void WhisperboxCoreImpl::loadLog() {
    // Signed event types are checked again: the fold doesn't verify, admission did, and a log
    // edited (or restored) on disk could carry an unsigned close, update or co-owner grant
    // (open-review FR-7). The 0.1.x unsigned form.publish placeholders are repaired below.
    auto signedType = [](const std::string& t) {
        return t == FORM_PUBLISH || t == RESPONSE_CONFIRM || t == FORM_CLOSE || t == whisperbox::FORM_REOPEN || t == whisperbox::FORM_UPDATE || t == whisperbox::FORM_COOWNER || t == whisperbox::RESPONSE_REPLY;
    };
    json bad = json::array();
    auto take = [&](const json& e) {
        if (whisperbox::wellFormedEvent(e) && (!signedType(e.value("type", "")) || whisperbox::verifyEventJson(e))) m_log.push_back(e);
        else { bad.push_back(e); m_loadDropped++; }
    };
    bool journal = false;
    {
        std::ifstream f(m_dataDir + "/events.json");
        if (f) try {
            // the log is a JSON array of events: two levels more than a frame; no size cap on our own file
            json a = whisperbox::parseLimited(std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>()),
                                              whisperbox::kMaxJsonDepth + 2, std::numeric_limits<size_t>::max());
            if (a.is_null()) throw std::runtime_error("events.json unreadable or nested too deep");
            if (a.is_array()) for (auto& e : a) take(e);
        } catch (...) {
            // Never let the next save overwrite it: keep the unreadable file for recovery.
            f.close();
            quarantine(m_dataDir + "/events.json");
            m_log.clear();
        }
    }
    {   // the journal: one event per line, appended since the last compaction (FR-5); a torn last
        // line (a crash mid-write) is skipped
        std::ifstream j(m_dataDir + "/events.journal");
        std::string line;
        while (j && std::getline(j, line)) {
            journal = true;
            if (line.empty()) continue;
            json e = whisperbox::parseLimited(line, whisperbox::kMaxJsonDepth, whisperbox::kMaxEventBytes * 2);
            if (e.is_null()) { m_loadDropped++; continue; }
            take(e);
        }
    }
    // A log written before 0.4.3 may hold a peer's malformed event that crashed every start
    // (WB-1): skip it, and keep it aside rather than losing it.
    if (!bad.empty()) {
        fprintf(stderr, "WHISPERBOX skipped %zu malformed events in the log (kept in events.bad.json)\n", bad.size());
        writeAtomic(m_dataDir + "/events.bad.json", bad.dump());
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
    else if (m_loadDropped || journal) saveLog();   // the malformed events are in events.bad.json; the journal folds into the base
    else { std::error_code ec; auto n = std::filesystem::file_size(m_dataDir + "/events.json", ec); m_baseBytes = ec ? 0 : (size_t)n; }
    recountLog();
}
void WhisperboxCoreImpl::recountLog() {
    m_logGen++;
    m_logBytes = 0; m_logResponses = 0; m_heldHlc.clear(); m_heldBytes.clear();
    for (const auto& e : m_log) {
        const size_t n = e.dump().size();
        m_logBytes += n; if (e.value("type", "") == RESPONSE_SUBMIT) m_logResponses++;
        const std::string key = whisperbox::eventKey(e);
        m_heldHlc[key] = e.value("hlc", json::object());
        m_heldBytes[key] = n;
    }
}
// The log on disk is events.json (the base, rewritten rarely) plus events.journal (one event per line,
// appended). Every flush used to rewrite the whole log: 1.8 s at 4 MB, 11 s at 84 MB (open-review
// 2026-11-03, FR-5). The journal is folded into the base once it outgrows max(4 MiB, the base), so
// rewriting costs O(1) per byte over time. Loading merges both (the merge drops duplicates).
void WhisperboxCoreImpl::saveLog() {   // compaction: the whole log as the base, an empty journal
    m_logDirty = false;
    m_journalPending.clear();
    const std::string text = json(m_log).dump();
    if (writeAtomic(m_dataDir + "/events.json", text)) {
        m_baseBytes = text.size();
        std::error_code ec;
        std::filesystem::remove(m_dataDir + "/events.journal", ec);
        m_journalBytes = 0;
    }
}
void WhisperboxCoreImpl::flushLog() {
    m_logDirty = false;
    if (m_journalPending.empty()) return;
    const std::string path = m_dataDir + "/events.journal";
    const bool fresh = !std::filesystem::exists(path);
    {
        std::ofstream f(path, std::ios::app | std::ios::binary);
        if (!f) return;   // kept pending: the next flush tries again
        if (fresh) { std::error_code ec; std::filesystem::permissions(path, kPrivateFile, std::filesystem::perm_options::replace, ec); }
        for (const auto& e : m_journalPending) { const std::string line = e.dump() + "\n"; f << line; m_journalBytes += line.size(); }
        f.flush();
        if (!f) return;
    }
    m_journalPending.clear();
    if (m_journalBytes > std::max<size_t>(size_t(4) << 20, m_baseBytes)) saveLog();
}
void WhisperboxCoreImpl::loadWatched() {
    m_watched.clear();
    std::ifstream f(m_dataDir + "/watched.json"); if (!f) return;
    try {
        json a = parseFile(f);
        if (a.is_array()) for (auto& x : a) if (x.is_string()) m_watched.insert(lc(x.get<std::string>()));
    } catch (...) { /* ignore */ }
}
void WhisperboxCoreImpl::saveWatched() {
    json a = json::array(); for (auto& id : m_watched) a.push_back(id);
    writeAtomic(m_dataDir + "/watched.json", a.dump());
}
void WhisperboxCoreImpl::loadPins() {
    m_pinned.clear(); m_pinsGen++;
    std::ifstream f(m_dataDir + "/pins.json"); if (!f) return;
    try {
        json o = parseFile(f);
        if (o.is_object()) for (auto it = o.begin(); it != o.end(); ++it) if (it.value().is_string()) m_pinned[lc(it.key())] = lc(it.value().get<std::string>());
    } catch (...) { /* ignore */ }
}
void WhisperboxCoreImpl::savePins() {
    m_pinsGen++;   // the fold prefers pinned creators: re-fold
    json o = json::object(); for (auto& kv : m_pinned) o[kv.first] = kv.second;
    writeAtomic(m_dataDir + "/pins.json", o.dump());
}
void WhisperboxCoreImpl::loadMySubmissions() {
    m_mySubmissions.clear(); m_myConfirmIds.clear();
    std::ifstream f(m_dataDir + "/my_submissions.json"); if (!f) return;
    try {
        json a = parseFile(f);
        // <= 0.1.x: ["formId", ...] (legacy receipt id); 0.2+: {"formId": "<confirmationId>"}
        if (a.is_array()) for (auto& x : a) if (x.is_string()) m_mySubmissions.insert(lc(x.get<std::string>()));
        if (a.is_object()) for (auto it = a.begin(); it != a.end(); ++it) {
            m_mySubmissions.insert(lc(it.key()));
            if (it.value().is_string() && !it.value().get<std::string>().empty()) m_myConfirmIds[lc(it.key())] = it.value().get<std::string>();
        }
    } catch (...) { /* ignore */ }
}
void WhisperboxCoreImpl::loadLocalPrefs() {
    m_hidden.clear(); m_myAnswers.clear(); m_drafts.clear(); m_answerDrafts.clear(); m_autoReceipts.clear(); m_seen.clear(); m_netTimes.clear(); m_firstSeen.clear();
    try {
        std::ifstream fs(m_dataDir + "/firstseen.json");
        if (fs) { json o = parseFile(fs);
                  if (o.is_object()) for (auto it = o.begin(); it != o.end(); ++it) if (it.value().is_number_integer() && it.value().get<long long>() > 0) m_firstSeen[it.key()] = it.value().get<long long>(); }
    } catch (...) { /* ignore */ }
    try {
        std::ifstream nt(m_dataDir + "/nettime.json");
        if (nt) { json o = parseFile(nt);
                  if (o.is_object()) for (auto it = o.begin(); it != o.end(); ++it) if (it.value().is_number_integer() && it.value().get<long long>() > 0) m_netTimes[it.key()] = it.value().get<long long>(); }
    } catch (...) { /* ignore */ }
    try {
        std::ifstream sn(m_dataDir + "/seen.json");
        if (sn) { json o = parseFile(sn);
                  if (o.is_object()) for (auto it = o.begin(); it != o.end(); ++it) if (it.value().is_number_integer()) m_seen[lc(it.key())] = it.value().get<long long>(); }
    } catch (...) { /* ignore */ }
    try {
        std::ifstream h(m_dataDir + "/hidden.json");
        if (h) { json a = parseFile(h);
                 if (a.is_array()) for (auto& x : a) if (x.is_string()) m_hidden.insert(lc(x.get<std::string>())); }
    } catch (...) { /* ignore */ }
    loadPrivateFiles();
}
// my_answers.json and drafts.json: plaintext, or sealed under the identity when a passphrase is set
// (open-review 2026-11-03, FR-13). Sealed + locked = not read yet (unlock() reads them).
std::string WhisperboxCoreImpl::readPrivate(const std::string& name, bool& readable) {
    readable = true;
    std::ifstream f(m_dataDir + "/" + name);
    if (!f) return "";
    std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    if (!whisperbox::vault::isSealedLocal(text)) return text;
    if (!m_signId.valid) { readable = false; return ""; }
    return whisperbox::vault::openLocal(whisperbox::vault::localKey(m_signId.priv), text);
}
void WhisperboxCoreImpl::writePrivate(const std::string& name, const std::string& text) {
    if (m_locked) return;   // nothing loaded yet: never overwrite the sealed file
    if (m_protected && m_signId.valid) writeAtomic(m_dataDir + "/" + name, whisperbox::vault::sealLocal(whisperbox::vault::localKey(m_signId.priv), text));
    else writeAtomic(m_dataDir + "/" + name, text);
}
void WhisperboxCoreImpl::loadPrivateFiles() {
    m_myAnswers.clear(); m_drafts.clear(); m_answerDrafts.clear(); m_autoReceipts.clear(); m_draftTrash.clear();
    bool ok = true;
    try {
        std::string t = readPrivate("drafts.json", ok);
        if (!t.empty()) {
            json o = whisperbox::parseLimited(t, whisperbox::kMaxJsonDepth + 2, size_t(256) << 20);
            if (o.is_object()) {
                if (o.contains("forms") && o["forms"].is_object()) for (auto it = o["forms"].begin(); it != o["forms"].end(); ++it) m_drafts[it.key()] = it.value();
                if (o.contains("answers") && o["answers"].is_object()) for (auto it = o["answers"].begin(); it != o["answers"].end(); ++it) m_answerDrafts[lc(it.key())] = it.value();
                if (o.contains("autoReceipts") && o["autoReceipts"].is_array()) for (auto& x : o["autoReceipts"]) if (x.is_string()) m_autoReceipts.insert(lc(x.get<std::string>()));
                if (o.contains("trash") && o["trash"].is_array()) for (auto& x : o["trash"]) if (x.is_object() && m_draftTrash.size() < kMaxDraftTrash) m_draftTrash.push_back(x);
            }
        }
    } catch (...) { fprintf(stderr, "WHISPERBOX drafts.json unreadable - starting without drafts\n"); }
    try {
        std::string t = readPrivate("my_answers.json", ok);
        if (!t.empty()) {
            json o = whisperbox::parseLimited(t, whisperbox::kMaxJsonDepth + 2, size_t(256) << 20);
            if (o.is_object()) for (auto it = o.begin(); it != o.end(); ++it) m_myAnswers[lc(it.key())] = it.value();
        }
    } catch (...) { /* ignore */ }
}
size_t WhisperboxCoreImpl::draftsBytes() const {
    size_t n = 0;
    for (const auto& kv : m_drafts) n += kv.second.dump().size();
    for (const auto& kv : m_answerDrafts) n += kv.second.dump().size();
    return n;
}
void WhisperboxCoreImpl::saveDrafts() {
    json o = json::object();
    json d = json::object(); for (auto& kv : m_drafts) d[kv.first] = kv.second;
    json a = json::object(); for (auto& kv : m_answerDrafts) a[kv.first] = kv.second;
    json r = json::array(); for (auto& id : m_autoReceipts) r.push_back(id);
    o["forms"] = d; o["answers"] = a; o["autoReceipts"] = r;
    o["trash"] = json(m_draftTrash);
    m_draftsDirty = false;
    writePrivate("drafts.json", o.dump());
}
void WhisperboxCoreImpl::saveSeen() {
    json o = json::object(); for (auto& kv : m_seen) o[kv.first] = kv.second;
    writeAtomic(m_dataDir + "/seen.json", o.dump());
}
// Mark every response of a form as seen (creator opened it).
std::string WhisperboxCoreImpl::markSeen(std::string formId) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    formId = lc(trim(formId));
    OrderedJson state = foldedState();
    OrderedJson cv = decryptView(state);
    long long n = cv["responses"].contains(formId) ? (long long)cv["responses"][formId].size() : 0;
    if (!m_seen.count(formId) || m_seen[formId] != n) { m_seen[formId] = n; saveSeen(); publishState(); }
    return json({{"ok", true}, {"formId", formId}, {"seen", n}}).dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}
void WhisperboxCoreImpl::saveHidden() {
    json a = json::array(); for (auto& id : m_hidden) a.push_back(id);
    writeAtomic(m_dataDir + "/hidden.json", a.dump());
}
void WhisperboxCoreImpl::saveMyAnswers() {
    json o = json::object(); for (auto& kv : m_myAnswers) o[kv.first] = kv.second;
    writePrivate("my_answers.json", o.dump());
}
void WhisperboxCoreImpl::saveMySubmissions() {
    json o = json::object();
    for (auto& id : m_mySubmissions) o[id] = m_myConfirmIds.count(id) ? m_myConfirmIds[id] : std::string();
    writeAtomic(m_dataDir + "/my_submissions.json", o.dump());
}

// ── transport: loam_core (Basecamp 0.3) ───────────────────────────────────────────
// WhisperBox no longer runs its own delivery node: loam_core is the one transport every Loam app
// shares (Waku via upstream delivery_module 0.3.x, BLE mesh when present). Its config owns the
// fleet, shards and RLN; we only say "Core mode on logos.test, reliable channels".
//
// Wire: unchanged. The bytes on the topic are the base64 envelope TEXT, as before (and as the
// phones send through loam-transport): sendSealed takes base64 of those bytes, received() hands
// them back base64'd once more.
void WhisperboxCoreImpl::bootstrapDelivery() {
    if (m_nodeReady || m_deliveryStarting) return;
    if (!m_signId.valid) { setStatus(m_locked ? "Locked - enter your passphrase" : "No identity"); return; }
    // a failed start is retried, backing off to once a minute (open-review 2026-11-02, FR-14)
    const int64_t backoff = std::min<int64_t>(60000, 5000LL * (1LL << std::min<long>(m_startFailures, 4)));
    if (m_startFailures > 0 && nowMs() - m_lastStartMs < backoff) return;
    m_lastStartMs = nowMs();
    m_deliveryStarting = true;
    // useChannels:false = plain relay. Delivery 0.3's reliable channels hold back every message whose
    // causal history this node never saw ("SDS message has missing dependencies", then "stash full"),
    // so a desktop never received anything from a phone with history (2026-10-09). loam_core still
    // unwraps the phones' channel frames on the relay path, and phones accept plain relay frames;
    // WhisperBox's own RBSR catch-up does the reliability.
    json cfg = {{"mode", "Core"}, {"preset", "logos.test"}, {"useChannels", false}};
    if (const char* ov = std::getenv("WHISPERBOX_DELIVERY_CFG")) {
        auto j = json::parse(ov, nullptr, false);
        if (j.is_object()) cfg = j;
    }
    auto life = m_life;
    try {
        // Callbacks arrive on the IPC thread. Never call a module from inside one (each call would
        // wait out the IPC timeout): hand the work to this module's thread. They may also arrive
        // after we're gone: through m_life only (FR-8).
        modules().loam_core.onReceived([life](const std::string& topic, const std::string&, const std::string& payloadB64, int64_t ts) {
            if (!isWireTopic(topic)) return;
            // ts: the message's network timestamp in ns (loam_core >= 0.8.0: 0 = none, and an
            // earlier-stamped duplicate is delivered again). Older loam_core passes the WakuMessage
            // time on this relay path too. Any of them bounds when the answer existed (ADR 0019).
            const long long netMs = netMsOf(ts, nowMs());
            // as the old receive path did: the payload still base64'd; the ingest peels one or two
            // layers (phones send base64(envelope) or the raw envelope)
            withSelf(life, [payloadB64, netMs](WhisperboxCoreImpl* self) { self->ingestEnvelopeText(payloadB64, /*channelPath=*/true, netMs); });
        });
        modules().loam_core.onStatusChanged([life](const std::string& st) { withSelf(life, [st](WhisperboxCoreImpl* self) { self->onTransportStatus(st); }); });
        modules().loam_core.setSenderIdAsync(m_deviceId, [](std::string) {});
        modules().loam_core.startAsync(cfg.dump(), [life](std::string err) {
            if (err.empty() || err == "{}" || err.find("\"ok\":true") != std::string::npos) return;
            withSelf(life, [err](WhisperboxCoreImpl* self) {
                std::lock_guard<std::recursive_mutex> lk(self->m_mtx);
                if (self->m_nodeReady) return;
                // the hub tick starts it again after the backoff (it used to stay "Connecting..." for good)
                self->m_deliveryStarting = false;
                self->m_startFailures++;
                self->setStatus("Transport error: " + err);
            });
        });
        setStatus("Connecting...");
    } catch (const std::exception& e) {
        m_deliveryStarting = false;
        m_startFailures++;
        setStatus(std::string("loam_core unavailable: ") + e.what());
    }
}

// ADR 0021: which transport. An installed loam_core answers statusAsync with a non-empty status
// ("Starting..." before anything started it); an absent optional module answers empty or with an error,
// without hanging. Only async calls go to loam_core, and nothing subscribes to its events before it has
// answered (subscribing to an absent module's events may wedge). Three silent tries, then go direct.
// WHISPERBOX_TRANSPORT=loam|direct forces the choice (tests, hubs).
void WhisperboxCoreImpl::probeTransport() {
    if (const char* f = std::getenv("WHISPERBOX_TRANSPORT")) {
        const std::string v = f;
        if (v == "loam" || v == "direct") {
            m_via = v == "loam" ? Via::Loam : Via::Direct;
            fprintf(stderr, "WHISPERBOX transport: %s (WHISPERBOX_TRANSPORT)\n", v.c_str());
            return;
        }
    }
    const int64_t now = nowMs();
    if (m_probing && now - m_probeAt < 8000) return;   // an answer is on its way (or lost: retry after 8 s)
    if (now - m_probeAt < 2000) return;
    if (m_probing) m_probing = false;                   // no answer at all counts as a silent try
    // Going direct is only possible once DirectTransport exists (kHaveDirect). Until then a missing
    // loam_core keeps being retried - exactly today's behaviour - so no existing install can lose Loam
    // to an early error ("auth token not recognized" at start is a transient error, not absence).
    static constexpr bool kHaveDirect = true;
    if (m_probeTries >= 3 && kHaveDirect) {
        m_via = Via::Direct;
        fprintf(stderr, "WHISPERBOX transport: delivery_module (loam_core not installed)\n");
        return;
    }
    if (m_probeTries >= 3 && m_status != "Waiting for loam_core") setStatus("Waiting for loam_core");
    m_probing = true;
    m_probeAt = now;
    m_probeTries++;
    auto life = m_life;
    try {
        modules().loam_core.statusAsync([life](std::string st) {
            withSelf(life, [st](WhisperboxCoreImpl* self) {
                std::lock_guard<std::recursive_mutex> lk(self->m_mtx);
                if (self->m_via != Via::Unknown) return;
                self->m_probing = false;
                std::string low = st;
                for (auto& c : low) c = (char)std::tolower((unsigned char)c);
                auto has = [&low](const char* s) { return low.find(s) != std::string::npos; };
                // An installed loam_core can refuse the first calls while the host wires us up ("auth
                // token not recognized", a timeout): that is not absence, so it doesn't count as a try.
                if (has("token") || has("timeout") || has("timed out") || has("not ready")) {
                    if (self->m_probeTries > 0) self->m_probeTries--;
                    fprintf(stderr, "WHISPERBOX transport: loam_core not answering yet (%s)\n", st.c_str());
                    return;
                }
                // An absent optional module answers nothing or empty (seen live on logosctl 0.3.1). Any
                // other answer is loam_core's own status - including "Transport error: ..." /
                // "Transport stalled: ...", which mean it is installed with a sick node (going direct
                // then would only add a second transport on the same node; review 2026-11-13).
                const bool absent = st.empty() || has("not found") || has("unknown module") || has("not loaded")
                    || has("not installed") || has("no such module") || has("not reachable");
                if (!absent) {
                    self->m_via = Via::Loam;
                    fprintf(stderr, "WHISPERBOX transport: loam_core (%s)\n", st.c_str());
                }
            });
        });
    } catch (...) { m_probing = false; }
}

// delivery_module directly, through Loam's shared header (loam/delivery_transport.hpp, loam_core 0.7.4):
// the same RLN-off logos.test network, the same wire, and it adopts a node another module already
// created. Every delivery_module callback arrives on an IPC thread: it hops to this module's thread
// (withSelf) before it touches the transport, which has no locks of its own.
// Which mode a node WE create gets. Both views share this core, so the core looks at what Basecamp
// installed: views live in <user-dir>/plugins/<name>, and this module's folder is
// <user-dir>/module_data/whisperbox_core/<id>. Studio (whisperbox) installed -> Core; only the respond
// view (whisperbox_respond) -> Edge; anything else (headless under logosctl, an unknown layout) -> Core,
// the mode that is safe to share. Read when the node is created: installing the studio later takes
// effect on the next start. WHISPERBOX_NODE_MODE=Core|Edge overrides (tests, hubs).
std::string WhisperboxCoreImpl::directNodeMode(std::string* why) const {
    auto say = [why](const std::string& w) { if (why) *why = w; };
    if (const char* f = std::getenv("WHISPERBOX_NODE_MODE")) {
        const std::string v = f;
        if (v == "Core" || v == "Edge") { say("WHISPERBOX_NODE_MODE"); return v; }
    }
    const std::string inst = instancePersistencePath();
    if (inst.empty()) { say("not in Basecamp"); return "Core"; }
    namespace fs = std::filesystem;
    std::error_code ec;
    const fs::path plugins = fs::path(normDir(inst)).parent_path().parent_path().parent_path() / "plugins";
    if (fs::is_directory(plugins / "whisperbox", ec)) { say("studio installed"); return "Core"; }
    if (fs::is_directory(plugins / "whisperbox_respond", ec)) { say("respond-only install"); return "Edge"; }
    say("no WhisperBox view found in " + plugins.string());
    return "Core";
}

void WhisperboxCoreImpl::bootstrapDirect() {
    if (m_direct) return;
    if (!m_signId.valid) { setStatus(m_locked ? "Locked - enter your passphrase" : "No identity"); return; }
    const int64_t backoff = std::min<int64_t>(60000, 5000LL * (1LL << std::min<long>(m_startFailures, 4)));
    if (m_startFailures > 0 && nowMs() - m_directFailedAt < backoff) return;
    using DT = loam::delivery::DeliveryTransport<LogosMap>;
    auto life = m_life;
    // run cb on the module thread, if the module and its transport still exist
    auto hop = [life](std::function<void(WhisperboxCoreImpl*)> fn) {
        withSelf(life, [fn](WhisperboxCoreImpl* s) {
            std::lock_guard<std::recursive_mutex> lk(s->m_mtx);
            if (s->m_direct && s->m_direct->t) fn(s);
        });
    };
    auto res = [hop](DT::Cb cb) { return [hop, cb](StdLogosResult r) { hop([cb, r](WhisperboxCoreImpl*) { cb(r.success, r.error); }); }; };
    auto text = [hop](std::function<void(bool, const std::string&)> cb) {
        return [hop, cb](StdLogosResult r) {
            const std::string v = r.value.is_string() ? r.value.get<std::string>() : r.value.dump();
            hop([cb, r, v](WhisperboxCoreImpl*) { cb(r.success, v); });
        };
    };
    m_direct = std::make_shared<Direct>();
    Direct* d = m_direct.get();
    d->raw = std::make_unique<logos::LpClient>("delivery_module", "whisperbox_core");
    DT::Ops ops;
    ops.createNode = [this, res](const std::string& cfg, DT::Cb cb) { modules().delivery_module.createNodeAsync(cfg, res(cb)); };
    ops.start      = [this, res](DT::Cb cb) { modules().delivery_module.startAsync(res(cb)); };
    ops.stop       = [this, res](DT::Cb cb) { modules().delivery_module.stopAsync(res(cb)); };
    ops.subscribe  = [this, res](const std::string& t, DT::Cb cb) { modules().delivery_module.subscribeAsync(t, res(cb)); };
    // the header ignores a send's result; we don't: a failed send goes back in the queue (audit W2-10).
    // m_sending is the message deliverySend is handing over, set around this synchronous call.
    ops.sendRaw    = [this, hop](const std::string& t, const LogosMap& p, DT::Cb cb) {
        OutMsg cur = m_sending;
        modules().delivery_module.sendAsync(t, p, [hop, cur, cb](StdLogosResult r) {
            hop([cur, r, cb](WhisperboxCoreImpl* s) { cb(r.success, r.error); if (!r.success) s->onSendFailed(cur, r.error); });
        });
    };
    ops.metrics    = [this, text](std::function<void(bool, const std::string&)> cb) { modules().delivery_module.getNodeInfoAsync("Metrics", text(cb)); };
    ops.connectionStatus = [this, text](std::function<void(bool, const std::string&)> cb) { modules().delivery_module.getConnectionStatusAsync(text(cb)); };
    // RAW messageReceived: [hash, contentTopic, payload, (source,) ts] - the payload untouched (the
    // generated binding's bytes conversion zeroes anything that isn't {"_bytes":...}); ts is last
    ops.onMessage = [d, hop](DT::RecvCb rcb) {
        auto sub = d->raw->subscribe("messageReceived", [hop, rcb](nlohmann::json a) {
            if (!a.is_array() || a.size() < 4) return;
            const std::string topic = a.at(1).is_string() ? a.at(1).get<std::string>() : std::string();
            const int64_t ts = a.back().is_number() ? (int64_t)a.back().get<double>() : 0;
            LogosMap payload = a.at(2);
            hop([rcb, topic, payload, ts](WhisperboxCoreImpl*) { rcb(topic, "", payload, ts); });
        });
        if (sub.valid()) d->subs.push_back(std::move(sub));
    };
    ops.onNodeStarted = [d, hop](std::function<void(bool, const std::string&)> cb) {
        auto sub = d->raw->subscribe("nodeStarted", [hop, cb](nlohmann::json a) {
            if (!a.is_array() || a.empty()) return;
            const bool ok = a.at(0).is_boolean() && a.at(0).get<bool>();
            const std::string msg = (a.size() > 1 && a.at(1).is_string()) ? a.at(1).get<std::string>() : std::string();
            hop([cb, ok, msg](WhisperboxCoreImpl*) { cb(ok, msg); });
        });
        if (sub.valid()) d->subs.push_back(std::move(sub));
    };
    DT::Config cfg;
    // the same network as the loam_core path: logos.test without RLN (nodeConfig spells it out).
    // Mode (Václav, 2026-11-13): the studio creates Core, a respond-only install creates Edge (a light
    // node: Filter for our buckets, Lightpush to send, no relaying). Only when WE create the node: one
    // that already runs on this Basecamp is adopted as it is (the header's adopt path).
    m_nodeMode = directNodeMode(&m_nodeModeWhy);
    fprintf(stderr, "WHISPERBOX node mode: %s (%s)\n", m_nodeMode.c_str(), m_nodeModeWhy.c_str());
    json app = {{"mode", m_nodeMode}, {"preset", "logos.test"}};
    if (const char* ov = std::getenv("WHISPERBOX_DELIVERY_CFG")) {
        auto j = json::parse(ov, nullptr, false);
        if (j.is_object()) { app = j; for (const char* k : {"useChannels", "hubMode", "useBle", "useMesh", "useDelivery", "rln"}) app.erase(k); }
    }
    cfg.nodeConfigJson = loam::delivery::nodeConfig<LogosMap>(LogosMap(app), false).dump();
    cfg.useChannels = false;   // plain relay, as on the loam_core path (RBSR does the reliability)
    cfg.senderId = m_deviceId;
    d->t = std::make_unique<DT>(std::move(ops), std::move(cfg));
    d->t->onFrame = [this](const loam::delivery::Frame& f) {
        if (!isWireTopic(f.topic)) return;
        // f.bytes = what was sent: the base64 envelope text (the ingest peels one or two layers)
        ingestEnvelopeText(f.bytes, /*channelPath=*/true, netMsOf(f.ts, nowMs()));
    };
    d->t->onReady = [this] { onTransportStatus("Connected"); };
    d->t->onError = [this](const std::string& e) {
        m_startFailures++;
        m_directFailedAt = nowMs();
        setStatus("Transport error: " + e);   // directTick drops this transport; the next tick starts another
    };
    d->t->onWarning = [](const std::string& w) { fprintf(stderr, "WHISPERBOX transport: %s\n", w.c_str()); };
    fprintf(stderr, "WHISPERBOX transport: delivery_module direct (wire v%d)\n", LOAM_DELIVERY_WIRE_VERSION);
    d->t->start();
    setStatus("Connecting...");
}

// Every hub tick on the direct path: drive the transport (peers, the peerless watchdog, adoption),
// and replace a transport whose node failed to start (never from inside its own callback).
void WhisperboxCoreImpl::directTick() {
    if (!m_direct || !m_direct->t) return;
    auto& t = *m_direct->t;
    if (!t.ready() && t.status().rfind("error", 0) == 0) {
        // the next transport is a new node: nothing is joined on it (audit W2-4)
        m_direct.reset(); m_subscribed = false; m_joinedTopics.clear();
        if (m_nodeReady) { m_nodeReady = false; setStatus("Reconnecting..."); }
        return;
    }
    t.tick(nowMs());
    if (m_nodeReady && !t.ready() && m_status != "Reconnecting...") setStatus("Reconnecting...");
}

// loam_core reports "Connected" by event; the event can be lost or come before we listened, so
// the hub timer also asks for the status until we're up.
void WhisperboxCoreImpl::onTransportStatus(const std::string& st) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    if (st.empty()) return;
    if (st == "Connected" && !m_nodeReady) {
        m_nodeReady = true;
        m_startFailures = 0;
        m_joinedTopics.clear();
        syncTopics();      // join our forms' buckets and pull what Store has for them
        setStatus("Connected");
        publishState();
    } else if (!m_nodeReady) {
        setStatus(st);
    } else if (st != m_status) {
        // After the first connect, keep showing what the transport says: loam_core reports
        // "Transport stalled: ..." when the delivery node stops answering, and the view must not
        // keep saying "Connected" (review 2026-10-22). Back to Connected: catch up what was missed.
        const bool recovered = st == "Connected";
        setStatus(st);
        // a new or restarted node knows none of our topics: join them all again (audit W2-4)
        if (recovered) { m_joinedTopics.clear(); syncTopics(); storePullAll(); drainSendQueue(); }
        publishState();
    }
}

// Run fn on the module's thread if the module still exists (FR-8).
void WhisperboxCoreImpl::withSelf(const std::shared_ptr<Life>& life, std::function<void(WhisperboxCoreImpl*)> fn) {
    if (!life) return;
    std::lock_guard<std::mutex> g(life->mu);
    WhisperboxCoreImpl* self = life->self;
    if (!self || !self->m_hubTimer) return;
    // queued on the timer: a timer deleted with the module drops the call
    QMetaObject::invokeMethod(self->m_hubTimer, [life, fn] {
        WhisperboxCoreImpl* s2 = nullptr;
        { std::lock_guard<std::mutex> g2(life->mu); s2 = life->self; }
        if (s2) fn(s2);
    }, Qt::QueuedConnection);
}

void WhisperboxCoreImpl::onLoop(std::function<void()> fn) {
    if (!m_hubTimer) return;
    QMetaObject::invokeMethod(m_hubTimer, std::move(fn), Qt::QueuedConnection);
}

void WhisperboxCoreImpl::joinTransport() {
    if (!m_nodeReady || m_subscribed) return;
    syncTopics(); return;   // wire v2: per-form buckets (ADR 0024); the code below is v1, unreachable
    auto life = m_life;
    modules().loam_core.joinAsync(TOPIC, [life](std::string r) {
        // a failed join is tried again on the next status change / catch-up round (FR-14)
        if (r.find("\"ok\":false") == std::string::npos && r.find("error") == std::string::npos) return;
        withSelf(life, [](WhisperboxCoreImpl* self) { std::lock_guard<std::recursive_mutex> lk(self->m_mtx); self->m_subscribed = false; });
    });
    m_subscribed = true;
}

void WhisperboxCoreImpl::seedBroadcast() {
    if (!m_nodeReady || m_log.empty()) return;
    for (const auto& e : m_log) serveEvent(e);
    m_lastSeedMs = nowMs();
}

// ── catch-up over an index (open-review 2026-11-02, FR-4; whisperbox_rbsr.hpp) ──────
void WhisperboxCoreImpl::rbsrIndex() {
    if (m_rbsrGen == m_logGen && m_rbsrPos.size() == m_log.size()) return;
    std::vector<std::string> keys; keys.reserve(m_log.size());
    m_rbsrPos.clear();
    for (size_t i = 0; i < m_log.size(); i++) { keys.push_back(whisperbox::eventKey(m_log[i])); m_rbsrPos[keys.back()] = i; }
    m_rbsr.build(std::move(keys));
    m_rbsrGen = m_logGen;
}
void WhisperboxCoreImpl::rbsrRespond(const json& msg) {
    rbsrIndex();
    auto st = whisperbox::rbsr::respond(m_rbsr, msg, m_deviceId);
    if (st.bad) { m_rxBad++; return; }
    for (const auto& r : st.replies) sendControl(r);
    m_serveSkipped += (long)st.serveSkipped;
    for (const auto& id : st.serve) {
        auto it = m_rbsrPos.find(id);
        if (it != m_rbsrPos.end() && it->second < m_log.size()) serveEvent(m_log[it->second]);
    }
}

// One RBSR round: publish a bounded fingerprint over our id-set. Peers respond() with
// splits / exact id lists / need, converging on the id-exact delta in both directions.
void WhisperboxCoreImpl::catchupRound() {
    if (!m_nodeReady) return;
    // RBSR items are event KEYS (id, or id#signer for signed events) so two signers'
    // events under one id both reconcile - same key function as the merge.
    rbsrIndex();
    sendControl(whisperbox::rbsr::initialMessage(m_rbsr, m_deviceId));
}
void WhisperboxCoreImpl::sendControl(const json& msg) {
    if (deliverySend(TOPIC, whisperbox::b64encode(msg.dump()))) m_txTotal++;
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
    // the sealed bytes are the base64 envelope text either way (loam_core gets them base64'd once more)
    if (m_via == Via::Direct) return m_direct && m_direct->t && m_direct->t->send(topic, b64Text);
    // what is being sent, for the result callback: a send that fails later goes back in the queue
    // (audit W2-10: a dispatched send used to count as delivered)
    OutMsg cur = m_sending;
    auto life = m_life;
    try {
        modules().loam_core.sendSealedAsync(topic, whisperbox::b64encode(b64Text), [life, cur](std::string r) {
            if (r.find("\"ok\":false") == std::string::npos && r.find("rror") == std::string::npos) return;
            withSelf(life, [cur, r](WhisperboxCoreImpl* self) { std::lock_guard<std::recursive_mutex> lk(self->m_mtx); self->onSendFailed(cur, r); });
        });
    }
    catch (...) { return false; }
    return true;
}
void WhisperboxCoreImpl::onSendFailed(OutMsg m, const std::string& why) {
    m_txErr++;
    if (m.text.empty()) return;
    if (++m.tries >= 5) {   // never forever: the schedules (re-publish, answer retries) send it again later
        m_txDropped++;
        fprintf(stderr, "WHISPERBOX send failed 5 times, dropped (%s): %s\n", m.key.c_str(), why.substr(0, 120).c_str());
        return;
    }
    fprintf(stderr, "WHISPERBOX send failed, queued again (%s): %s\n", m.key.c_str(), why.substr(0, 120).c_str());
    m_rlnTokens += 1;   // it didn't go out
    for (const auto& q : m_outQ) if (!m.key.empty() && q.key == m.key) return;   // a newer copy is queued already
    m_outQ.push_back(std::move(m));
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

// An event peers would refuse is neither stored nor sent: a 100,000-byte receipt id or a 200 KB answer
// used to go into the local log (and the local view) while every peer dropped it (open-review
// 2026-11-02, FR-9/FR-10).
bool WhisperboxCoreImpl::adoptChecked(const json& e) {
    if (whisperbox::wellFormedEvent(e) && e.dump().size() <= whisperbox::kMaxWireEventBytes) return true;   // W2-1: also small enough to SEND
    fprintf(stderr, "WHISPERBOX refused a local %s event peers would drop (shape or size)\n", e.value("type", "?").c_str());
    return false;
}
void WhisperboxCoreImpl::adoptLocal(json e) {
    if (!adoptChecked(e)) return;
    if (whisperbox::mergeOne(m_log, e)) {
        m_logGen++;
        const std::string key = whisperbox::eventKey(e);
        const size_t eBytes = e.dump().size();
        const size_t oldBytes = m_heldBytes.count(key) ? m_heldBytes[key] : 0;
        if (!m_heldHlc.count(key) && e.value("type", "") == RESPONSE_SUBMIT) m_logResponses++;
        m_logBytes = m_logBytes + eBytes - oldBytes;
        m_heldHlc[key] = e.value("hlc", json::object());
        m_heldBytes[key] = eBytes;
        m_clock.receive(e.value("hlc", json::object()));
        // appended to the journal at once: a local event must survive a crash right after it
        m_journalPending.push_back(e);
        flushLog();
    }
}

// ── wire v2 (ADR 0024) ───────────────────────────────────────────────────────────
// Every form lives on one of 16 bucket topics; a node joins only the buckets of forms it made,
// co-owns or opened, pulls them from Store, and sends little: the creator re-publishes a form's
// state hourly (and when asked), a respondent its answer until the receipt. No catch-up rounds,
// no serving. All /whisperbox/2 topics map to relay shard 1 of cluster 2 (autosharding).
std::string WhisperboxCoreImpl::wireTopicFor(const std::string& formId) { return formTopic(lc(formId)); }

void WhisperboxCoreImpl::broadcastEvent(const json& e) {
    // Form-state events (publish, update, close, re-open, co-owner, reply) go out as the form's state in
    // one message; it is also what the hourly re-publish sends. A receipt goes out on its own.
    if (!whisperbox::wellFormedEvent(e)) return;   // FR-9/10: never send what peers refuse
    const std::string t = e.value("type", "");
    const std::string fid = formIdOf(e);
    if (fid.empty()) return;
    if (t == RESPONSE_CONFIRM) { queueReceipt(fid, e); return; }
    const int prio = (t == RESPONSE_CONFIRM || t == whisperbox::RESPONSE_REPLY) ? 2 : 3;
    publishFormState(fid, prio);
}

// A receipt alone, never the whole form state (it used to be: O(N²) bytes with automatic receipts,
// audit W2-5). Receipts made while one is waiting in the send queue join it: one frame per form.
void WhisperboxCoreImpl::queueReceipt(const std::string& formId, const json& e) {
    auto& pend = m_rcptPending[formId];
    for (const auto& x : pend) if (x.value("id", "") == e.value("id", "")) return;
    pend.push_back(e);
    sendEvents(formId, json(pend), 2, "rcpt:" + formId);
}
// The respondent sends its answer again until it has the receipt: a copy of an answer I hold and have
// confirmed means my receipt didn't reach it - send that one receipt again (at most every 10 min)
void WhisperboxCoreImpl::resendReceiptFor(const std::string& answerId) {
    auto c = m_openCache.find(answerId);
    if (c == m_openCache.end() || !c->second.dec.is_object()) return;
    const json& dec = c->second.dec;
    const std::string cid = dec.contains("confirmationId") && dec["confirmationId"].is_string() ? dec["confirmationId"].get<std::string>() : "";
    const std::string fid = dec.contains("formId") && dec["formId"].is_string() ? lc(dec["formId"].get<std::string>()) : "";
    if (cid.empty() || fid.empty()) return;
    for (const auto& e : m_log) {
        if (e.value("type", "") != RESPONSE_CONFIRM || formIdOf(e) != fid || !e.contains("payload")) continue;
        const json& p = e["payload"];
        bool has = p.value("confirmationId", "") == cid;
        if (!has && p.contains("confirmationIds") && p["confirmationIds"].is_array())
            for (const auto& x : p["confirmationIds"]) if (x.is_string() && x.get<std::string>() == cid) { has = true; break; }
        if (!has) continue;
        const std::string rid = e.value("id", "");
        const long long now = nowMs();
        if (m_rcptResentMs.count(rid) && now - m_rcptResentMs[rid] < 10 * envLL("WHISPERBOX_MINUTE_MS", 60000LL)) return;
        m_rcptResentMs[rid] = now;
        queueReceipt(fid, e);
        return;
    }
}

// ── what this node keeps ─────────────────────────────────────────────────────────
// Václav, 2026-11-13: "we should not store forms and answers we do not care about". A bucket topic
// carries up to 1/16 of all forms; before this, every node in a bucket stored every form and answer
// in it, and strangers' answers counted against our caps (audit W2-2, 2026-11-13).
bool WhisperboxCoreImpl::baseWants(const std::string& fid) const {
    return m_watched.count(fid) || m_mySubmissions.count(fid) || m_pinned.count(fid) || m_answerDrafts.count(fid)
        || m_myAnswers.count(fid) || m_hidden.count(fid);
}
// The forms I created or co-own, and my form keys: from the fold, recomputed only when the log
// changed (a dropped stranger's event doesn't change it, so a flood never refolds)
void WhisperboxCoreImpl::refreshInterest() {
    if (m_interestGen == (long long)m_logGen) return;
    m_interestGen = (long long)m_logGen;
    m_myForms.clear(); m_myKeys.clear();
    if (!m_signId.valid) return;
    OrderedJson st = foldedState();
    for (auto it = st["forms"].begin(); it != st["forms"].end(); ++it)
        if (it.value().value("creator", "") == m_signId.address || isCoOwner(it.value())) m_myForms.insert(it.key());
    m_myKeys = formKeysFor(st);
}
bool WhisperboxCoreImpl::wanted(const json& e) {
    if (!m_signId.valid) return true;   // locked: no keys to judge with (and nothing connects until unlocked)
    const std::string t = e.value("type", "");
    if (t == RESPONSE_SUBMIT) {
        const std::string id = e.value("id", "");
        for (const auto& kv : m_myAnswers) {   // mine: kept until its receipt, and re-sent
            if (kv.second.value("eventId", "") == id) return true;
            if (kv.second.contains("earlier") && kv.second["earlier"].is_array())
                for (const auto& a : kv.second["earlier"]) if (a.is_object() && a.value("eventId", "") == id) return true;
        }
        refreshInterest();
        if (m_myKeys.empty()) return false;
        const std::string hex = e.contains("payload") && e["payload"].is_object() ? e["payload"].value("encryptedPayload", "") : "";
        if (hex.empty()) return false;
        const whisperbox::Bytes blob = whisperbox::fromHex(hex);
        for (const auto& kv : m_myKeys) {   // the budget was taken before this: it bounds the work
            try { (void)whisperbox::eciesOpen(kv.second->priv, blob); return true; } catch (...) {}
        }
        return false;
    }
    const std::string fid = formIdOf(e);
    if (fid.empty()) return false;
    if (baseWants(fid)) return true;
    if (e.contains("payload") && e["payload"].is_object()) {
        const json& p = e["payload"];
        const std::string me = lc(m_signId.address);
        if (lc(p.value("creator", "")) == me || lc(p.value("author", "")) == me) return true;   // my own
        if (t == whisperbox::FORM_COOWNER && lc(p.value("owner", "")) == me) return true;          // a key shared with me
    }
    refreshInterest();
    return m_myForms.count(fid) > 0;
}
// Drop from the log what this node no longer keeps (on start, after unlock, after a form is removed)
void WhisperboxCoreImpl::pruneUnwanted() {
    if (!m_signId.valid || m_log.empty()) return;
    refreshInterest();   // from the whole log, before anything goes: my own events always stay
    std::vector<json> kept; kept.reserve(m_log.size());
    size_t dropped = 0;
    for (auto& e : m_log) { if (wanted(e)) kept.push_back(std::move(e)); else dropped++; }
    if (!dropped) { m_log = std::move(kept); return; }
    m_log = std::move(kept);
    std::set<std::string> ids;
    for (const auto& e : m_log) ids.insert(e.value("id", ""));
    for (auto* m : {&m_netTimes, &m_firstSeen})
        for (auto it = m->begin(); it != m->end();) it = ids.count(it->first) ? std::next(it) : m->erase(it);
    recountLog();
    m_foldValid = false; m_cvValid = false; m_openCache.clear();
    saveLog(); saveNetTimes(); saveFirstSeen();
    fprintf(stderr, "WHISPERBOX pruned %zu events of forms this node doesn't keep (%zu left)\n", dropped, m_log.size());
}

std::set<std::string> WhisperboxCoreImpl::relevantForms() {
    std::set<std::string> out(m_watched.begin(), m_watched.end());
    for (const auto& f : m_mySubmissions) out.insert(f);
    for (const auto& kv : m_pinned) out.insert(kv.first);
    for (const auto& kv : m_answerDrafts) out.insert(kv.first);
    for (const auto& kv : m_myAnswers) out.insert(kv.first);
    if (m_signId.valid) {
        OrderedJson st = foldedState();
        for (auto it = st["forms"].begin(); it != st["forms"].end(); ++it)
            if (it.value().value("creator", "") == m_signId.address || isCoOwner(it.value())) out.insert(it.key());
    }
    return out;
}

// A bucket no kept form is in any more: forget it, so it isn't Store-pulled again. Neither
// delivery_module nor loam_core can unsubscribe, so live frames still arrive until the next start;
// wanted() drops them (audit W2-9).
void WhisperboxCoreImpl::dropUnusedBuckets() {
    std::set<std::string> want;
    for (const auto& f : relevantForms()) want.insert(formTopic(f));
    bool changed = false;
    for (auto it = m_joinedTopics.begin(); it != m_joinedTopics.end();)
        if (isWireTopic(*it) && !want.count(*it)) { it = m_joinedTopics.erase(it); changed = true; } else ++it;
    for (auto it = m_lastPullMs.begin(); it != m_lastPullMs.end();)
        if (!want.count(it->first)) { it = m_lastPullMs.erase(it); changed = true; } else ++it;
    if (changed) savePulls();
}

void WhisperboxCoreImpl::syncTopics() {
    if (!m_nodeReady) return;
    std::set<std::string> want;
    for (const auto& f : relevantForms()) want.insert(formTopic(f));
    for (const auto& t : want) {
        if (m_joinedTopics.count(t)) continue;
        if (m_via == Via::Direct) { if (!m_direct || !m_direct->t) continue; m_direct->t->join(t); }
        else {
            auto life = m_life;
            modules().loam_core.joinAsync(t, [life, t](std::string r) {
                if (r.find("\"ok\":false") == std::string::npos && r.find("error") == std::string::npos) return;
                withSelf(life, [t](WhisperboxCoreImpl* self) { std::lock_guard<std::recursive_mutex> lk(self->m_mtx); self->m_joinedTopics.erase(t); });
            });
        }
        m_joinedTopics.insert(t);
        storePull(t);   // a bucket we hadn't held: what's there from before we listened
    }
    m_subscribed = !m_joinedTopics.empty();
}

// One queue for everything sent, drained within the node's RLN budget: WhisperBox takes at most
// WHISPERBOX_MSGS_PER_EPOCH (default 10) of the 100 messages a node may send per 600 s epoch.
// Lower prio = sooner: 1 answer, 2 receipt/reply, 3 form change / answering an ASK, 4 ASK,
// 5 scheduled re-publish, 6 answer retry. A message queued again under the same key replaces
// the queued one (newest content, most urgent priority).
void WhisperboxCoreImpl::enqueueSend(int prio, const std::string& topic, const json& env, const std::string& key) {
    std::string text = whisperbox::eventToJsonText(env);
    for (auto& m : m_outQ) if (!key.empty() && m.key == key) { m.text = std::move(text); m.topic = topic; m.prio = std::min(m.prio, prio); return; }
    m_outQ.push_back(OutMsg{prio, m_outSeq++, topic, std::move(text), key});
    drainSendQueue();
}
void WhisperboxCoreImpl::drainSendQueue() {
    if (!m_nodeReady || m_outQ.empty()) return;
    const double perEpoch = (double)envLL("WHISPERBOX_MSGS_PER_EPOCH", 10);
    const int64_t now = nowMs();
    if (m_rlnRefillMs == 0) { m_rlnRefillMs = now; m_rlnTokens = perEpoch; }
    m_rlnTokens = std::min(perEpoch, m_rlnTokens + double(now - m_rlnRefillMs) * perEpoch / 600000.0);
    m_rlnRefillMs = now;
    while (m_rlnTokens >= 1 && !m_outQ.empty()) {
        auto best = std::min_element(m_outQ.begin(), m_outQ.end(), [](const OutMsg& a, const OutMsg& b) { return a.prio != b.prio ? a.prio < b.prio : a.seq < b.seq; });
        OutMsg m = std::move(*best);
        m_outQ.erase(best);
        // receipts leave the pending set as they leave the queue; a refused send puts them back, so a
        // later receipt for the form re-queues them together
        const std::string rf = m.key.rfind("rcpt:", 0) == 0 ? m.key.substr(5, m.key.find('#') == std::string::npos ? std::string::npos : m.key.find('#') - 5) : "";
        if (!rf.empty()) m_rcptPending.erase(rf);
        m_sending = m;
        const bool ok = deliverySend(m.topic, whisperbox::b64encode(m.text));
        m_sending = OutMsg{};
        if (ok) { m_txTotal++; m_rlnTokens -= 1; }
        else {
            if (!rf.empty()) {
                json env = json::parse(m.text, nullptr, false);
                auto& pend = m_rcptPending[rf];
                if (env.is_object() && env.contains("events") && env["events"].is_array())
                    for (const auto& e : env["events"]) {
                        bool have = false; for (const auto& x : pend) if (x.value("id", "") == e.value("id", "")) { have = true; break; }
                        if (!have) pend.push_back(e);
                    }
            }
            m_outQ.push_back(std::move(m)); break;   // transport not taking it: try on the next tick
        }
    }
}
// events -> EVENTS frames on the form's topic, split to stay under Delivery's 150 KiB message cap once
// base64'd twice (audit W2-1: the old 120,000 counted the JSON, not what goes on the wire)
void WhisperboxCoreImpl::sendEvents(const std::string& formId, const json& events, int prio, const std::string& key) {
    static constexpr size_t kMaxBundle = whisperbox::kMaxWireEventBytes;
    json chunk = json::array(); size_t bytes = 0; int part = 0;
    auto flush = [&] {
        if (chunk.empty()) return;
        enqueueSend(prio, formTopic(formId), json({{"v", 2}, {"type", "EVENTS"}, {"events", chunk}}), part == 0 ? key : key + "#" + std::to_string(part));
        part++; chunk = json::array(); bytes = 0;
    };
    for (const auto& e : events) {
        const size_t n = e.dump().size();
        // one event too big for any frame (an old one, from before the limit): never sent, said so
        if (n > kMaxBundle) { m_txDropped++; fprintf(stderr, "WHISPERBOX can't send %s: %zu bytes is over the wire limit\n", e.value("id", "?").c_str(), n); continue; }
        if (bytes + n > kMaxBundle) flush();
        chunk.push_back(e); bytes += n;
    }
    flush();
}
// The form's state as its creator side knows it: the creator's publish and edits, close and re-open,
// co-owner grants and replies - not receipts (they go on their own, see queueReceipt). Peers check
// each event as from the network.
void WhisperboxCoreImpl::publishFormState(const std::string& formId, int prio) {
    OrderedJson st = foldedState();
    if (!st["forms"].contains(formId)) return;
    const auto& f = st["forms"][formId];
    const std::string creator = f.value("creator", "");
    std::set<std::string> authors = {creator};
    if (f.contains("coOwners") && f["coOwners"].is_array()) for (const auto& c : f["coOwners"]) if (c.is_object()) authors.insert(lc(c.value("address", "")));
    json events = json::array();
    for (const auto& e : m_log) {
        const std::string t = e.value("type", "");
        if (t == RESPONSE_SUBMIT || t == RESPONSE_CONFIRM || formIdOf(e) != formId || !e.contains("payload")) continue;   // receipts go on their own
        const std::string author = lc(t == FORM_PUBLISH ? e["payload"].value("creator", "") : e["payload"].value("author", ""));
        if (t == FORM_PUBLISH ? author != creator : !authors.count(author)) continue;
        if (t == FORM_PUBLISH) events.insert(events.begin(), e); else events.push_back(e);
    }
    if (events.empty()) return;
    syncTopics();   // the creator side listens on the form's bucket from its first publish (answers)
    m_formSentMs[formId] = nowMs();
    sendEvents(formId, events, prio, "form:" + formId);
}

void WhisperboxCoreImpl::onAsk(const json& env) {
    const std::string fid = env.contains("formId") && env["formId"].is_string() ? lc(env["formId"].get<std::string>()) : std::string();
    if (fid.empty() || fid.size() > 128) return;
    OrderedJson st = foldedState();
    if (!st["forms"].contains(fid)) return;
    const auto& f = st["forms"][fid];
    // only the creator side answers, at most once per form per 10 min whoever asked
    if (!(m_signId.valid && f.value("creator", "") == m_signId.address) && !isCoOwner(f)) return;
    // its own limit: an ASK right after a publish still gets an answer (Store may have missed it)
    if (m_askAnsweredMs.count(fid) && nowMs() - m_askAnsweredMs[fid] < 10 * envLL("WHISPERBOX_MINUTE_MS", 60000LL)) return;
    m_askAnsweredMs[fid] = nowMs();
    publishFormState(fid, 3);
}

void WhisperboxCoreImpl::loadPulls() {
    m_lastPullMs.clear();
    std::ifstream f(m_dataDir + "/pulls.json");
    if (!f) return;
    try { json j = json::parse(f); if (j.is_object()) for (auto it = j.begin(); it != j.end(); ++it) if (it.value().is_number_integer()) m_lastPullMs[it.key()] = it.value().get<long long>(); } catch (...) {}
}
void WhisperboxCoreImpl::savePulls() {
    json j = json::object(); for (const auto& kv : m_lastPullMs) j[kv.first] = kv.second;
    writeAtomic(m_dataDir + "/pulls.json", j.dump());
}

// Store: what was published on a bucket since we last looked (at most 6 h back; Store keeps 1-2 h
// for sure). Queries cost no RLN. Peers: getNodeInfo("StoreNodes") where Delivery has it, else
// the preset's fleet (logos-co/logos-delivery-module#187 asks for a query-any-peer call).
void WhisperboxCoreImpl::storePull(const std::string& topic) {
    m_pullWant.insert(topic);
    kickPull();
}
void WhisperboxCoreImpl::storePullAll() {
    m_lastPullRoundMs = nowMs();
    m_pullRetryAt = 0;   // start, reconnect or resync: don't wait for a failed pull's retry
    for (const auto& t : m_joinedTopics) m_pullWant.insert(t);
    kickPull();
}
// One Store query at a time, for every bucket that wants one (Store takes a list of content topics):
// nine parallel queries overran the module's IPC timeout and one flaky Store peer failed them all
// (live test 2026-11-12). A failed query moves to the next Store peer and is tried again in 20 s.
void WhisperboxCoreImpl::kickPull() {
    if (!m_nodeReady || m_pullBusy || m_pullWant.empty()) return;
    if (m_pullRetryAt && nowMs() < m_pullRetryAt) return;
    auto life = m_life;
    if (m_storePeers.empty()) {
        m_storePeers = {
            "/dns4/node-01.gc-us-central1-a.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmF8WtwGPmeGHgYAX2277jHgy5cW9F7zsB8EqUjBZQAZQ3",
            "/dns4/node-01.do-ams3.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmQ9X2xDfPG3uL77V9piYDhjq14JhKCtcmNYsTMKNqrKCj",
            "/dns4/node-02.gc-us-central1-a.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmUuXhUW9bdJpzN1kfDziFiUZo4bszTk66cvr7uuyCHXR7",
            "/dns4/node-02.do-ams3.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmB8NYprrfQrgWVzsJtYWkfjsXbmJEGNMG6othXsQ53BwG",
            "/dns4/node-01.ac-cn-hongkong-c.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmL3oU95jh1BZHozn3uNhx8HEneirgr8M1jEAapzXGDqRF",
            "/dns4/node-02.ac-cn-hongkong-c.logos.test.status.im/tcp/30303/p2p/16Uiu2HAm28CoBZjpyxsanC8tQpbvZ7bZJnVYuB1EgFzb571qpWsV"};
        if (const char* ov = std::getenv("WHISPERBOX_STORE_PEERS")) {
            std::vector<std::string> mine; std::stringstream ss(ov); std::string a;
            while (std::getline(ss, a, ',')) if (!trim(a).empty()) mine.push_back(trim(a));
            if (!mine.empty()) m_storePeers = std::move(mine);   // empty or only commas: keep the fleet (audit W2-12: % 0)
        }
        if (!m_storePeersAsked) {
            m_storePeersAsked = true;
            try {
                modules().delivery_module.getNodeInfoAsync("StoreNodes", [life](StdLogosResult r) {
                    if (!r.success) return;
                    const std::string v = r.value.is_string() ? r.value.get<std::string>() : r.value.dump();
                    json arr = json::parse(v, nullptr, false);
                    if (!arr.is_array() || arr.empty()) return;
                    withSelf(life, [arr](WhisperboxCoreImpl* self) {
                        std::lock_guard<std::recursive_mutex> lk(self->m_mtx);
                        std::vector<std::string> peers; for (const auto& a : arr) if (a.is_string()) peers.push_back(a.get<std::string>());
                        if (!peers.empty()) { self->m_storePeers = peers; self->m_storePeerIx = 0; }
                    });
                });
            } catch (...) {}
        }
    }
    const long long now = nowMs();
    // at most 10 content topics per query: Delivery's Store refuses more (Rumor specs, batch_topics);
    // the rest wait in m_pullWant for the next query
    std::vector<std::string> topics;
    for (auto it = m_pullWant.begin(); it != m_pullWant.end() && topics.size() < 10;) { topics.push_back(*it); it = m_pullWant.erase(it); }
    long long since = now - 6LL * 3600000LL;
    {   // from the least recently pulled of them (5 min overlap), at most 6 h back
        long long oldest = now;
        for (const auto& t : topics) oldest = std::min(oldest, m_lastPullMs.count(t) ? m_lastPullMs[t] : 0LL);
        since = std::max(since, oldest - 5LL * 60000LL);
    }
    m_pullBusy = true;
    m_pullStartedMs = now;
    const std::string peer = m_storePeers[m_storePeerIx % m_storePeers.size()];
    fprintf(stderr, "WHISPERBOX store pull %zu bucket(s) from %lld s ago\n", topics.size(), (now - since) / 1000);
    auto page = std::make_shared<std::function<void(std::string, int)>>();
    *page = [this, life, topics, since, now, peer, page](std::string cursor, int n) {
        json q = {{"requestId", "wb-" + randomHex(4)}, {"includeData", true}, {"paginationForward", true}, {"pubsubTopic", kWireShard},
                  {"contentTopics", topics}, {"timeStart", since * 1000000LL}, {"timeEnd", (now + 60000LL) * 1000000LL}, {"paginationLimit", 100}};
        if (!cursor.empty()) q["paginationCursor"] = cursor;
        try {
            modules().delivery_module.storeQueryAsync(q.dump(), peer, 15000, [life, topics, now, page, n](StdLogosResult r) {
                withSelf(life, [r, topics, now, page, n](WhisperboxCoreImpl* self) {
                    std::lock_guard<std::recursive_mutex> lk(self->m_mtx);
                    json v;
                    if (r.success) { v = r.value.is_string() ? json::parse(r.value.get<std::string>(), nullptr, false) : json::parse(r.value.dump(), nullptr, false); }
                    if (!r.success || !v.is_object() || v.value("statusCode", 0) != 200) {
                        self->m_pullBusy = false;
                        self->m_storePeerIx++;   // another Store peer, in 20 s
                        for (const auto& t : topics) self->m_pullWant.insert(t);
                        self->m_pullFailures++;
                        // a full pull asked for while this one ran (reconnect, resync): go again at once
                        const bool asked = self->m_lastPullRoundMs >= self->m_pullStartedMs;
                        self->m_pullRetryAt = asked || self->m_pullFailures >= 6 ? 0 : nowMs() + 20000;
                        if (!asked && self->m_pullFailures >= 6) { self->m_pullFailures = 0; self->m_pullWant.clear(); }   // the 15-min round tries again
                        if (asked) self->onLoop([self] { std::lock_guard<std::recursive_mutex> lk2(self->m_mtx); self->kickPull(); });
                        fprintf(stderr, "WHISPERBOX store pull failed: %s\n", r.success ? v.dump().substr(0, 160).c_str() : r.error.c_str());
                        return;
                    }
                    // A Store reply is untrusted input (audit W2-3): only the topics we asked for, at most
                    // a page's worth (we ask for 100), and its events go through the same admission,
                    // the keep-filter and caps; an ASK in it is never acted on.
                    if (v.contains("messages") && v["messages"].is_array()) {
                        size_t taken = 0;
                        for (const auto& m : v["messages"]) {
                            if (!m.is_object() || !m.contains("message") || !m["message"].is_object()) continue;
                            const json& wm = m["message"];
                            if (!wm.contains("payload") || !wm["payload"].is_string()) continue;
                            const std::string ct = wm.contains("contentTopic") && wm["contentTopic"].is_string() ? wm["contentTopic"].get<std::string>() : std::string();
                            if (std::find(topics.begin(), topics.end(), ct) == topics.end()) { self->m_storeDropTopic++; continue; }
                            if (++taken > 100) { self->m_storeDropCap++; continue; }
                            long long ts = wm.contains("timestamp") && wm["timestamp"].is_number() ? (long long)wm["timestamp"].get<double>() : 0;
                            self->ingestEnvelopeText(wm["payload"].get<std::string>(), false, netMsOf(ts, nowMs(), /*fromStore=*/true));
                        }
                    }
                    const std::string next = v.contains("paginationCursor") && v["paginationCursor"].is_string() ? v["paginationCursor"].get<std::string>() : std::string();
                    if (!next.empty() && n < 20) { (*page)(next, n + 1); return; }
                    self->m_pullBusy = false;
                    self->m_pullFailures = 0; self->m_pullRetryAt = 0;
                    fprintf(stderr, "WHISPERBOX store pull done (%zu bucket(s), %d page(s))\n", topics.size(), n + 1);
                    for (const auto& t : topics) self->m_lastPullMs[t] = now;
                    self->savePulls();
                    self->flushLog();
                    self->publishState();
                    self->kickPull();   // buckets that wanted a pull meanwhile
                });
            });
        } catch (...) { m_pullBusy = false; for (const auto& t : topics) m_pullWant.insert(t); }
    };
    (*page)("", 0);
}

// The wire's schedule, every few seconds while the node is up (ADR 0024, "Schedules").
void WhisperboxCoreImpl::wireSchedule() {
    if (!m_nodeReady) return;
    syncTopics();
    const long long now = nowMs();
    const long long minute = envLL("WHISPERBOX_MINUTE_MS", 60000LL);   // tests shrink time
    const long long hour = envLL("WHISPERBOX_REPUBLISH_MS", 60 * minute);
    OrderedJson st = foldedState();
    // creator: re-publish open forms hourly (±10% per form), a closed one 3 times
    for (auto it = st["forms"].begin(); it != st["forms"].end(); ++it) {
        const std::string fid = it.key();
        const auto& f = it.value();
        if (!(m_signId.valid && f.value("creator", "") == m_signId.address)) continue;
        const int jitter = (int)(std::hash<std::string>{}(fid) % 21) - 10;   // -10..+10 %
        const long long every = hour + hour * jitter / 100;
        const bool closed = f.value("status", "open") != "open";
        if (closed && m_formClosedSends[fid] >= 3) continue;
        if (now - m_formSentMs[fid] < every) continue;
        if (closed) m_formClosedSends[fid]++;
        publishFormState(fid, 5);
    }
    // respondent: a form opened from a link that hasn't arrived - ASK after 20 s, 10 min, 30 min,
    // then hourly (for a day)
    for (const auto& fid : m_watched) {
        // held - unless it is someone else's form under that id and the link names another creator:
        // keep asking for the real one (audit W2-7: a squatted id silenced the ASK)
        const auto pin = m_pinned.find(fid);
        const bool have = st["forms"].contains(fid) && (pin == m_pinned.end() || pin->second.empty() || lc(st["forms"][fid].value("creator", "")) == lc(pin->second));
        if (have) { m_askCount.erase(fid); continue; }
        if (!m_askSentMs.count(fid)) m_askSentMs[fid] = now;   // first seen: give Store a moment (20 s)
        const int n = m_askCount[fid];
        const long long gap = n == 0 ? minute / 3 : n == 1 ? 10 * minute : n == 2 ? 20 * minute : 60 * minute;
        if (n >= 26 || now - m_askSentMs[fid] < gap) continue;
        m_askSentMs[fid] = now; m_askCount[fid] = n + 1;
        enqueueSend(4, formTopic(fid), json({{"v", 2}, {"type", "ASK"}, {"formId", fid}}), "ask:" + fid);
    }
    // respondent: each answer again until its receipt - every 10 min for an hour, hourly for 4 h,
    // then every 6 h, for 14 days
    static const long long kRetryAt[] = {10, 20, 30, 40, 50, 110, 170, 230, 290};   // minutes after sending
    bool dirty = false;
    for (auto& kv : m_myAnswers) {
        const std::string fid = kv.first;
        if (!st["forms"].contains(fid)) continue;
        const auto& conf = st["forms"][fid]["confirmations"];
        auto handle = [&](json& a) {
            const std::string eid = a.value("eventId", ""), cid = a.value("confirmationId", "");
            if (eid.empty() || cid.empty() || containsStr(conf, cid)) return;
            const long long first = a.value("submittedAt", 0LL);
            if (first <= 0 || now - first > 14LL * 24 * 60 * minute) return;
            const int n = a.value("retries", 0);
            const long long dueAt = !a.value("sent", false) ? 0 : first + minute * (n < 9 ? kRetryAt[n] : 290 + 360LL * (n - 8));
            if (now < dueAt) return;
            for (const auto& e : m_log) if (e.value("id", "") == eid) {
                sendEvents(fid, json::array({e}), a.value("sent", false) ? 6 : 1, "ans:" + eid);
                if (a.value("sent", false)) a["retries"] = n + 1; else a["sent"] = true;
                dirty = true;
                break;
            }
        };
        handle(kv.second);
        if (kv.second.contains("earlier") && kv.second["earlier"].is_array()) for (auto& e : kv.second["earlier"]) if (e.is_object()) handle(e);
    }
    if (dirty) saveMyAnswers();
    // Store: every 15 min (and on start / reconnect)
    if (now - m_lastPullRoundMs >= envLL("WHISPERBOX_PULL_MS", 15 * minute)) storePullAll();
    kickPull();   // a pull waiting for its retry
    drainSendQueue();
}

// Send an event on behalf of a peer that lacks it. Serving has a budget, and an event served a
// moment ago (the same frame over two bearers, a burst of identical asks) isn't sent again: a 40-byte
// "ids" frame used to make the node re-broadcast its whole log, every time it came (open-review
// FR-3). The window is short on purpose: a second peer catching up a few seconds later must still be
// served. A peer that misses out gets it on its next catch-up round.
// A token bucket: budgetPerMin a minute, a burst of the same. False = over budget.
bool WhisperboxCoreImpl::takeToken(double& tokens, int64_t& refillMs, double budgetPerMin) {
    const int64_t now = nowMs();
    if (refillMs == 0) { refillMs = now; tokens = budgetPerMin; }
    tokens = std::min(budgetPerMin, tokens + double(now - refillMs) * budgetPerMin / 60000.0);
    refillMs = now;
    if (tokens < 1) return false;
    tokens -= 1;
    return true;
}

bool WhisperboxCoreImpl::serveEvent(const json& e) {
    static constexpr int64_t kServeCooldownMs = 2000;
    static constexpr double kServeBudget = 300;   // events a minute, a burst of the same
    const int64_t now = nowMs();
    const std::string key = whisperbox::eventKey(e);
    auto it = m_servedMs.find(key);
    if (it != m_servedMs.end() && now - it->second < kServeCooldownMs) { m_serveSkipped++; return false; }
    if (m_serveRefillMs == 0) { m_serveRefillMs = now; m_serveTokens = kServeBudget; }
    m_serveTokens = std::min(kServeBudget, m_serveTokens + double(now - m_serveRefillMs) * kServeBudget / 60000.0);
    m_serveRefillMs = now;
    if (m_serveTokens < 1) { m_serveSkipped++; return false; }
    m_serveTokens -= 1;
    if (m_servedMs.size() > 4096)   // only the cooldown window matters: forget the rest
        for (auto s = m_servedMs.begin(); s != m_servedMs.end();) s = now - s->second >= kServeCooldownMs ? m_servedMs.erase(s) : std::next(s);
    m_servedMs[key] = now;
    broadcastEvent(e);
    return true;
}

// One event from the network (a live frame, a Store page or a bundle): the cheap checks, the budget,
// the signature, then the merge. True when it was new.
bool WhisperboxCoreImpl::ingestOne(json e, long long netMs, bool live, bool bundled) {
            // The cheap checks, then the budget, then the signature: a forged signature used to cost a
            // full verification before any budget was taken (open-review 2026-11-03, FR-6).
            if (!whisperbox::wellFormedEvent(e)) { m_admDropShape++; return false; }
            if (e["hlc"]["wall"].get<long long>() > nowMs() + whisperbox::kMaxClockLeadMs) { m_admDropFuture++; return false; }
            // Unsigned answers: anyone can send any number of them, so answers have a node-wide
            // budget and the log a cap (open-review 2026-11-01, FR-3). Every copy costs, a replayed one
            // too (2026-11-02, FR-6), and signed events have their own budget (2026-11-02, FR-2). A peer
            // that missed out gets the rest on a later catch-up round.
            const bool isResp = e.value("type", "") == RESPONSE_SUBMIT;
            const std::string key = whisperbox::eventKey(e);
            auto held = m_heldHlc.find(key);
            // An answer we hold is never replaced: its HLC is the sender's and unsigned, and an earlier
            // copy reordered answers (2026-11-03, FR-3). A signed event may be replaced by an
            // earlier-HLC copy (the merge rule), and is charged for its size (FR-1).
            const bool dup = held != m_heldHlc.end() && (isResp || whisperbox::compareHlc(e["hlc"], held->second) >= 0);
            // The flood budget is for live frames; a Store pull is bounded by our own paging (ADR 0024).
            // In a bundle (a form's hourly state) a copy we hold costs nothing - the frame paid once.
            if (live && !(bundled && dup) && !(isResp ? takeToken(m_respTokens, m_respRefillMs, 600) : takeToken(m_sigTokens, m_sigRefillMs, 600))) { m_admDropBudget++; return false; }
            if (dup) {   // known without a scan of the log, and without verifying it again
                m_rxDup++;
                if (isResp) resendReceiptFor(e.value("id", ""));   // a retry: the receipt didn't reach the respondent
                if (noteNetTime(e, netMs)) { m_publishDirty = true; scheduleFlush(); }
                return false;
            }
            if (!wanted(e)) { m_admDropUnwanted++; return false; }   // not a form or answer of mine: never stored
            if (!admitEvent(e)) return false;   // the signature (counted)
            const bool replaced = held != m_heldHlc.end();
            const size_t eBytes = e.dump().size();
            const size_t oldBytes = replaced && m_heldBytes.count(key) ? m_heldBytes[key] : 0;
            const size_t grow = eBytes > oldBytes ? eBytes - oldBytes : 0;
            // the caps apply to a replacement too: a small event replaced by a large one used to grow
            // the log without bound (FR-1)
            if (isResp ? (m_logResponses >= kMaxLogResponses || m_logBytes + grow > kMaxLogBytes)
                       : (grow > 0 && m_logBytes + grow > kMaxLogBytes + kLogReserveBytes)) { m_admDropFull++; return false; }
            noteNetTime(e, netMs);
            if (!whisperbox::mergeOne(m_log, e)) { m_rxDup++; return false; }
            m_heldHlc[key] = e["hlc"];
            m_heldBytes[key] = eBytes;
            m_logBytes = m_logBytes + eBytes - oldBytes;
            if (!replaced && isResp) m_logResponses++;
            if (isResp) noteFirstSeen(e);
            m_logGen++;
            // made a co-owner: the answers sent before were dropped (I couldn't open them then) - pull
            // the form's bucket again over the whole Store window (Václav 2026-11-13: keep only mine)
            if (e.value("type", "") == whisperbox::FORM_COOWNER && m_signId.valid && e.contains("payload")
                && lc(e["payload"].value("owner", "")) == lc(m_signId.address) && m_nodeReady) {
                const std::string t = formTopic(formIdOf(e));
                m_lastPullMs.erase(t); syncTopics(); storePull(t);
            }
            m_rxNew++;
            m_clock.receive(e["hlc"], nowMs() + whisperbox::kMaxClockLeadMs);
            m_journalPending.push_back(e);
            m_logDirty = true; m_publishDirty = true; scheduleFlush();
            return true;
        
}

// ── ingest (receive path) ────────────────────────────────────────────────────────
void WhisperboxCoreImpl::ingestEnvelopeText(const std::string& text, bool channelPath, long long netMs) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    m_rxRaw++;
    if (channelPath) m_rxSeen++;
    // a frame past the size cap is refused before any decoding (base64, maybe twice: 16/9 of the bytes)
    if (text.size() > whisperbox::kMaxFrameBytes * 2) { m_rxBad++; return; }
    // The wire payload is base64 text; a peer may single- OR double-encode. Try the
    // double-peel first, then a single peel (qaku convention).
    auto tryText = [this, netMs, channelPath](const std::string& t) -> bool {
        json env = whisperbox::parseEnvelope(t);
        if (!env.is_object() || !env.contains("type") || !env["type"].is_string()) return false;
        const std::string type = env["type"].get<std::string>();
        // v1 catch-up (RBSR, SYNC_REQ): not answered any more - nobody serves anybody (ADR 0024)
        if (type == "RBSR" || type == "SYNC_REQ") return true;
        if (type == "EVENT" && env.contains("event")) { ingestOne(env["event"], netMs, channelPath, false); return true; }
        // wire v2 (ADR 0024): a form's state or an answer as one frame of events
        if (type == "EVENTS" && env.contains("events") && env["events"].is_array()) {
            if (env["events"].size() > 2000) { m_rxBad++; return true; }
            if (channelPath && !takeToken(m_ctlTokens, m_ctlRefillMs, 120)) { m_ctlDropBudget++; return true; }   // a frame budget
            for (const auto& e : env["events"]) { try { ingestOne(e, netMs, channelPath, true); } catch (...) { m_rxBad++; } }
            return true;
        }
        if (type == "ASK") {   // a live ASK only, and it costs a frame token (audit W2-3/W2-6)
            if (!channelPath) return true;
            if (!takeToken(m_ctlTokens, m_ctlRefillMs, 120)) { m_ctlDropBudget++; return true; }
            onAsk(env); return true;
        }
        return false;
    };
    std::string once = whisperbox::b64decode(text);
    if (tryText(whisperbox::b64decode(once))) return;   // double peel
    if (tryText(whisperbox::b64decode(whisperbox::b64decode(once)))) return;   // Store payload of a Loam send
    if (tryText(once)) return;                           // single peel
    if (channelPath) fprintf(stderr, "WHISPERBOXRX ingest OPENFAIL plen=%zu\n", text.size());
} catch (const std::exception& ex) {
    // A frame that throws while it's processed is counted and dropped (review 2026-10-22, WB-1). This
    // catches exceptions, not stack exhaustion: that is prevented by the size and depth limits on the
    // envelope (parseEnvelope) and on everything decrypted (parseUntrusted), open-review FR-1.
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    m_rxBad++;
    fprintf(stderr, "WHISPERBOXRX dropped a frame that failed to process: %s\n", ex.what());
} catch (...) {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    m_rxBad++;
}

// ADR 0019: keep the earliest network time per answer. A copy re-served during catch-up is published
// again (a later time) and a store copy keeps the original, so the earliest is the closest to when the
// respondent sent it. True when it moved earlier.
bool WhisperboxCoreImpl::noteNetTime(const json& e, long long netMs) {
    if (netMs <= 0 || e.value("type", "") != RESPONSE_SUBMIT) return false;
    const std::string id = e.value("id", "");
    auto it = m_netTimes.find(id);
    if (it != m_netTimes.end() && it->second <= netMs) return false;
    m_netTimes[id] = netMs;
    m_netTs++;
    m_netGen++;
    m_netDirty = true; scheduleFlush();   // saved with the next flush, not per copy (FR-6)
    return true;
}
// When this device first saw an answer (local clock, kept, never synced): the time an answer with no
// network time is judged by against a close (open-review 2026-11-03, FR-3).
void WhisperboxCoreImpl::noteFirstSeen(const json& e) {
    const std::string id = e.value("id", "");
    if (id.empty() || m_firstSeen.count(id)) return;
    m_firstSeen[id] = nowMs();
    m_netGen++;
    m_firstDirty = true; scheduleFlush();
}
void WhisperboxCoreImpl::saveFirstSeen() {
    json o = json::object(); for (auto& kv : m_firstSeen) o[kv.first] = kv.second;
    writeAtomic(m_dataDir + "/firstseen.json", o.dump());
}
void WhisperboxCoreImpl::saveNetTimes() {
    json o = json::object(); for (auto& kv : m_netTimes) o[kv.first] = kv.second;
    writeAtomic(m_dataDir + "/nettime.json", o.dump());
}

// Admission gates at merge (PLAN 3.4): drop violators, counted, not fatal.
bool WhisperboxCoreImpl::admitEvent(const json& e) {
    // Shape first: a wrongly-typed field must never reach the fold (WB-1/WB-9/WB-11).
    if (!whisperbox::wellFormedEvent(e)) { m_admDropShape++; return false; }
    // A peer's clock may lead ours by a few minutes, not by centuries (WB-3).
    if (e["hlc"]["wall"].get<long long>() > nowMs() + whisperbox::kMaxClockLeadMs) { m_admDropFuture++; return false; }
    const std::string type = e.value("type", "");
    if (type == FORM_PUBLISH) {
        // Creator-gated by signature: must verify AND the recovered address must be
        // payload.creator (verifyEvent does both). Unsigned publishes are dropped —
        // forms are public, but authorship is not optional.
        if (!whisperbox::verifyEventJson(e)) { m_admDropSig++; return false; }
        // the key answers are sealed to must be a real point: an invalid one meant an all-zero
        // shared secret, so anyone could read the answers (open-review FR-4)
        const std::string pk = e["payload"].value("publicKey", "");
        if (!pk.empty() && !whisperbox::validPubPoint(whisperbox::fromHex(pk))) { m_admDropShape++; return false; }
        return true;
    }
    if (type == RESPONSE_CONFIRM || type == FORM_CLOSE || type == whisperbox::FORM_REOPEN || type == whisperbox::FORM_UPDATE || type == whisperbox::FORM_COOWNER || type == whisperbox::RESPONSE_REPLY) {
        if (!whisperbox::verifyEventJson(e)) { m_admDropSig++; return false; }
        return true;   // not-creator is also dropped at fold time (engine, counted there)
    }
    if (type == RESPONSE_SUBMIT) {
        // OPAQUE: an event-level pub/sig here would leak the respondent's identity —
        // reject such events outright (privacy invariant).
        if (e.contains("pub") && e["pub"].is_string() && !e["pub"].get<std::string>().empty()) { m_admDropSig++; return false; }
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
    // The fold, cached until the log, pins or identity change. Signatures were checked at
    // admission and at load, once (open-review 2026-11-02, FR-2).
    const OrderedJson& full = foldedState();

    // Creator view: decrypt the response pool with our key, then mark each
    // response confirmed by matching its receipt id against the public set
    // (module layer, NOT the engine - keeps the TS/C++ engine parity intact).
    // Only counts and receipt state go out: the snapshot is also the stateChanged event, which any
    // module in the same Basecamp can receive. Answers, respondents, scores, my own answers, my
    // replies and quiz keys come from formDetail(formId), for the form the view shows (open-review
    // 2026-11-03, FR-2). Scoring every answer of every form on every snapshot is gone too (FR-12).
    json creatorViewJson;
    if (m_signId.valid && (full["creator"] != nullptr || !coOwnedForms(full).empty())) {
        OrderedJson cv = decryptView(full);
        creatorViewJson = json::object();
        creatorViewJson["address"] = cv["address"];
        creatorViewJson["forms"] = cv["forms"];
        creatorViewJson["dropped"] = cv["dropped"];          // counts per reason
        creatorViewJson["undecrypted"] = cv["undecrypted"];
        creatorViewJson["confirmations"] = cv["confirmations"];   // public receipt ids
        json counts = json::object();
        for (auto it = cv["responses"].begin(); it != cv["responses"].end(); ++it) {
            const std::string fid = it.key();
            std::unordered_set<std::string> confs;
            if (full["forms"].contains(fid)) for (const auto& c : full["forms"][fid]["confirmations"]) if (c.is_string()) confs.insert(c.get<std::string>());
            json arr = json::array();
            for (const auto& r : it.value()) {
                json rj = json::parse(r.dump());
                arr.push_back({{"confirmed", confs.count(confirmIdOf(rj, fid)) > 0},
                               {"verified", !(rj.contains("verified") && rj["verified"].is_boolean() && !rj["verified"].get<bool>())}});
            }
            counts[fid] = arr;
        }
        creatorViewJson["responses"] = counts;
    }

    // Only the forms this device shows: mine, co-owned, answered, opened from a link, hidden or
    // pinned. Every form anyone published on the topic used to go to the view on every poll
    // (50,000 forms = 27 MB a snapshot, open-review 2026-11-02, FR-5/FR-7); the views list
    // nothing else anyway (no public directory).
    std::unordered_set<std::string> shown;
    for (auto it = full["forms"].begin(); it != full["forms"].end(); ++it) {
        const std::string& fid = it.key();
        if ((!me.empty() && it.value()["creator"].get<std::string>() == me) || m_watched.count(fid) || m_mySubmissions.count(fid)
            || m_hidden.count(fid) || m_pinned.count(fid) || m_answerDrafts.count(fid) || isCoOwner(it.value())) shown.insert(fid);
    }
    OrderedJson state = OrderedJson::object();
    for (auto it = full.begin(); it != full.end(); ++it) {
        const std::string& k = it.key();
        if (k == "forms" || k == "closeHlc" || k == "closedSpans" || k == "receiptHlc") {
            OrderedJson o = OrderedJson::object();
            for (auto f = it.value().begin(); f != it.value().end(); ++f)
                if (shown.count(f.key())) whisperbox::appendNewKey(o, f.key(), OrderedJson(f.value()));
            state[k] = std::move(o);
        } else if (k == "pending") {
            // the count only: a peer's signed events for invented form ids used to be listed in every
            // snapshot (open-review 2026-11-03, FR-11)
            OrderedJson pn = OrderedJson::object(); pn["count"] = it.value()["count"]; pn["events"] = OrderedJson::array();
            state[k] = std::move(pn);
        } else if (k == "feed") {
            OrderedJson a = OrderedJson::array();
            for (const auto& id : it.value()) if (id.is_string() && shown.count(id.get<std::string>())) a.push_back(id);
            state[k] = std::move(a);
        } else state[k] = it.value();
    }

    // Per-form flags for THIS device (module layer): has the local identity
    // answered / been confirmed / may it answer at all.
    bool seenDirty = false;
    long long newTotal = 0;
    for (auto it = state["forms"].begin(); it != state["forms"].end(); ++it) {
        const std::string fid = it.key();
        auto& f = it.value();
        const bool mine = m_signId.valid && f["creator"].get<std::string>() == m_signId.address;
        const bool coOwner = !mine && isCoOwner(f);
        f["coOwner"] = coOwner;
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
        // Answers go only to a creator a link or QR named: a bare id names nobody, and whoever published
        // under it first got the answers (open-review 2026-10-30, FR-3)
        const bool needsLink = pin.empty() && !mine;
        const bool trusted = !linkMismatch && !needsLink && (!contested || pin == f["creator"].get<std::string>());
        f["needsLink"] = needsLink;
        f["contested"] = contested;
        f["pinnedCreator"] = pin.empty() ? json(nullptr) : json(pin);
        f["linkMismatch"] = linkMismatch;
        f["mine"] = mine;
        f["mySubmitted"] = submitted;
        if (mine || coOwner) {   // "N new" since the creator / co-owner last looked
            long long n = (creatorViewJson.is_object() && creatorViewJson.contains("responses") && creatorViewJson["responses"].contains(fid))
                          ? (long long)creatorViewJson["responses"][fid].size() : 0;
            if (!m_seen.count(fid)) { m_seen[fid] = n; seenDirty = true; }   // first sight: nothing is "new"
            f["newResponses"] = std::max(0LL, n - m_seen[fid]);
            if (!m_hidden.count(fid)) newTotal += std::max(0LL, n - m_seen[fid]);
        }
        if (submitted && f.contains("allowEdits") && f["allowEdits"].is_boolean() && f["allowEdits"].get<bool>() && m_myAnswers.count(fid)) {
            const long long first = m_myAnswers[fid].value("firstSubmittedAt", m_myAnswers[fid].value("submittedAt", 0LL));
            const long long until = first + std::min<long long>(f["editWindowMinutes"].is_number() ? whisperbox::toLL(f["editWindowMinutes"].get<double>()) : 15, 525600) * 60000LL;
            f["editUntil"] = until;
            f["canEdit"] = !confirmed && f["status"].get<std::string>() == "open" && nowMs() < until;
        }
        f["hidden"] = m_hidden.count(fid) > 0;
        f["autoReceipts"] = m_autoReceipts.count(fid) > 0;
        // the content itself (answer draft, my answers, quiz key, my replies) is in formDetail (FR-2)
        f["hasAnswerDraft"] = m_answerDrafts.count(fid) > 0;
        f["hasMyAnswers"] = m_myAnswers.count(fid) > 0;
        if (submitted && m_myConfirmIds.count(fid) && f.contains("replies") && !f["replies"].empty()) {
            const std::vector<std::string> cids = myCidsFor(fid);
            long long n = 0; for (const auto& r : f["replies"]) if (std::find(cids.begin(), cids.end(), r.value("to", "")) != cids.end()) n++;
            f["myReplyCount"] = n;   // the replies themselves: formDetail
        }
        f["myConfirmed"] = confirmed;
        f["allowed"] = allowed;
        // ADR 0022: a several-answer form stays answerable until this person's cap (0 = none)
        const long long perResp = whisperbox::maxPerRespondentOf(f);
        const long long myCount = submitted ? (long long)myCidsFor(fid).size() : 0;
        const bool room = perResp == 1 ? !submitted : (perResp == 0 || myCount < perResp);
        if (perResp != 1) {
            f["myAnswerCount"] = myCount;
            long long rc = 0; for (const auto& c : myCidsFor(fid)) if (containsStr(f["confirmations"], c)) rc++;
            f["myReceipts"] = rc;
        }
        f["canRespond"] = trusted && !mine && room && allowed && f["status"].get<std::string>() == "open"
                          && f["publicKey"].is_string() && !f["publicKey"].get<std::string>().empty();
    }

    OrderedJson snap = OrderedJson::object();
    snap["v"] = 1;
    snap["identity"] = m_signId.valid
        ? json({{"address", m_signId.address}, {"pubHex", m_signId.pubHex}, {"protected", m_protected}}) : nullptr;
    // a passphrase-protected identity not unlocked yet: the view asks for the passphrase (FR-13)
    snap["locked"] = m_locked ? json({{"address", m_lockedAddress}}) : json(nullptr);
    if (seenDirty) saveSeen();
    snap["deviceId"] = m_deviceId;
    snap["newResponses"] = newTotal;   // across my (non-hidden) forms
    snap["storage"] = json({{"dir", m_dataDir}, {"ok", m_storageOk}, {"note", m_storageNote}});
    snap["nodeReady"] = m_nodeReady;
    // The sealed answers are opaque to the view and grew the snapshot with every blob (open-review
    // 2026-11-01, FR-3): the view gets their count; the creator's decrypted ones are in creatorView.
    state["responseCount"] = (long long)m_logResponses;
    snap["state"] = state;
    snap["creatorView"] = creatorViewJson.is_null() ? nullptr : creatorViewJson;
    json watchedArr = json::array(); for (auto& id : m_watched) watchedArr.push_back(id);
    snap["watched"] = watchedArr;
    json pendingArr = json::array();
    for (auto& id : m_watched) if (!m_foldIds.count(id)) pendingArr.push_back(id);
    snap["pendingForms"] = pendingArr;
    json hiddenArr = json::array(); for (auto& id : m_hidden) hiddenArr.push_back(id);
    snap["hidden"] = hiddenArr;
    json draftsArr = json::array(); for (auto& kv : m_drafts) draftsArr.push_back(kv.second);
    snap["drafts"] = draftsArr;
    json subArr = json::array(); for (auto& id : m_mySubmissions) subArr.push_back(id);
    snap["mySubmissions"] = subArr;
    snap["diagnostics"] = json({
        {"transport", m_via == Via::Loam ? "loam_core" : m_via == Via::Direct ? "delivery_module" : "probing"}, {"nodeMode", m_nodeMode},
        {"rxRaw", m_rxRaw}, {"rxSeen", m_rxSeen}, {"rxNew", m_rxNew}, {"rxDup", m_rxDup},
        {"txTotal", m_txTotal}, {"admDropSig", m_admDropSig}, {"admDropType", m_admDropType}, {"admDropShape", m_admDropShape}, {"admDropFuture", m_admDropFuture}, {"rxBad", m_rxBad}, {"loadDropped", m_loadDropped}, {"netTs", m_netTs}, {"serveSkipped", m_serveSkipped},
        {"rbsrRx", m_rbsrRx}, {"legacyReseeds", m_legacyReseeds},
        {"admDropBudget", m_admDropBudget}, {"admDropUnwanted", m_admDropUnwanted}, {"txErr", m_txErr}, {"txDropped", m_txDropped}, {"storeDropTopic", m_storeDropTopic}, {"storeDropCap", m_storeDropCap}, {"admDropFull", m_admDropFull}, {"ctlDropBudget", m_ctlDropBudget}, {"startFailures", m_startFailures}, {"logBytes", (long long)m_logBytes}, {"logResponses", (long long)m_logResponses},
    });
    return snap;
}

void WhisperboxCoreImpl::publishState() {
    m_publishDirty = false;
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
std::map<std::string, const whisperbox::SignId*> WhisperboxCoreImpl::formKeysFor(const OrderedJson& state) {
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
    // forms I co-own: their key arrives sealed to my identity (form.coowner)
    for (const auto& fid : coOwnedForms(state)) {
        const auto& f = state["forms"][fid];
        if (const whisperbox::SignId* k = coOwnerKey(fid, f)) keys[k->pubHex] = k;
    }
    return keys;
}

OrderedJson WhisperboxCoreImpl::decryptView(const OrderedJson& state) {
    // cached with the fold: same log, pins, identity and network times give the same view
    const std::string me = m_signId.valid ? m_signId.address : "";
    if (m_cvValid && m_cvLogGen == m_logGen && m_cvPinsGen == m_pinsGen && m_cvNetGen == m_netGen && m_cvIdent == me) return m_cvCache;
    const auto keys = formKeysFor(state);
    const std::set<std::string> also = coOwnedForms(state);
    std::unordered_map<std::string, const OrderedJson*> formIdx;
    for (auto it = state["forms"].begin(); it != state["forms"].end(); ++it) formIdx[it.key()] = &it.value();
    // keyed by event id (it hashes the sealed bytes): the whole hex blob used to be the key
    auto open = [&](const std::string& id, const std::string& hexBlob) -> json {
        const std::string& key = id.empty() ? hexBlob : id;
        auto c = m_openCache.find(key);
        if (c != m_openCache.end() && (!c->second.dec.is_null() || c->second.nKeys == keys.size())) return c->second.dec;
        json dec;
        const whisperbox::Bytes blob = whisperbox::fromHex(hexBlob);
        for (const auto& kv : keys) {
            whisperbox::Bytes pt;
            try { pt = whisperbox::eciesOpen(kv.second->priv, blob); } catch (...) { continue; }
            try { dec = parseUntrusted(std::string(pt.begin(), pt.end())); } catch (...) { dec = json(); break; }
            const std::string fid = dec.is_object() && dec.contains("formId") && dec["formId"].is_string() ? lc(dec["formId"].get<std::string>()) : "";
            auto fi = formIdx.find(fid);
            if (fid.empty() || fi == formIdx.end() || fi->second->value("publicKey", "") != kv.first) dec = json();
            break;
        }
        // bounded (FR-3): the log holds at most 50,000 answers, so this keeps one entry each
        if (m_openCache.size() >= 60000) m_openCache.clear();
        m_openCache[key] = Opened{dec, keys.size()};
        return dec;
    };
    auto netTime = [this](const std::string& id) -> long long { auto n = m_netTimes.find(id); return n == m_netTimes.end() ? 0 : n->second; };
    auto localTime = [this](const std::string& id) -> long long { auto n = m_firstSeen.find(id); return n == m_firstSeen.end() ? 0 : n->second; };
    // the pool straight from the log: the fold no longer copies it (FR-5)
    std::vector<const json*> pool;
    pool.reserve(m_logResponses);
    for (const auto& e : m_log) if (e.contains("type") && e["type"].is_string() && e["type"].get_ref<const std::string&>() == RESPONSE_SUBMIT) pool.push_back(&e);
    m_cvCache = whisperbox::creatorViewPool<json>(state, pool, me, open, verifyInnerResponse, also, netTime, localTime);
    m_cvValid = true; m_cvLogGen = m_logGen; m_cvPinsGen = m_pinsGen; m_cvNetGen = m_netGen; m_cvIdent = me;
    return m_cvCache;
}

const OrderedJson& WhisperboxCoreImpl::foldedState() {
    const std::string me = m_signId.valid ? m_signId.address : "";
    if (m_foldValid && m_foldLogGen == m_logGen && m_foldPinsGen == m_pinsGen && m_foldIdent == me) return m_foldCache;
    m_foldCache = whisperbox::computeState(m_log, me, nullptr, m_pinned, /*withPool=*/false);
    m_foldIds.clear();
    for (auto it = m_foldCache["forms"].begin(); it != m_foldCache["forms"].end(); ++it) m_foldIds.insert(it.key());
    m_foldValid = true; m_foldLogGen = m_logGen; m_foldPinsGen = m_pinsGen; m_foldIdent = me;
    return m_foldCache;
}

json WhisperboxCoreImpl::quizOf(const OrderedJson& f, const std::map<std::string, const whisperbox::SignId*>& keys) {
    if (!f.contains("quizKey") || !f["quizKey"].is_string()) return json();
    const std::string qk = f["quizKey"].get<std::string>();
    auto c = m_quizCache.find(qk);
    if (c != m_quizCache.end()) return c->second;
    auto k = keys.find(f.value("publicKey", ""));
    if (k == keys.end()) return json();
    json key;
    try { whisperbox::Bytes pt = whisperbox::eciesOpen(k->second->priv, whisperbox::fromHex(qk)); key = parseUntrusted(std::string(pt.begin(), pt.end())); }
    catch (...) { key = json(); }
    if (!key.is_object()) key = json();
    m_quizCache[qk] = key;
    return key;
}
// Module-layer extras per decrypted answer: receipt sent, private replies sent, quiz score.
void WhisperboxCoreImpl::enrichResponses(const OrderedJson& state, const std::string& formId, json& responses,
                                         const std::map<std::string, const whisperbox::SignId*>& keys) {
    if (!state["forms"].contains(formId) || !responses.is_array()) return;
    const auto& f = state["forms"][formId];
    const json quiz = quizOf(f, keys);
    std::map<std::string, int> replies;
    if (f.contains("replies")) for (const auto& r : f["replies"]) replies[r.value("to", "")]++;
    std::unordered_set<std::string> confs;
    for (const auto& c : f["confirmations"]) if (c.is_string()) confs.insert(c.get<std::string>());
    // questions parsed once, and each answer's score kept until the form or the answer changes: every
    // snapshot re-parsed and re-scored every answer (5,000 x 500 questions = 18 s, open-review
    // 2026-11-03, FR-12)
    json questions;
    const std::string formVer = formId + "|" + f["version"].dump() + "|" + f["quizKey"].dump() + "|";
    for (auto& r : responses) {
        if (!r.is_object()) continue;
        const std::string cid = confirmIdOf(r, formId);
        r["confirmed"] = confs.count(cid) > 0;
        r["replies"] = replies.count(cid) ? replies[cid] : 0;
        if (quiz.is_object()) {
            const std::string key = formVer + r.value("respondent", "") + "|" + (r.contains("hlc") ? r["hlc"].dump() : "") + "|" + (r.contains("edits") ? r["edits"].dump() : "");
            auto c = m_scoreCache.find(key);
            if (c == m_scoreCache.end()) {
                if (questions.is_null()) questions = json::parse(f["questions"].dump());
                json sc = whisperbox::scoreAnswers(questions, quiz, r.contains("answers") && r["answers"].is_array() ? r["answers"] : json::array());
                if (m_scoreCache.size() >= 60000) m_scoreCache.clear();
                c = m_scoreCache.emplace(key, sc).first;
            }
            r["score"] = c->second["score"]; r["outOf"] = c->second["outOf"]; r["correct"] = c->second["correct"];
        }
    }
}
// "" = not sent: the reply key came from the respondent and may not be a curve point (WB-8).
std::string WhisperboxCoreImpl::sendReply(const std::string& formId, const std::string& cid, const std::string& replyPub, const json& body) {
    const std::string pt = body.dump();
    std::string sealed;
    try { sealed = whisperbox::toHex(whisperbox::eciesSeal(whisperbox::fromHex(replyPub), whisperbox::Bytes(pt.begin(), pt.end()))); }
    catch (...) { return ""; }
    OrderedJson p = OrderedJson::object();
    p["formId"] = formId; p["author"] = m_signId.address; p["to"] = cid; p["sealed"] = sealed;
    json ev = buildEvent(whisperbox::RESPONSE_REPLY, "reply:" + formId + ":" + cid + ":" + randomHex(6), p, /*sign=*/true);
    if (!adoptChecked(ev)) return "";   // too long, or a receipt id peers refuse (FR-9)
    adoptLocal(ev); broadcastEvent(ev);
    return sealed;
}

// Private reply to one answer (creator / co-owner): only that respondent can read it.
std::string WhisperboxCoreImpl::replyToResponse(std::string formId, std::string confirmationId, std::string message) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(trim(formId)); confirmationId = trim(confirmationId);
    if (trim(message).empty()) { out["ok"] = false; out["error"] = "write a message first"; return out.dump(); }
    OrderedJson state = foldedState();
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (state["forms"][formId]["creator"].get<std::string>() != m_signId.address && !isCoOwner(state["forms"][formId])) { out["ok"] = false; out["error"] = "not the creator or a co-owner"; return out.dump(); }
    OrderedJson cv = decryptView(state);
    std::string replyPub;
    if (cv["responses"].contains(formId))
        for (const auto& r : cv["responses"][formId])
            if (confirmIdOf(json::parse(r.dump()), formId) == confirmationId) { replyPub = r.value("replyPub", ""); break; }
    if (replyPub.empty()) { out["ok"] = false; out["error"] = "that answer can't receive replies (sent by an older WhisperBox)"; return out.dump(); }
    if (sendReply(formId, confirmationId, replyPub, json({{"message", trim(message)}, {"from", m_signId.address}, {"at", nowMs()}})).empty()) {
        out["ok"] = false; out["error"] = "that answer has an invalid reply key, so it can't receive replies"; return out.dump();
    }
    publishState();
    out["ok"] = true;
    return out.dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}

// Quiz: send each answer that hasn't had a reply yet its score (privately).
std::string WhisperboxCoreImpl::sendScores(std::string formId) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(trim(formId));
    OrderedJson state = foldedState();
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (state["forms"][formId]["creator"].get<std::string>() != m_signId.address && !isCoOwner(state["forms"][formId])) { out["ok"] = false; out["error"] = "not the creator or a co-owner"; return out.dump(); }
    const auto keys = formKeysFor(state);
    if (!quizOf(state["forms"][formId], keys).is_object()) { out["ok"] = false; out["error"] = "this form isn't a quiz"; return out.dump(); }
    OrderedJson cv = decryptView(state);
    json rs = cv["responses"].contains(formId) ? json::parse(cv["responses"][formId].dump()) : json::array();
    enrichResponses(state, formId, rs, keys);
    int sent = 0, skipped = 0;
    for (const auto& r : rs) {
        if (r.value("replies", 0) > 0) continue;
        const std::string rp = r.value("replyPub", "");
        if (rp.empty()) { skipped++; continue; }
        if (sendReply(formId, confirmIdOf(r, formId), rp, json({{"kind", "score"}, {"score", r["score"]}, {"outOf", r["outOf"]}, {"correct", r["correct"]},
                                                               {"from", m_signId.address}, {"at", nowMs()}})).empty()) { skipped++; continue; }
        sent++;
    }
    if (sent) publishState();
    out["ok"] = true; out["sent"] = sent; out["skipped"] = skipped;
    return out.dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}

bool WhisperboxCoreImpl::isCoOwner(const OrderedJson& f) const {
    if (!m_signId.valid || !f.contains("coOwners") || !f["coOwners"].is_array()) return false;
    for (const auto& c : f["coOwners"]) if (c.is_object() && c.value("address", "") == m_signId.address) return true;
    return false;
}
std::set<std::string> WhisperboxCoreImpl::coOwnedForms(const OrderedJson& state) {
    std::set<std::string> out;
    if (state.contains("forms")) for (auto it = state["forms"].begin(); it != state["forms"].end(); ++it)
        if (it.value().value("creator", "") != m_signId.address && isCoOwner(it.value())) out.insert(it.key());
    return out;
}
// The form key a creator sealed to me; checked against the form's public key.
const whisperbox::SignId* WhisperboxCoreImpl::coOwnerKey(const std::string& formId, const OrderedJson& f) {
    for (const auto& c : f["coOwners"]) {
        if (!c.is_object() || c.value("address", "") != m_signId.address || !c.contains("sealedKey") || !c["sealedKey"].is_string()) continue;
        const std::string cacheKey = formId + "|" + c["sealedKey"].get<std::string>();
        auto it = m_coKeyCache.find(cacheKey);
        if (it == m_coKeyCache.end()) {
            whisperbox::SignId k;
            try {
                whisperbox::Bytes pt = whisperbox::eciesOpen(m_signId.priv, whisperbox::fromHex(c["sealedKey"].get<std::string>()));
                k = whisperbox::identityFromPriv(whisperbox::fromHex(std::string(pt.begin(), pt.end())));
            } catch (...) {}
            it = m_coKeyCache.emplace(cacheKey, k).first;
        }
        if (it->second.valid && it->second.pubHex == f.value("publicKey", "")) return &it->second;
    }
    return nullptr;
}

// Share a form's key with a co-owner (creator): they can read answers and send receipts.
// coOwnerPubHex = their "co-owner code" (33-byte compressed public key). Can't be revoked.
std::string WhisperboxCoreImpl::addCoOwner(std::string formId, std::string coOwnerPubHex) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(trim(formId)); coOwnerPubHex = lc(trim(coOwnerPubHex));
    if (!isHex(coOwnerPubHex, 66) || !whisperbox::validPubPoint(whisperbox::fromHex(coOwnerPubHex))) { out["ok"] = false; out["error"] = "that isn't a co-owner code (66 hex characters)"; return out.dump(); }
    OrderedJson state = foldedState();
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    const auto& f = state["forms"][formId];
    if (f["creator"].get<std::string>() != m_signId.address) { out["ok"] = false; out["error"] = "not the creator"; return out.dump(); }
    // A legacy form's key IS the identity key: sealing it to a co-owner gave them the creator's
    // identity, to sign as the creator and derive every other form key (open-review 2026-11-01, FR-1).
    // Only a derived per-form key is ever shared.
    if (f.value("publicKey", "") == m_signId.pubHex) { out["ok"] = false; out["error"] = "this form was made before per-form keys: its key is your identity key, so it can't be shared with a co-owner - duplicate it as a new form and add co-owners there"; return out.dump(); }
    whisperbox::SignId fk = whisperbox::deriveFormKey(m_signId, formId);
    if (!fk.valid || fk.pubHex != f.value("publicKey", "")) { out["ok"] = false; out["error"] = "this form's key isn't on this device (Keycard form?) - add co-owners from the phone"; return out.dump(); }
    whisperbox::Bytes pub = whisperbox::fromHex(coOwnerPubHex);
    whisperbox::Bytes h = whisperbox::sha256(pub);
    const std::string ownerAddr = "0x" + whisperbox::toHex(h.data(), 32).substr(24, 40);
    if (ownerAddr == m_signId.address) { out["ok"] = false; out["error"] = "that's your own code"; return out.dump(); }
    const std::string privHex = whisperbox::toHex(fk.priv);
    std::string sealed;
    try { sealed = whisperbox::toHex(whisperbox::eciesSeal(pub, whisperbox::Bytes(privHex.begin(), privHex.end()))); }
    catch (...) { out["ok"] = false; out["error"] = "that co-owner code isn't a valid key"; return out.dump(); }
    OrderedJson p = OrderedJson::object();
    p["formId"] = formId; p["author"] = m_signId.address; p["owner"] = ownerAddr; p["sealedKey"] = sealed;
    json e = buildEvent(whisperbox::FORM_COOWNER, "coowner:" + formId + ":" + ownerAddr, p, /*sign=*/true);
    adoptLocal(e); broadcastEvent(e); publishState();
    out["ok"] = true; out["formId"] = formId; out["owner"] = ownerAddr;
    return out.dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}

// ── create / edit ───────────────────────────────────────────────────────────────
// The definition fields a creator sets on publish and may change with form.update
// (the fold normalizes them the same way: whisperbox_engine.hpp applyEditableFields).
static OrderedJson editableFromDef(const json& def, const std::string& sealPub = "") {
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
    if (def.value("anonymous", false) == true) p["anonymous"] = true;
    // quiz: the answer key travels sealed to the form key (only creator + co-owners read it)
    if (!sealPub.empty() && def.contains("quiz") && def["quiz"].is_object() && !def["quiz"].empty()) {
        const std::string k = def["quiz"].dump();
        p["quizKey"] = whisperbox::toHex(whisperbox::eciesSeal(whisperbox::fromHex(sealPub), whisperbox::Bytes(k.begin(), k.end())));
    }
    if (def.value("allowEdits", false) == true) {
        p["allowEdits"] = true;
        p["editWindowMinutes"] = def.contains("editWindowMinutes") && def["editWindowMinutes"].is_number_integer() && def["editWindowMinutes"].get<long long>() > 0 ? def["editWindowMinutes"] : json(15);
    }
    // answers per respondent (ADR 0022): omitted at the default 1; 0 = unlimited
    if (whisperbox::maxPerRespondentOf(def) != 1) p["maxPerRespondent"] = whisperbox::maxPerRespondentOf(def);
    return p;
}
// Combinations the protocol doesn't define: writers refuse them (same as the JS client).
static std::string defConflict(const json& def) {
    if (def.value("anonymous", false) == true && def.contains("whitelist") && def["whitelist"].is_object() && def["whitelist"].value("type", "none") != "none")
        return "an anonymous form can't be members-only (that needs real addresses)";
    if (def.value("allowEdits", false) == true && whisperbox::maxPerRespondentOf(def) != 1)
        return "a form that takes several answers per person can't also allow edits (each answer is final)";
    return "";
}

// Edit a published form (creator). The full new definition replaces the old one on every
// device (latest update wins); id / creator / key / creation time never change. Keep the
// ids of existing questions - answers are stored by question id.
std::string WhisperboxCoreImpl::updateForm(std::string formId, std::string defJson) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(trim(formId));
    json def;
    try { def = parseUntrusted(trim(defJson), kMaxLocalJson); } catch (...) { out["ok"] = false; out["error"] = "bad defJson"; return out.dump(); }
    if (!def.is_object()) { out["ok"] = false; out["error"] = "def must be an object"; return out.dump(); }
    if (def.contains("questions") && !def["questions"].is_array()) { out["ok"] = false; out["error"] = "questions must be an array"; return out.dump(); }
    { const std::string c = defConflict(def); if (!c.empty()) { out["ok"] = false; out["error"] = c; return out.dump(); } }
    OrderedJson state = foldedState();
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (state["forms"][formId]["creator"].get<std::string>() != m_signId.address) { out["ok"] = false; out["error"] = "not the creator"; return out.dump(); }
    OrderedJson p = OrderedJson::object();
    p["formId"] = formId; p["author"] = m_signId.address; p["form"] = editableFromDef(def, state["forms"][formId].value("publicKey", ""));
    json e = buildEvent(whisperbox::FORM_UPDATE, whisperbox::formUpdateId(formId, randomHex(6)), p, /*sign=*/true);
    // the same shape check peers apply, or they'd drop it and our state would differ from theirs (FR-5)
    if (!whisperbox::wellFormedEvent(e)) { out["ok"] = false; out["error"] = "the form is too large or has a field peers would refuse"; return out.dump(); }
    if (e.dump().size() > whisperbox::kMaxWireEventBytes) { out["ok"] = false; out["error"] = "the form is too large to send (about 78 KB at most) - shorten its texts"; return out.dump(); }   // W2-1
    adoptLocal(e); broadcastEvent(e); publishState();
    out["ok"] = true; out["formId"] = formId;
    return out.dump();
} catch (const std::exception& ex) {
    // A local caller's malformed JSON (a mistyped field) must come back as an error, never throw out
    // of the module (open-review FR-8).
    return json({{"ok", false}, {"error", std::string("bad request: ") + ex.what()}}).dump();
}

// ── create ───────────────────────────────────────────────────────────────────────
std::string WhisperboxCoreImpl::createForm(std::string defJson) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    json def;
    try { def = parseUntrusted(trim(defJson), kMaxLocalJson); } catch (...) { out["ok"] = false; out["error"] = "bad defJson"; return out.dump(); }
    if (!def.is_object()) { out["ok"] = false; out["error"] = "def must be an object"; return out.dump(); }
    { const std::string c = defConflict(def); if (!c.empty()) { out["ok"] = false; out["error"] = c; return out.dump(); } }
    std::string formId = lc(def.value("id", ""));
    if (formId.empty()) formId = "form-" + randomHex(4);
    // the id must fit the share link: "x&y" was published, but its link opened form "x" (FR-11)
    if (!plausibleFormId(formId)) { out["ok"] = false; out["error"] = "a form id is 1-128 of a-z, 0-9, '.', '_', ':' and '-', starting with a letter or digit"; return out.dump(); }
    if (def.contains("questions") && !def["questions"].is_array()) { out["ok"] = false; out["error"] = "questions must be an array"; return out.dump(); }

    OrderedJson p = OrderedJson::object();
    p["id"] = formId;
    p["creator"] = m_signId.address;
    // Sealing key = this form's OWN key, derived from the identity (whisperbox_identity.hpp).
    p["publicKey"] = whisperbox::deriveFormKey(m_signId, formId).pubHex;
    p["createdAt"] = nowMs();
    OrderedJson ed = editableFromDef(def, p["publicKey"].get<std::string>());
    for (auto it = ed.begin(); it != ed.end(); ++it) p[it.key()] = it.value();

    json e = buildEvent(FORM_PUBLISH, whisperbox::formPublishId(formId), p, /*sign=*/true);
    if (!whisperbox::wellFormedEvent(e)) { out["ok"] = false; out["error"] = "the form is too large or has a field peers would refuse"; return out.dump(); }   // FR-5
    if (e.dump().size() > whisperbox::kMaxWireEventBytes) { out["ok"] = false; out["error"] = "the form is too large to send (about 78 KB at most) - shorten its texts"; return out.dump(); }   // W2-1
    adoptLocal(e);
    broadcastEvent(e);
    publishState();
    out["ok"] = true; out["formId"] = formId; out["event"] = e;
    return out.dump();
} catch (const std::exception& ex) {
    // A local caller's malformed JSON (a mistyped field) must come back as an error, never throw out
    // of the module (open-review FR-8).
    return json({{"ok", false}, {"error", std::string("bad request: ") + ex.what()}}).dump();
}

std::string WhisperboxCoreImpl::closeForm(std::string formId) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(formId);
    OrderedJson state = foldedState();
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
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}

std::string WhisperboxCoreImpl::confirmResponse(std::string formId, std::string respondentAddr) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(formId);
    respondentAddr = lc(respondentAddr);
    OrderedJson state = foldedState();
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (state["forms"][formId]["creator"].get<std::string>() != m_signId.address && !isCoOwner(state["forms"][formId])) { out["ok"] = false; out["error"] = "not the creator or a co-owner"; return out.dump(); }

    // The receipt id is the one the respondent SEALED inside its response (random,
    // unlinkable); legacy responses fall back to the old (form, respondent) hash.
    // Same id every time -> re-confirmation is idempotent under union-by-id.
    OrderedJson cv = decryptView(state);
    // Only a verified answer: an unsigned one can claim anyone's address, and confirming it used to give
    // the receipt to the forger's id instead of the real respondent's (open-review 2026-11-01, FR-8).
    std::string confirmationId;
    bool unverifiedOnly = false;
    if (cv["responses"].contains(formId))
        for (const auto& r : cv["responses"][formId]) {
            if (!(r.contains("respondent") && r["respondent"].is_string() && lc(r["respondent"].get<std::string>()) == respondentAddr)) continue;
            if (r.contains("verified") && r["verified"].is_boolean() && !r["verified"].get<bool>()) { unverifiedOnly = true; continue; }
            confirmationId = confirmIdOf(json::parse(r.dump()), formId); break;
        }
    if (confirmationId.empty() && unverifiedOnly) { out["ok"] = false; out["error"] = "that answer isn't signed by the address it names, so it can't get a receipt"; return out.dump(); }
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
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}

// Every receipt id this device answered a form with: the latest, then earlier ones (ADR 0022).
std::vector<std::string> WhisperboxCoreImpl::myCidsFor(const std::string& fid) {
    std::vector<std::string> out;
    if (m_myConfirmIds.count(fid) && !m_myConfirmIds[fid].empty()) out.push_back(m_myConfirmIds[fid]);
    auto it = m_myAnswers.find(fid);
    if (it != m_myAnswers.end() && it->second.contains("earlier") && it->second["earlier"].is_array())
        for (const auto& e : it->second["earlier"])
            if (e.is_object() && e.contains("confirmationId") && e["confirmationId"].is_string() && !e["confirmationId"].get<std::string>().empty())
                out.push_back(e["confirmationId"].get<std::string>());
    return out;
}

// Receipt for ONE answer by its receipt id: several-answer forms have one per answer (ADR 0022).
std::string WhisperboxCoreImpl::confirmAnswer(std::string formId, std::string confirmationId) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(formId);
    OrderedJson state = foldedState();
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (state["forms"][formId]["creator"].get<std::string>() != m_signId.address && !isCoOwner(state["forms"][formId])) { out["ok"] = false; out["error"] = "not the creator or a co-owner"; return out.dump(); }
    OrderedJson cv = decryptView(state);
    bool found = false, unverified = false;
    if (cv["responses"].contains(formId))
        for (const auto& r : cv["responses"][formId]) {
            if (confirmIdOf(json::parse(r.dump()), formId) != confirmationId) continue;
            if (r.contains("verified") && r["verified"].is_boolean() && !r["verified"].get<bool>()) { unverified = true; continue; }
            found = true; break;
        }
    if (!found) { out["ok"] = false; out["error"] = unverified ? "that answer isn't signed by the address it names, so it can't get a receipt" : "no decrypted answer with that receipt id"; return out.dump(); }
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
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}

// ── respond ──────────────────────────────────────────────────────────────────────
std::string WhisperboxCoreImpl::submitResponse(std::string formId, std::string answersJson) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(formId);
    json answers;
    try { answers = parseUntrusted(trim(answersJson), kMaxLocalJson); } catch (...) { out["ok"] = false; out["error"] = "bad answersJson"; return out.dump(); }
    if (!answers.is_array()) { out["ok"] = false; out["error"] = "answers must be an array of {questionId,value}"; return out.dump(); }

    OrderedJson state = foldedState();
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
    // ADR 0022: several answers per respondent, each final, up to the form's per-person cap (0 = none)
    const long long perResp = whisperbox::maxPerRespondentOf(f);
    const long long myCount = m_mySubmissions.count(formId)
        ? 1 + (long long)(m_myAnswers.count(formId) && m_myAnswers[formId].contains("earlier") && m_myAnswers[formId]["earlier"].is_array() ? m_myAnswers[formId]["earlier"].size() : 0) : 0;
    if (perResp != 1 && myCount > 0) {
        if (perResp > 0 && myCount >= perResp) { out["ok"] = false; out["error"] = "this form takes at most " + std::to_string(perResp) + " answers from one person"; return out.dump(); }
    } else if (m_mySubmissions.count(formId)) {
        if (!allowEdits) { out["ok"] = false; out["error"] = "you already answered this form"; return out.dump(); }
        firstAt = m_myAnswers.count(formId) ? m_myAnswers[formId].value("firstSubmittedAt", m_myAnswers[formId].value("submittedAt", 0LL)) : 0;
        const long long win = std::min<long long>(f["editWindowMinutes"].is_number() ? whisperbox::toLL(f["editWindowMinutes"].get<double>()) : 15, 525600) * 60000LL;
        const std::string cid0 = m_myConfirmIds.count(formId) ? m_myConfirmIds[formId] : std::string();
        if (!cid0.empty() && containsStr(f["confirmations"], cid0)) { out["ok"] = false; out["error"] = "the creator already sent you a receipt - your answer is final"; return out.dump(); }
        if (firstAt <= 0 || nowMs() - firstAt > win) { out["ok"] = false; out["error"] = "the time to edit your answer is over"; return out.dump(); }
        isEdit = true;
    }
    {
        const std::string creator = f["creator"].get<std::string>();
        const std::string pin = m_pinned.count(formId) ? m_pinned[formId] : std::string();
        const bool contested = f.contains("contested") && f["contested"].is_boolean() && f["contested"].get<bool>();
        if (pin.empty()) { out["ok"] = false; out["error"] = "open this form from its creator's link or QR code to answer: a bare form id doesn't say who made it, so anyone could publish a form under it"; return out.dump(); }
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
    // anonymous form: answer as the per-form identity (no link to my address / other forms)
    const bool anonymous = f.contains("anonymous") && f["anonymous"].is_boolean() && f["anonymous"].get<bool>();
    const whisperbox::SignId me = anonymous ? whisperbox::deriveAnonIdentity(m_signId, formId) : m_signId;
    resp["respondent"] = me.address;
    resp["submittedAt"] = submittedAt;
    resp["answers"] = answers;
    // Random receipt id, sealed: the creator echoes it publicly on confirm; only
    // this device (which keeps it) can tell the receipt is its own.
    // an edit keeps the original receipt id (a receipt locks "this person's answer")
    const std::string confirmationId = isEdit && m_myConfirmIds.count(formId) ? m_myConfirmIds[formId] : randomHex(8);
    resp["confirmationId"] = confirmationId;
    // one-off key for private replies / quiz scores to this answer (re-derivable, unlinkable)
    resp["replyPub"] = whisperbox::deriveReplyKey(m_signId, formId, confirmationId).pubHex;
    {   // Every answer is signed by the respondent it names (ADR 0019): nobody can answer in
        // someone else's name or replace their answer. Inside the sealed payload: the wire names nobody.
        OrderedJson m = OrderedJson::object();
        m["formId"] = formId;
        m["respondent"] = me.address;
        m["submittedAt"] = submittedAt;
        m["answers"] = answers;
        std::string msg = "whisperbox-inner-v1|" + whisperbox::esJson(m);   // JSON.stringify, as the phones (FR-12)
        whisperbox::Bytes digest = whisperbox::sha256(whisperbox::Bytes(msg.begin(), msg.end()));
        resp["signature"] = whisperbox::toHex(whisperbox::ecdsaSignLowS(me.priv, digest));
        resp["pub"] = me.pubHex;
    }

    std::string creatorPubHex = f["publicKey"].get<std::string>();
    try {
        const std::string ptText = resp.dump();   // ONE dump — two temporaries would mix iterators
        whisperbox::Bytes pt(ptText.begin(), ptText.end());
        whisperbox::Bytes sealed = whisperbox::eciesSeal(whisperbox::fromHex(creatorPubHex), pt);
        std::string sealedHex = whisperbox::toHex(sealed);
        json p = {{"encryptedPayload", sealedHex}};
        json e = buildEvent(RESPONSE_SUBMIT, whisperbox::responseSubmitId(sealedHex), p, /*sign=*/false);
        const std::string eventId = e.value("id", "");
        // A fresh random tag per answer on the wire. It used to be sha256(deviceId|formId), but every
        // signed event carries the device id in clear, so anyone could compute a user's tag for any
        // form and link an anonymous answer to their device (review 2026-10-22, WB-5).
        const std::string tag = "wb-" + randomHex(6);
        e["dev"] = tag; if (e.contains("hlc") && e["hlc"].is_object()) e["hlc"]["dev"] = tag;
        // peers refuse an event over 256 KiB: say so instead of keeping an answer nobody gets (FR-10)
        if (!adoptChecked(e)) { out["ok"] = false; out["error"] = "these answers are too long to send - shorten the longest ones"; return out.dump(); }
        adoptLocal(e);
        publishState();
        const std::string prevCid = m_myConfirmIds.count(formId) ? m_myConfirmIds[formId] : std::string();
        m_mySubmissions.insert(formId);   // local, private: "I already answered this"
        m_myConfirmIds[formId] = confirmationId;
        saveMySubmissions();
        // eventId + confirmationId: the answer is sent again until its receipt (ADR 0024)
        json entry = json({{"answers", answers}, {"submittedAt", submittedAt}, {"firstSubmittedAt", isEdit ? firstAt : submittedAt},
                           {"eventId", eventId}, {"confirmationId", confirmationId}, {"sent", false}, {"retries", 0}});
        if (perResp != 1 && myCount > 0 && m_myAnswers.count(formId)) {   // keep the answers sent before, newest last
            const json& prevA = m_myAnswers[formId];
            json earlier = prevA.contains("earlier") && prevA["earlier"].is_array() ? prevA["earlier"] : json::array();
            json prevEntry = json({{"answers", prevA.value("answers", json::array())}, {"submittedAt", prevA.value("submittedAt", 0LL)},
                                    {"confirmationId", prevCid.empty() ? json(nullptr) : json(prevCid)}});
            for (const char* k : {"eventId", "sent", "retries"}) if (prevA.contains(k)) prevEntry[k] = prevA[k];
            earlier.push_back(prevEntry);
            entry["earlier"] = earlier;
        }
        if (isEdit && m_myAnswers.count(formId)) {   // an edit replaces the answer: stop retrying the old one
            entry["retries"] = 0;
        }
        m_myAnswers[formId] = entry;
        if (m_nodeReady) {
            sendEvents(formId, json::array({e}), 1, "ans:" + eventId);
            m_myAnswers[formId]["sent"] = true;
        }
        saveMyAnswers();
        if (m_answerDrafts.erase(formId)) saveDrafts();
        out["ok"] = true; out["eventId"] = e["id"].get<std::string>();
    } catch (const std::exception& ex) {
        fprintf(stderr, "WHISPERBOX submit EXCEPTION (%s): %s\n", typeid(ex).name(), ex.what());
        out["ok"] = false; out["error"] = std::string("seal failed: ") + ex.what();
    }
    return out.dump();
} catch (const std::exception& ex) {
    // A local caller's malformed JSON (a mistyped field) must come back as an error, never throw out
    // of the module (open-review FR-8).
    return json({{"ok", false}, {"error", std::string("bad request: ") + ex.what()}}).dump();
}

std::string WhisperboxCoreImpl::getDecryptedResponses(std::string formId) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(formId);
    OrderedJson state = foldedState();
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (state["forms"][formId]["creator"].get<std::string>() != m_signId.address && !isCoOwner(state["forms"][formId])) { out["ok"] = false; out["error"] = "not the creator or a co-owner"; return out.dump(); }

    OrderedJson view = decryptView(state);
    json rs = view["responses"].contains(formId) ? json::parse(view["responses"][formId].dump()) : json::array();
    enrichResponses(state, formId, rs, formKeysFor(state));
    out["ok"] = true;
    out["responses"] = rs;
    return out.dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}

// The private parts of one form, for the view showing it: the answers (creator / co-owner, with
// receipts, replies and scores), my own answers, my replies, the quiz key, my answer draft. They used
// to be in every snapshot and every stateChanged event (open-review 2026-11-03, FR-2).
std::string WhisperboxCoreImpl::formDetail(std::string formId) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    const std::string fid = lc(formId);
    const OrderedJson& state = foldedState();
    if (!m_foldIds.count(fid)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    const auto& f = state["forms"][fid];
    const bool mine = f["creator"].get<std::string>() == m_signId.address, coOwner = !mine && isCoOwner(f);
    out["ok"] = true; out["formId"] = fid; out["mine"] = mine; out["coOwner"] = coOwner;
    const auto keys = formKeysFor(state);
    if (mine || coOwner) {
        OrderedJson view = decryptView(state);
        json rs = view["responses"].contains(fid) ? json::parse(view["responses"][fid].dump()) : json::array();
        enrichResponses(state, fid, rs, keys);
        out["responses"] = rs;
        json q = quizOf(f, keys);
        if (q.is_object()) out["quiz"] = q;
    }
    if (m_answerDrafts.count(fid)) out["answerDraft"] = m_answerDrafts[fid];
    if (m_myAnswers.count(fid)) out["myAnswers"] = m_myAnswers[fid];
    if (m_mySubmissions.count(fid) && m_myConfirmIds.count(fid) && f.contains("replies") && !f["replies"].empty()) {
        // private replies / scores addressed to my answers (several on ADR 0022 forms: tagged with `to`)
        const std::vector<std::string> cids = myCidsFor(fid);
        json mine2 = json::array();
        std::map<std::string, whisperbox::SignId> rks;
        for (const auto& r : f["replies"]) {
            const std::string to = r.value("to", "");
            if (std::find(cids.begin(), cids.end(), to) == cids.end()) continue;
            const std::string cid = to;
            const std::string sealed = r.value("sealed", "");
            auto c = m_replyCache.find(sealed);
            if (c == m_replyCache.end()) {
                auto& rk = rks[cid];
                if (!rk.valid) rk = whisperbox::deriveReplyKey(m_signId, fid, cid);
                json body;
                try { whisperbox::Bytes pt = whisperbox::eciesOpen(rk.priv, whisperbox::fromHex(sealed)); body = parseUntrusted(std::string(pt.begin(), pt.end())); } catch (...) { body = json(); }
                c = m_replyCache.emplace(sealed, body.is_object() ? body : json()).first;
            }
            if (c->second.is_object()) { json b = c->second; if (cids.size() > 1) b["to"] = to; mine2.push_back(b); }
        }
        if (!mine2.empty()) out["myReplies"] = mine2;
    }
    return out.dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}

// ── manage ───────────────────────────────────────────────────────────────────────
// A form id as links carry it (review 2026-10-22: anything used to be accepted and watched forever).
static bool plausibleFormId(const std::string& id) {
    static const std::regex re("^[a-z0-9][a-z0-9._:-]{0,127}$");
    return std::regex_match(id, re);
}
static bool plausibleAddress(const std::string& a) {
    static const std::regex re("^0x[0-9a-f]{40}$");
    return std::regex_match(a, re);
}
std::string WhisperboxCoreImpl::joinForm(std::string formId) try {
    // a share link, not a bare id: importForm parses it and pins the creator it names
    if (trim(formId).rfind("whisperbox://", 0) == 0) return importForm(formId);
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    formId = lc(trim(formId));
    if (!plausibleFormId(formId)) return json({{"ok", false}, {"error", "that isn't a WhisperBox form id or link"}}).dump();
    if (!m_watched.count(formId) && m_watched.size() >= kMaxWatched) return json({{"ok", false}, {"error", "too many opened forms - remove some"}}).dump();   // FR-14
    m_watched.insert(formId);
    saveWatched();
    if (m_nodeReady) { syncTopics(); storePull(formTopic(formId)); }   // wire v2: its bucket, from Store
    publishState();
    json out = {{"ok", true}, {"formId", formId}};
    return out.dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}

std::string WhisperboxCoreImpl::deleteLocalForm(std::string formId) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    formId = lc(formId);
    // off this device: the link it was opened from (pin), and hidden. My own answers and receipt ids
    // stay: any module can call this, and they used to go with it (FR-7)
    m_watched.erase(formId);
    saveWatched();
    if (m_hidden.erase(formId)) saveHidden();
    if (m_pinned.erase(formId)) savePins();   // a new link may pin another creator (FR-5)
    pruneUnwanted();   // its events go too, unless I created, co-own or answered it (audit W2-9)
    dropUnusedBuckets();
    publishState();
    json out = {{"ok", true}, {"formId", formId}};
    return out.dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}

// Hide a form from my lists (any form: mine, answered, opened). Local only - the form
// stays in the shared log, my keys and answers stay, and unhideForm brings it back.
std::string WhisperboxCoreImpl::hideForm(std::string formId) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    formId = lc(trim(formId));
    if (formId.empty()) return json({{"ok", false}, {"error", "formId required"}}).dump();
    if (!m_hidden.count(formId) && m_hidden.size() >= kMaxHidden) return json({{"ok", false}, {"error", "too many hidden forms"}}).dump();   // FR-14
    m_hidden.insert(formId);
    saveHidden();
    publishState();
    return json({{"ok", true}, {"formId", formId}}).dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}
// Re-open a closed form (creator). Answers sealed while it was closed stay dropped.
std::string WhisperboxCoreImpl::reopenForm(std::string formId) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(trim(formId));
    OrderedJson state = foldedState();
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    const auto& f = state["forms"][formId];
    if (f["creator"].get<std::string>() != m_signId.address) { out["ok"] = false; out["error"] = "not the creator"; return out.dump(); }
    if (f["status"].get<std::string>() == "open") { out["ok"] = false; out["error"] = "form is already open"; return out.dump(); }
    if (f.contains("expiresAt") && f["expiresAt"].is_number() && nowMs() > f["expiresAt"].get<long long>()) { out["ok"] = false; out["error"] = "its end date has passed - duplicate it as a new form"; return out.dump(); }
    if (f.contains("maxResponses") && f["maxResponses"].is_number()) {
        OrderedJson cv = decryptView(state);
        long long counted = 0;   // verified answers only, as the cap itself
        if (cv["responses"].contains(formId))
            for (const auto& r : cv["responses"][formId]) if (!(r.contains("verified") && r["verified"].is_boolean() && !r["verified"].get<bool>())) counted++;
        if (counted >= f["maxResponses"].get<long long>()) {
            out["ok"] = false; out["error"] = "it reached its answer limit - duplicate it as a new form"; return out.dump(); }
    }
    OrderedJson p = OrderedJson::object();
    p["formId"] = formId; p["author"] = m_signId.address;
    json e = buildEvent(whisperbox::FORM_REOPEN, whisperbox::formReopenId(formId, randomHex(6)), p, /*sign=*/true);
    adoptLocal(e); broadcastEvent(e); publishState();
    out["ok"] = true; out["formId"] = formId;
    return out.dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}

// Receipts for every decrypted, not-yet-confirmed response of a form, as few events as
// possible (100 receipt ids per event keeps each well inside one message).
std::string WhisperboxCoreImpl::confirmAll(std::string formId) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(trim(formId));
    OrderedJson state = foldedState();
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (state["forms"][formId]["creator"].get<std::string>() != m_signId.address && !isCoOwner(state["forms"][formId])) { out["ok"] = false; out["error"] = "not the creator or a co-owner"; return out.dump(); }
    OrderedJson cv = decryptView(state);
    const json confs = json::parse(state["forms"][formId]["confirmations"].dump());
    std::vector<std::string> todo;
    if (cv["responses"].contains(formId))
        for (const auto& r : cv["responses"][formId]) {
            // an unverified answer proves nothing: no receipt for it unless the creator sends one by hand
            if (r.contains("verified") && r["verified"].is_boolean() && !r["verified"].get<bool>()) continue;
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
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}

std::string WhisperboxCoreImpl::setAutoReceipts(std::string formId, std::string on) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    formId = lc(trim(formId));
    const bool enable = trim(on) == "1" || trim(on) == "true";
    if (enable) {   // only on a form I make or co-own (FR-7)
        const OrderedJson& st = foldedState();
        if (!m_foldIds.count(formId)) return json({{"ok", false}, {"error", "unknown form"}}).dump();
        const auto& f = st["forms"][formId];
        if (!m_signId.valid || (f["creator"].get<std::string>() != m_signId.address && !isCoOwner(f))) return json({{"ok", false}, {"error", "not the creator or a co-owner"}}).dump();
    }
    if (enable) m_autoReceipts.insert(formId); else m_autoReceipts.erase(formId);
    saveDrafts();
    publishState();
    if (enable) confirmAll(formId);   // catch up on what's already in
    return json({{"ok", true}, {"formId", formId}, {"autoReceipts", enable}}).dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}

// Form drafts: {id?, def, publishAt?(ms|null)}. Saved locally only; publishDraft (or the
// scheduler, once publishAt has passed and the node is up) turns one into a real form.
std::string WhisperboxCoreImpl::saveDraft(std::string draftJson) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json d;
    try { d = parseUntrusted(trim(draftJson), kMaxLocalJson); } catch (...) { return json({{"ok", false}, {"error", "bad draftJson"}}).dump(); }
    if (!d.is_object() || !d.contains("def") || !d["def"].is_object()) return json({{"ok", false}, {"error", "draft needs a def object"}}).dump();
    std::string id = d.value("id", "");
    if (id.empty()) id = "draft-" + randomHex(4);
    if (!m_drafts.count(id) && m_drafts.size() >= kMaxDrafts) return json({{"ok", false}, {"error", "too many drafts - publish or delete some"}}).dump();   // FR-14
    json rec = {{"id", id}, {"def", d["def"]}, {"updatedAt", nowMs()},
                {"publishAt", d.contains("publishAt") && d["publishAt"].is_number() ? d["publishAt"] : json(nullptr)}};
    json before = m_drafts.count(id) ? m_drafts[id] : json();
    m_drafts[id] = rec;
    if (draftsBytes() > kMaxDraftsBytes) {   // FR-14
        if (before.is_null()) m_drafts.erase(id); else m_drafts[id] = before;
        return json({{"ok", false}, {"error", "drafts are too large - publish or delete some"}}).dump();
    }
    saveDrafts();
    publishState();
    return json({{"ok", true}, {"draftId", id}}).dump();
} catch (const std::exception& ex) {
    // A local caller's malformed JSON (a mistyped field) must come back as an error, never throw out
    // of the module (open-review FR-8).
    return json({{"ok", false}, {"error", std::string("bad request: ") + ex.what()}}).dump();
}
std::string WhisperboxCoreImpl::deleteDraft(std::string draftId) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    // kept in the drafts' trash (the last 20) instead of gone: any module can call this (FR-7)
    auto it = m_drafts.find(trim(draftId));
    if (it == m_drafts.end()) return json({{"ok", false}, {"error", "no such draft"}}).dump();
    m_draftTrash.push_back(it->second);
    while (m_draftTrash.size() > kMaxDraftTrash) m_draftTrash.erase(m_draftTrash.begin());
    m_drafts.erase(it);
    saveDrafts();
    publishState();
    return json({{"ok", true}}).dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}
std::string WhisperboxCoreImpl::publishDraft(std::string draftId) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    return publishDraftLocked(trim(draftId));
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}
std::string WhisperboxCoreImpl::publishDraftLocked(const std::string& draftId) {
    auto it = m_drafts.find(draftId);
    if (it == m_drafts.end()) return json({{"ok", false}, {"error", "unknown draft"}}).dump();
    json r = json::parse(createForm(it->second["def"].dump()));
    if (r.value("ok", false)) { m_drafts.erase(draftId); saveDrafts(); publishState(); }
    return r.dump();
}
// Half-filled answers for a form, restored when it is opened again. "" / [] clears.
std::string WhisperboxCoreImpl::saveAnswerDraft(std::string formId, std::string answersJson) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    formId = lc(trim(formId));
    json a;
    try { a = trim(answersJson).empty() ? json::array() : parseUntrusted(trim(answersJson), kMaxLocalJson); } catch (...) { return json({{"ok", false}, {"error", "bad answersJson"}}).dump(); }
    if (!a.is_array() || a.empty()) m_answerDrafts.erase(formId);
    else {
        if (!m_answerDrafts.count(formId) && m_answerDrafts.size() >= kMaxAnswerDrafts) return json({{"ok", false}, {"error", "too many unsent answers saved"}}).dump();   // FR-14
        json before = m_answerDrafts.count(formId) ? m_answerDrafts[formId] : json();
        m_answerDrafts[formId] = a;
        if (draftsBytes() > kMaxDraftsBytes) {
            if (before.is_null()) m_answerDrafts.erase(formId); else m_answerDrafts[formId] = before;
            return json({{"ok", false}, {"error", "unsent answers are too large to keep"}}).dump();
        }
    }
    // saved with the next flush, not per keystroke (FR-14); no publishState: called while typing
    m_draftsDirty = true; scheduleFlush();
    return json({{"ok", true}}).dump();
} catch (const std::exception& ex) {
    // A local caller's malformed JSON (a mistyped field) must come back as an error, never throw out
    // of the module (open-review FR-8).
    return json({{"ok", false}, {"error", std::string("bad request: ") + ex.what()}}).dump();
}

// Every 5 s while online: publish due scheduled drafts, close my forms at their cap or end
// date, send receipts for forms with automatic receipts.
void WhisperboxCoreImpl::housekeeping() {
    if (!m_nodeReady || !m_signId.valid) return;
    std::vector<std::string> due;
    for (auto& kv : m_drafts) if (kv.second.contains("publishAt") && kv.second["publishAt"].is_number() && kv.second["publishAt"].get<long long>() <= nowMs()) due.push_back(kv.first);
    for (auto& id : due) { json r = json::parse(publishDraftLocked(id)); fprintf(stderr, "WHISPERBOX scheduled draft %s -> %s\n", id.c_str(), r.dump().c_str()); }

    OrderedJson state = foldedState();
    bool anyMine = false;
    for (auto it = state["forms"].begin(); it != state["forms"].end(); ++it) if (it.value()["creator"].get<std::string>() == m_signId.address || isCoOwner(it.value())) { anyMine = true; break; }
    if (!anyMine) return;
    OrderedJson cv = decryptView(state);
    for (auto it = state["forms"].begin(); it != state["forms"].end(); ++it) {
        const auto& f = it.value();
        if (f["creator"].get<std::string>() != m_signId.address) {
            // co-owned: automatic receipts only (closing stays the creator's)
            const std::string cfid = it.key();
            if (isCoOwner(f) && m_autoReceipts.count(cfid) && cv["responses"].contains(cfid)) {
                const json confs = json::parse(f["confirmations"].dump());
                for (const auto& r : cv["responses"][cfid])
                    if (!(r.contains("verified") && r["verified"].is_boolean() && !r["verified"].get<bool>())
                        && !containsStr(confs, confirmIdOf(json::parse(r.dump()), cfid))) { confirmAll(cfid); break; }
            }
            continue;
        }
        const std::string fid = it.key();
        if (f["status"].get<std::string>() == "open") {
            // the cap counts answers that prove who sent them: a flood of unsigned answers can't close the form
            size_t n = 0;
            if (cv["responses"].contains(fid))
                for (const auto& r : cv["responses"][fid]) if (!(r.contains("verified") && r["verified"].is_boolean() && !r["verified"].get<bool>())) n++;
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

std::string WhisperboxCoreImpl::unhideForm(std::string formId) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    formId = lc(trim(formId));
    m_hidden.erase(formId);
    saveHidden();
    publishState();
    return json({{"ok", true}, {"formId", formId}}).dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}

std::string WhisperboxCoreImpl::importIdentity(std::string privHex) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (m_locked) { out["ok"] = false; out["error"] = "unlock WhisperBox first"; return out.dump(); }
    if (!isHex(trim(privHex), 64)) { out["ok"] = false; out["error"] = "privHex must be 64 hex chars"; return out.dump(); }
    whisperbox::SignId next = whisperbox::identityFromPriv(whisperbox::fromHex(trim(privHex)));
    if (!next.valid) { out["ok"] = false; out["error"] = "invalid scalar (0, >= n, or bad point)"; return out.dump(); }
    // The current key is the only one that opens the answers sealed to this identity: it is kept as
    // identity.json.prev (0600; sealed if a passphrase is set), never just overwritten (open-review
    // 2026-11-03, FR-4).
    {
        std::error_code ec;
        std::filesystem::copy_file(m_dataDir + "/identity.json", m_dataDir + "/identity.json.prev", std::filesystem::copy_options::overwrite_existing, ec);
        std::filesystem::permissions(m_dataDir + "/identity.json.prev", kPrivateFile, std::filesystem::perm_options::replace, ec);
    }
    out["previousAddress"] = m_signId.address;
    m_signId = next;
    // Everything tied to the previous identity goes: its keys and opened answers, its own answers and
    // receipts, its private replies, its "seen" counts. They used to stay, readable under the new one
    // (open-review 2026-11-01, FR-9). The files are copied to *.prev first, in case the import was a mistake.
    for (const char* f : {"my_submissions.json", "my_answers.json", "seen.json", "drafts.json"}) {
        std::error_code ec;
        std::filesystem::copy_file(m_dataDir + "/" + f, m_dataDir + "/" + f + ".prev", std::filesystem::copy_options::overwrite_existing, ec);
    }
    m_formKeyCache.clear(); m_openCache.clear(); m_coKeyCache.clear(); m_quizCache.clear(); m_replyCache.clear();
    m_mySubmissions.clear(); m_myConfirmIds.clear(); m_myAnswers.clear(); m_answerDrafts.clear(); m_autoReceipts.clear(); m_seen.clear();
    saveMySubmissions(); saveMyAnswers(); saveDrafts(); saveSeen();
    saveIdentity();
    publishState();
    out["ok"] = true; out["address"] = m_signId.address;
    return out.dump();
} catch (const std::exception& ex) {
    // A local caller's malformed JSON (a mistyped field) must come back as an error, never throw out
    // of the module (open-review FR-8).
    return json({{"ok", false}, {"error", std::string("bad request: ") + ex.what()}}).dump();
}

// ── passphrase (open-review 2026-11-03, FR-13; whisperbox_vault.hpp) ─────────────────
// Unlock a passphrase-protected identity: until then the core has no identity (no signing, sending
// or decrypting) and my_answers.json / drafts.json stay sealed.
std::string WhisperboxCoreImpl::unlock(std::string passphrase) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    if (!m_locked) return json({{"ok", true}, {"address", m_signId.address}}).dump();
    whisperbox::Bytes key = whisperbox::vault::keyFor(m_lockedIdentity, passphrase);
    whisperbox::Bytes priv;
    try { priv = whisperbox::vault::openIdentity(m_lockedIdentity, key); }
    catch (...) { return json({{"ok", false}, {"error", "wrong passphrase"}}).dump(); }
    whisperbox::SignId id = whisperbox::identityFromPriv(priv);
    if (!id.valid || id.address != m_lockedAddress) return json({{"ok", false}, {"error", "the identity file doesn't match its address"}}).dump();
    m_signId = id;
    m_vaultKey = key; m_vaultSalt = whisperbox::fromHex(m_lockedIdentity["kdf"]["salt"].get<std::string>());
    m_locked = false; m_lockedIdentity = json();
    loadPrivateFiles();
    m_foldValid = false; m_cvValid = false;
    pruneUnwanted();
    setStatus("Starting...");
    publishState();
    return json({{"ok", true}, {"address", m_signId.address}}).dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}
// Set, change or remove the passphrase. currentPassphrase: needed when one is set. newPassphrase: ""
// removes it (back to plaintext files), else at least 8 characters.
std::string WhisperboxCoreImpl::setPassphrase(std::string currentPassphrase, std::string newPassphrase) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    if (m_locked || !m_signId.valid) return json({{"ok", false}, {"error", "unlock WhisperBox first"}}).dump();
    if (m_protected) {
        json o = json::parse(std::ifstream(m_dataDir + "/identity.json"), nullptr, false);
        bool good = false;
        try { good = whisperbox::vault::isSealedIdentity(o) && whisperbox::vault::openIdentity(o, whisperbox::vault::keyFor(o, currentPassphrase)) == m_signId.priv; } catch (...) { good = false; }
        if (!good) return json({{"ok", false}, {"error", "the current passphrase is wrong"}}).dump();
    }
    if (!newPassphrase.empty() && newPassphrase.size() < whisperbox::vault::kMinPassphrase)
        return json({{"ok", false}, {"error", "a passphrase has at least 8 characters"}}).dump();
    // the backups of a previous identity follow: sealed with the new passphrase, or opened when it's removed
    const whisperbox::Bytes oldKey = m_vaultKey;
    if (newPassphrase.empty()) { m_protected = false; m_vaultKey.clear(); m_vaultSalt.clear(); }
    else { m_protected = true; m_vaultSalt = whisperbox::vault::randomBytes(16); m_vaultKey = whisperbox::vault::passKey(newPassphrase, m_vaultSalt); }
    saveIdentity(); saveMyAnswers(); saveDrafts();
    {   // identity.json.prev (an imported-over identity): re-sealed or opened like the current one
        json prev = json::parse(std::ifstream(m_dataDir + "/identity.json.prev"), nullptr, false);
        whisperbox::Bytes ppriv;
        if (whisperbox::vault::isSealedIdentity(prev) && oldKey.size() == 32) { try { ppriv = whisperbox::vault::openIdentity(prev, oldKey); } catch (...) {} }
        else if (prev.is_object() && prev.contains("privHex") && prev["privHex"].is_string()) ppriv = whisperbox::fromHex(prev["privHex"].get<std::string>());
        whisperbox::SignId pid = ppriv.size() == 32 ? whisperbox::identityFromPriv(ppriv) : whisperbox::SignId{};
        if (pid.valid) {
            json o = m_protected ? whisperbox::vault::sealIdentity(pid.priv, pid.address, pid.pubHex, m_vaultKey, m_vaultSalt)
                                 : json({{"privHex", whisperbox::toHex(pid.priv)}, {"pubHex", pid.pubHex}, {"address", pid.address}});
            writeAtomic(m_dataDir + "/identity.json.prev", o.dump());
        }
    }
    publishState();
    return json({{"ok", true}, {"protected", m_protected}}).dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}

std::string WhisperboxCoreImpl::setDeviceId(std::string deviceId) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    deviceId = trim(deviceId);
    if (deviceId.empty()) { json o = {{"ok", false}, {"error", "empty deviceId"}}; return o.dump(); }
    // 1-64 of [A-Za-z0-9_-], what peers accept in a catch-up request (open-review 2026-11-01, FR-11)
    static const std::regex devId("^[A-Za-z0-9_-]{1,64}$");
    if (!std::regex_match(deviceId, devId)) { json o = {{"ok", false}, {"error", "a device id is 1-64 letters, digits, - or _"}}; return o.dump(); }
    m_deviceId = deviceId;
    m_clock = whisperbox::Clock(m_deviceId);   // HLC dev identity changes with the device id
    writeAtomic(m_dataDir + "/device_id.txt", m_deviceId);
    json out = {{"ok", true}, {"deviceId", m_deviceId}};
    return out.dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}

// One form at a glance, for a card in another app (Freequencies' night): title, status and
// counts. Answer counts only for the creator or a co-owner: a sealed answer doesn't say which
// form it's for, so nobody else can count them. Receipts are public (form.confirmations).
std::string WhisperboxCoreImpl::formSummary(std::string formId) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    formId = lc(formId);
    publishState();
    json snap;
    try { snap = json::parse(m_snapshot); } catch (...) { return json({{"ok", false}, {"error", "no state"}}).dump(); }
    // another app's card may name a form this device never opened: the snapshot only carries the
    // forms it shows, the fold has every form on the topic (FR-5/FR-7)
    json f;
    if (snap["state"]["forms"].contains(formId)) f = snap["state"]["forms"][formId];
    else if (m_foldIds.count(formId)) f = json::parse(foldedState()["forms"][formId].dump());
    else return json({{"ok", false}, {"error", "unknown form"}}).dump();
    const bool mine = f.value("mine", false), coOwner = f.value("coOwner", false);
    json out = {{"ok", true}, {"formId", formId}, {"title", f.value("title", "")}, {"status", f.value("status", "open")},
                {"expiresAt", f.contains("expiresAt") ? f["expiresAt"] : json(nullptr)}, {"createdAt", f.value("createdAt", 0LL)},
                {"mine", mine}, {"coOwner", coOwner}, {"canRead", mine || coOwner},
                {"receipts", f.contains("confirmations") && f["confirmations"].is_array() ? (long long)f["confirmations"].size() : 0LL}};
    if (mine || coOwner) {
        json list = json::array();
        if (snap["creatorView"].is_object() && snap["creatorView"]["responses"].contains(formId)) list = snap["creatorView"]["responses"][formId];
        long long last = 0;
        for (const auto& r : list) if (r.contains("submittedAt") && r["submittedAt"].is_number()) last = std::max(last, whisperbox::toLL(r["submittedAt"].get<double>()));
        out["responses"] = (long long)list.size();
        out["newResponses"] = f.value("newResponses", 0LL);
        out["lastResponseAt"] = last ? json(last) : json(nullptr);
    }
    return out.dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}

std::string WhisperboxCoreImpl::shareUri(std::string formId) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    formId = lc(formId);
    OrderedJson state = foldedState();
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (!plausibleFormId(formId)) { out["ok"] = false; out["error"] = "this form's id can't go in a link"; return out.dump(); }   // FR-11
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
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
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

std::string WhisperboxCoreImpl::importForm(std::string defJson) try {
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
            try { def = parseUntrusted(whisperbox::b64decode(query), kMaxLocalJson); }
            catch (...) { out["ok"] = false; out["error"] = "bad URI payload"; return out.dump(); }
        }
    } else {
        try { def = parseUntrusted(input, kMaxLocalJson); }
        catch (...) { out["ok"] = false; out["error"] = "bad defJson"; return out.dump(); }
    }
    if (!def.is_object() || !def.contains("id")) {
        out["ok"] = false; out["error"] = "def must include id (use shareUri output)"; return out.dump();
    }
    // publicKey is optional: short-URI imports get it from the canonical event.
    std::string formId = def["id"].is_string() ? lc(def["id"].get<std::string>()) : "";
    if (formId.empty()) { out["ok"] = false; out["error"] = "missing id"; return out.dump(); }
    if (!plausibleFormId(formId)) { out["ok"] = false; out["error"] = "that link doesn't name a valid form id"; return out.dump(); }
    if (def.contains("creator") && (!def["creator"].is_string() || !plausibleAddress(lc(def["creator"].get<std::string>())))) {
        out["ok"] = false; out["error"] = "that link names a creator that isn't an address"; return out.dump();
    }

    // No local placeholder event: an unsigned form.publish with the canonical id
    // would shadow the creator's signed event forever (union-by-id keeps the first
    // copy). Watch the id and pull; the view shows it as pending until it lands.
    // The first link's creator is pinned; a later link naming a different creator for the same id is
    // refused, not taken: it used to replace the pin and send answers to whoever made the second link
    // (open-review 2026-11-01, FR-5). Removing the form from this device drops the pin.
    std::string by = def.contains("creator") ? lc(def["creator"].get<std::string>()) : std::string();
    auto pinIt = m_pinned.find(formId);
    if (!by.empty() && pinIt != m_pinned.end() && pinIt->second != by) {
        out["ok"] = false;
        out["error"] = "this link names creator " + by + ", but you opened this form from a link by " + pinIt->second + ". Remove the form from this device first if you trust the new link.";
        return out.dump();
    }
    if (!m_watched.count(formId) && m_watched.size() >= kMaxWatched) { out["ok"] = false; out["error"] = "too many opened forms - remove some"; return out.dump(); }   // FR-14
    OrderedJson state = foldedState();
    const bool have = state["forms"].contains(formId);
    // Not here: pull its bucket over the whole window. A bucket we were already in doesn't mean we have
    // it - a form nobody here opened was dropped on arrival (Václav 2026-11-13), so "since the last
    // pull" would miss it.
    if (!have && m_nodeReady) { m_watched.insert(formId); syncTopics(); m_lastPullMs.erase(formTopic(formId)); storePull(formTopic(formId)); }
    m_watched.insert(formId);
    saveWatched();
    // Answers are only ever sealed to a form whose (signed) creator matches the pin.
    if (!by.empty() && pinIt == m_pinned.end()) { m_pinned[formId] = by; savePins(); }
    publishState();
    out["ok"] = true; out["formId"] = formId; out["pending"] = !have;
    return out.dump();
} catch (const std::exception& ex) {
    // A local caller's malformed JSON (a mistyped field) must come back as an error, never throw out
    // of the module (open-review FR-8).
    return json({{"ok", false}, {"error", std::string("bad request: ") + ex.what()}}).dump();
}

// ── form files (ADR 0023) ─────────────────────────────────────────────────────────
// {"whisperbox":"form","v":1,"formId","creator","title","link","events":[form.publish, form.update...]}
// Only the creator's signed events: public anyway, no keys. Another app ships it and hands it to the
// whisperbox.respond intent, so the form needn't be found on the network.
std::string WhisperboxCoreImpl::exportForm(std::string formId) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    formId = lc(trim(formId));
    OrderedJson state = foldedState();
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    const auto& f = state["forms"][formId];
    const std::string creator = f["creator"].get<std::string>();
    json events = json::array();
    for (const auto& e : m_log) {
        const std::string t = e.value("type", "");
        if (t == FORM_PUBLISH && e.value("id", "") == "form:" + formId && e.contains("payload") && lc(e["payload"].value("creator", "")) == creator)
            events.insert(events.begin(), e);
        else if (t == whisperbox::FORM_UPDATE && e.contains("payload") && lc(e["payload"].value("formId", "")) == formId && lc(e["payload"].value("author", "")) == creator)
            events.push_back(e);
    }
    if (events.empty() || events[0].value("type", "") != FORM_PUBLISH) { out["ok"] = false; out["error"] = "this device doesn't hold the form's signed definition yet"; return out.dump(); }
    json file = {{"whisperbox", "form"}, {"v", 1}, {"formId", formId}, {"creator", creator}, {"title", f.value("title", "")},
                 {"link", "whisperbox://form?id=" + formId + "&by=" + creator}, {"events", events}};
    const std::string text = file.dump(2);
    // saved where people look for downloads; the text is returned too (copy / embed)
    std::string dir = realHome().empty() ? m_dataDir : realHome() + "/Downloads";
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    if (ec) dir = m_dataDir;
    const std::string path = dir + "/whisperbox-" + formId + ".json";   // ids start with "form-"
    bool saved = false;
    { std::ofstream o(path, std::ios::trunc); if (o) { o << text; saved = (bool)o; } }
    out["ok"] = true; out["formId"] = formId; out["file"] = text;
    out["path"] = saved ? json(path) : json(nullptr);
    return out.dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("failed: ") + ex.what()}}).dump();
}

std::string WhisperboxCoreImpl::importFormFile(std::string fileJson) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    json file;
    try { file = parseUntrusted(trim(fileJson), kMaxLocalJson); } catch (...) { out["ok"] = false; out["error"] = "that isn't a WhisperBox form file"; return out.dump(); }
    if (!file.is_object() || file.value("whisperbox", "") != "form" || !file.contains("events") || !file["events"].is_array()
        || file["events"].empty() || file["events"].size() > 64) { out["ok"] = false; out["error"] = "that isn't a WhisperBox form file"; return out.dump(); }
    if (!file.contains("v") || !file["v"].is_number_integer() || file["v"].get<long long>() != 1) { out["ok"] = false; out["error"] = "this form file is from a newer WhisperBox - update it"; return out.dump(); }
    // The publish decides the form and its creator; everything else must be that creator's update of it.
    const json& pub = file["events"][0];
    if (!whisperbox::wellFormedEvent(pub) || pub.value("type", "") != FORM_PUBLISH || !whisperbox::verifyEventJson(pub)) { out["ok"] = false; out["error"] = "the form in this file isn't signed by its creator"; return out.dump(); }
    const std::string formId = lc(pub["payload"].value("id", ""));
    const std::string creator = lc(pub["payload"].value("creator", ""));
    if (!plausibleFormId(formId) || !plausibleAddress(creator) || pub.value("id", "") != "form:" + formId) { out["ok"] = false; out["error"] = "the form in this file is malformed"; return out.dump(); }
    for (size_t i = 1; i < file["events"].size(); i++) {
        const json& e = file["events"][i];
        if (!whisperbox::wellFormedEvent(e) || e.value("type", "") != whisperbox::FORM_UPDATE || lc(e["payload"].value("formId", "")) != formId
            || lc(e["payload"].value("author", "")) != creator || !whisperbox::verifyEventJson(e)) { out["ok"] = false; out["error"] = "this file carries something other than its creator's form - refusing it"; return out.dump(); }
    }
    // pin + watch first (refuses a file whose creator differs from a link opened before)
    json r = json::parse(importForm("whisperbox://form?id=" + formId + "&by=" + creator));
    if (!r.value("ok", false)) return r.dump();
    // then every event through the network's admission path (shape, budget, signature, caps)
    for (const auto& e : file["events"]) ingestEnvelopeText(whisperbox::b64encode(json({{"v", 1}, {"type", "EVENT"}, {"event", e}}).dump()), false, 0);
    flushLog();
    OrderedJson state = foldedState();
    const bool have = state["forms"].contains(formId) && state["forms"][formId].value("creator", "") == creator;
    publishState();
    out["ok"] = true; out["formId"] = formId; out["creator"] = creator; out["pending"] = !have;
    return out.dump();
} catch (const std::exception& ex) {
    return json({{"ok", false}, {"error", std::string("bad request: ") + ex.what()}}).dump();
}

std::string WhisperboxCoreImpl::exportCsv(std::string formId) try {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    json out;
    if (!m_signId.valid) { out["ok"] = false; out["error"] = "no identity"; return out.dump(); }
    formId = lc(formId);
    OrderedJson state = foldedState();
    if (!state["forms"].contains(formId)) { out["ok"] = false; out["error"] = "unknown form"; return out.dump(); }
    if (state["forms"][formId]["creator"].get<std::string>() != m_signId.address && !isCoOwner(state["forms"][formId])) { out["ok"] = false; out["error"] = "not the creator or a co-owner"; return out.dump(); }

    OrderedJson view = decryptView(state);

    auto csvCell = [](std::string v) {
        // Answers come from respondents: a cell starting with = + - @ (or tab/CR) is a formula to a
        // spreadsheet (=HYPERLINK(...) leaks other cells). Plain numbers stay numbers.
        static const std::regex number("^[+-]?[0-9]+([.][0-9]+)?$");
        if (!v.empty() && std::string("=+-@\t\r").find(v[0]) != std::string::npos && !std::regex_match(v, number)) v = "'" + v;
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
    const json quiz = quizOf(f, formKeysFor(state));
    // verified: signed by the respondent it names (an unsigned answer can claim anyone's address);
    // timeVerified: its time is the network's, not the sender's clock (open-review FR-5)
    std::vector<std::string> header = {"respondent", "verified", "submittedAt", "timeVerified", "confirmed"};
    if (quiz.is_object()) header.push_back("score");
    std::vector<json> qs;
    auto strOf = [](const json& o, const char* k) -> std::string { return o.is_object() && o.contains(k) && o[k].is_string() ? o[k].get<std::string>() : std::string(); };
    if (f.contains("questions") && f["questions"].is_array())
        for (const auto& q0 : f["questions"]) {
            json q = json::parse(q0.dump());
            if (!q.is_object()) continue;
            std::string t = strOf(q, "text"); header.push_back(t.empty() ? strOf(q, "id") : t); qs.push_back(q);
        }
    auto line = [&](const std::vector<std::string>& cells) {
        std::string l; for (size_t k = 0; k < cells.size(); ++k) { if (k) l += ","; l += csvCell(cells[k]); } return l + "\n";
    };
    std::string csv = line(header);
    if (view["responses"].contains(formId)) {
        for (const auto& ro : view["responses"][formId]) {
            json r = json::parse(ro.dump());
            std::map<std::string, json> byQ;
            if (r.contains("answers") && r["answers"].is_array())
                for (const auto& a : r["answers"]) if (a.is_object() && a.contains("questionId") && a["questionId"].is_string()) byQ[a["questionId"].get<std::string>()] = a.contains("value") ? a["value"] : json();
            auto yesNo = [&r](const char* k) -> std::string { return r.contains(k) && r[k].is_boolean() ? (r[k].get<bool>() ? "yes" : "no") : ""; };
            std::vector<std::string> row = {strOf(r, "respondent"), yesNo("verified"),
                isoUtc(r.contains("submittedAt") && r["submittedAt"].is_number() ? whisperbox::toLL(r["submittedAt"].get<double>()) : 0),
                yesNo("timeVerified"),
                containsStr(confs, confirmIdOf(r, formId)) ? "yes" : "no"};
            if (quiz.is_object()) {
                json sc = whisperbox::scoreAnswers(json::parse(f["questions"].dump()), quiz, r.contains("answers") && r["answers"].is_array() ? r["answers"] : json::array());
                auto n = [](const json& x) { return x.is_number_integer() ? std::to_string(x.get<long long>()) : x.dump(); };
                row.push_back(n(sc["score"]) + "/" + n(sc["outOf"]));
            }
            for (const auto& q : qs) { std::string qid = strOf(q, "id"); row.push_back(byQ.count(qid) ? cellOf(q, byQ[qid]) : ""); }
            csv += line(row);
        }
    }
    out["ok"] = true; out["csv"] = csv;
    return out.dump();
} catch (const std::exception& ex) {
    // form and answer fields come from peers: a mistyped one fails the export, never the module
    // (open-review 2026-11-01, FR-2)
    return json({{"ok", false}, {"error", std::string("export failed: ") + ex.what()}}).dump();
}

std::string WhisperboxCoreImpl::resync() {
    std::lock_guard<std::recursive_mutex> lk(m_mtx);
    if (!m_nodeReady) { json o = {{"ok", false}, {"error", "node not ready"}}; return o.dump(); }
    // wire v2: join our buckets again (the node may have restarted), pull them from Store again, and
    // ASK at once for forms that haven't arrived
    m_joinedTopics.clear();
    syncTopics();
    storePullAll();
    for (const auto& fid : m_watched) m_askSentMs[fid] = 0;
    publishState();
    json out = {{"ok", true}, {"logSize", (int)m_log.size()}};
    return out.dump();
}
