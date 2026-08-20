#pragma once
// WhisperboxCoreImpl - WhisperBox (privacy-first forms) as a Logos CORE module
// (universal authoring). One shared event log over ONE topic
// (/whisperbox/1/all/proto), folded through the std-only engine
// (whisperbox_engine.hpp, byte-parity with the TS reference), responses
// ECIES-sealed to their form's creator (whisperbox_crypto.hpp), synced over
// delivery_module Reliable Channels. Runs standalone under logoscore AND
// behind the `whisperbox` ui_qml view - ONE implementation, no drift.
//
// Privacy ground truth (original whisperbox waku.ts): the ENTIRE response is
// sealed to the creator; the wire event carries only the opaque blob. Form
// events are public (public feed). No results/aggregates ever leave the
// creator's device.
//
// Rules honored (basecamp + multiwriter-sync skills):
//  - public methods return std::string (never int/bool);
//  - read state is a dispatchable snapshot() ACTION plus a stateChanged event;
//  - <=4 args per method; structured payloads pass as ONE JSON string;
//  - NO trailing // comments on a declaration line (the glue drops such methods);
//  - ASCII-only (a non-ASCII char stops the interface generator).
#include <string>
#include <vector>
#include <set>
#include <map>
#include <mutex>
#include "logos_module_context.h"
#include "whisperbox_engine.hpp"
#include "whisperbox_crypto.hpp"
#include "whisperbox_identity.hpp"
#include "whisperbox_wire.hpp"

class QTimer;

class WhisperboxCoreImpl : public LogosModuleContext {
public:
    ~WhisperboxCoreImpl() override;

    // --- read surface (the UI polls snapshot on a Timer) ---
    std::string snapshot();
    std::string status();

    // --- create (any participant may author forms; creator-gated by signature) ---
    std::string createForm(std::string defJson);
    std::string closeForm(std::string formId);
    std::string confirmResponse(std::string formId, std::string respondentAddr);

    // --- respond ---
    std::string submitResponse(std::string formId, std::string answersJson);
    std::string getDecryptedResponses(std::string formId);

    // --- manage ---
    std::string joinForm(std::string formId);
    std::string deleteLocalForm(std::string formId);
    std::string importIdentity(std::string privHex);
    std::string setDeviceId(std::string deviceId);
    std::string shareUri(std::string formId);
    std::string shareQr(std::string formId);
    std::string importForm(std::string defJson);
    std::string exportCsv(std::string formId);
    std::string resync();

protected:
    void onContextReady() override;

logos_events:
    void stateChanged(const std::string& snapshotJson);
    void statusChanged(const std::string& status);

private:
    // --- event lifecycle ---
    whisperbox::json buildEvent(const std::string& type, const std::string& id, const whisperbox::json& payload, bool sign);
    void adoptLocal(whisperbox::json e);
    void broadcastEvent(const whisperbox::json& e);
    bool deliverySend(const std::string& topic, const std::string& b64Text);

    // --- ingest (receive path) ---
    void ingestEnvelopeText(const std::string& text, bool channelPath);
    bool admitEvent(const whisperbox::json& e);

    // --- state / snapshot ---
    void publishState();
    std::string setStatus(std::string s);
    whisperbox::OrderedJson buildSnapshot();

    // --- identity / persistence ---
    void setupDataDir();
    void loadIdentity();
    void saveIdentity();
    void loadLog();
    void saveLog();
    void loadWatched();
    void saveWatched();
    void loadMySubmissions();
    void saveMySubmissions();
    std::string randomHex(int bytes);

    // --- delivery (all calls async / fire-and-forget) ---
    void bootstrapDelivery();
    void joinTransport();
    void seedBroadcast();
    void requestSync();

    // --- state ---
    std::vector<whisperbox::json> m_log;              // merged, HLC-ordered (single shared log)
    whisperbox::Clock m_clock;
    whisperbox::SignId m_signId;          // local identity (persisted)
    std::string m_deviceId = "whisperbox-core";
    std::string m_dataDir;                // ~/.whisperbox-core or $WHISPERBOX_CORE_DATA
    std::set<std::string> m_watched;      // locally joined form ids
    std::string m_snapshot = "{}";
    std::string m_status = "Starting...";
    bool m_nodeReady = false;
    bool m_deliveryStarting = false;
    bool m_subscribed = false;
    int m_sendRepr = 0;

    // diagnostic counters (surfaced in snapshot, per logos-distributed-debugging)
    long m_rxRaw = 0, m_rxSeen = 0, m_rxNew = 0, m_rxDup = 0, m_txTotal = 0;
    long m_admDropSig = 0, m_admDropType = 0;

    int64_t m_lastSyncReserveMs = 0;      // SYNC_REQ-driven re-serve throttle (3s)
    int64_t m_lastSeedMs = 0;             // periodic seed throttle (60s)
    int64_t m_lastSyncReqMs = 0;          // last outgoing SYNC_REQ
    int m_syncReqTries = 0;               // outgoing SYNC_REQ attempts (backoff schedule)
    int64_t m_lastStatMs = 0;             // 30s counter dump throttle

    std::recursive_mutex m_mtx;
    QTimer* m_hubTimer = nullptr;
    std::set<std::string> m_mySubmissions; // NOTE: appended at end of class on purpose — see commit message (host SDK layout mismatch clobbers shifted offsets)
};
