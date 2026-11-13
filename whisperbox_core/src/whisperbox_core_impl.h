#pragma once
#include <memory>
#include <array>
#include <unordered_set>
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
#include <unordered_map>
#include <mutex>
#include <functional>
#include "logos_module_context.h"
#include "whisperbox_engine.hpp"
#include "whisperbox_crypto.hpp"
#include "whisperbox_identity.hpp"
#include "whisperbox_wire.hpp"
#include "whisperbox_rbsr.hpp"
#include "whisperbox_vault.hpp"

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
    // Receipt for one answer by its receipt id (several answers per person, ADR 0022)
    std::string confirmAnswer(std::string formId, std::string confirmationId);

    // --- respond ---
    std::string submitResponse(std::string formId, std::string answersJson);
    std::string getDecryptedResponses(std::string formId);
    // One form's private parts for the view showing it: answers, my answers, my replies, quiz key, answer draft
    std::string formDetail(std::string formId);

    // --- manage ---
    std::string joinForm(std::string formId);
    std::string deleteLocalForm(std::string formId);
    std::string hideForm(std::string formId);
    std::string unhideForm(std::string formId);
    std::string reopenForm(std::string formId);
    std::string confirmAll(std::string formId);
    std::string setAutoReceipts(std::string formId, std::string on);
    std::string saveDraft(std::string draftJson);
    std::string deleteDraft(std::string draftId);
    std::string publishDraft(std::string draftId);
    std::string saveAnswerDraft(std::string formId, std::string answersJson);
    std::string markSeen(std::string formId);
    std::string updateForm(std::string formId, std::string defJson);
    std::string addCoOwner(std::string formId, std::string coOwnerPubHex);
    // Accept a co-owner invitation (a creator shared a form's key with me): from then on the form and
    // its answers are kept, and its bucket is pulled from Store over the whole window. {ok}
    std::string acceptCoOwner(std::string formId);
    // Decline a co-owner invitation, or stop co-owning a form: its events and answers go from this device. {ok}
    std::string leaveCoOwner(std::string formId);
    std::string replyToResponse(std::string formId, std::string confirmationId, std::string message);
    std::string sendScores(std::string formId);
    std::string importIdentity(std::string privHex);
    // Unlock a passphrase-protected identity (until then: no signing, sending or decrypting)
    std::string unlock(std::string passphrase);
    // Set, change or remove the passphrase; newPassphrase "" removes it, else 8+ characters
    std::string setPassphrase(std::string currentPassphrase, std::string newPassphrase);
    std::string setDeviceId(std::string deviceId);
    std::string shareUri(std::string formId);
    std::string formSummary(std::string formId);
    std::string shareQr(std::string formId);
    std::string importForm(std::string defJson);
    std::string exportCsv(std::string formId);
    // A form as a file (ADR 0023): the creator-signed publish + updates, to ship inside another app
    std::string exportForm(std::string formId);
    // Open a form from such a file: every event is checked like one from the network, the creator pinned
    std::string importFormFile(std::string fileJson);
    // The bucket topic a form lives on (wire v2, ADR 0024)
    static std::string wireTopicFor(const std::string& formId);
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
    // netMs: the network (Logos Delivery) timestamp of the frame in ms, 0 = none (ADR 0019)
    void ingestEnvelopeText(const std::string& text, bool channelPath, long long netMs);
    bool noteNetTime(const whisperbox::json& e, long long netMs);
    void saveNetTimes();
    bool admitEvent(const whisperbox::json& e);

    // --- state / snapshot ---
    void publishState();
    std::string setStatus(std::string s);
    whisperbox::OrderedJson buildSnapshot();

    // --- identity / persistence ---
    void setupDataDir();
    std::vector<std::string> myCidsFor(const std::string& fid);
    void loadIdentity();
    void saveIdentity();
    void loadLog();
    void saveLog();
    void loadWatched();
    void saveWatched();
    void loadMySubmissions();
    void saveMySubmissions();
    void loadPins();
    void savePins();
    std::string randomHex(int bytes);

    // --- transport: loam_core (all calls async / fire-and-forget) ---
    void bootstrapDelivery();
    // ADR 0021: loam_core when it is installed (today's path, unchanged), else delivery_module directly
    void probeTransport();
    void bootstrapDirect();
    std::string directNodeMode(std::string* why = nullptr) const;   // Core | Edge for a node we create
    // What this node keeps (Václav, 2026-11-13: never store forms and answers we don't care about).
    // Signed events: only forms I created, co-own, opened, answered or drafted. Answers: only mine,
    // or ones a form key of mine opens. Everything else is dropped on arrival and pruned from the log.
    bool wanted(const whisperbox::json& e);
    bool baseWants(const std::string& fid) const;
    void refreshInterest();
    void pruneUnwanted();
    void dropUnusedBuckets();
    long m_txErr = 0, m_txDropped = 0, m_storeDropTopic = 0, m_storeDropCap = 0;
    // Receipts, minimal (Václav 2026-11-13): sent on their own, coalesced per form while queued, never
    // in the hourly form state; a respondent's retried answer gets its receipt again (audit W2-5)
    void queueReceipt(const std::string& formId, const whisperbox::json& confirmEvent);
    void resendReceiptFor(const std::string& answerId);
    std::map<std::string, std::vector<whisperbox::json>> m_rcptPending;   // formId -> receipts not sent yet
    std::map<std::string, long long> m_rcptResentMs;                     // receipt event id -> last re-send   // stop pulling buckets no form of mine is in (no unsubscribe exists)
    long long m_interestGen = -1;
    std::set<std::string> m_myForms;                                   // created or co-owned (from the fold)
    std::map<std::string, std::string> m_formCreator;                  // formId -> creator (the fold's, else the link's)
    std::map<std::string, std::set<std::string>> m_formCoOwners;       // formId -> co-owner addresses (the fold's)
    std::map<std::string, int> m_publishAlts;                          // formId -> form.publish events held (contested)
    std::map<std::string, std::string> m_keyForm;                      // sealing pub -> formId
    std::map<std::string, long> m_respPerForm;                         // formId -> answers held (audit R2-3)
    std::string m_wantedForm;                                          // the form wanted() found an answer for
    bool m_pruning = false;                                            // pruneUnwanted: no per-form cap on what is already held
    // co-owner invitations (audit R2-1/R2-6): accepted / declined form ids, persisted
    std::set<std::string> m_coAccepted, m_coDeclined;
    void loadCoOwnerPrefs();
    void saveCoOwnerPrefs();
    whisperbox::json coInvites();
    // Store pulls (audit R2-4/R2-5): an event budget per pull, the window it asked for, a second Store's opinion
    bool m_storeIngest = false;
    long m_storeEventsLeft = 0;
    long long m_storeWindowMs = 0;
    std::map<std::string, long long> m_secondWant;                     // bucket -> window start, for the second Store
    bool m_secondPass = false;
    std::set<std::string> m_netLive;                                   // answer ids whose network time came live
    long long m_lastRejoinMs = 0;
    std::map<std::string, const whisperbox::SignId*> m_myKeys;          // sealing pub -> key (formKeysFor)
    long m_admDropUnwanted = 0;
    std::string m_nodeMode, m_nodeModeWhy;                            // what bootstrapDirect chose ("" = not chosen)
    void directTick();
    struct Direct;                      // delivery_module directly (loam/delivery_transport.hpp), in the .cpp
    std::shared_ptr<Direct> m_direct;   // shared_ptr: the generated glue builds this class without seeing Direct
    int64_t m_directFailedAt = 0;
    void onTransportStatus(const std::string& st);
    void onLoop(std::function<void()> fn);   // run on the module's thread
    void joinTransport();
    void seedBroadcast();
    void requestSync();
    void catchupRound();
    void sendControl(const whisperbox::json& msg);
    // ── wire v2 (ADR 0024): per-form bucket topics, Store pull, creator re-publish, RLN budget ──
    std::set<std::string> m_joinedTopics;                    // bucket topics joined on the transport
    struct OutMsg { int prio; long long seq; std::string topic; std::string text; std::string key; int tries = 0; };
    OutMsg m_sending{};                                       // the message deliverySend is sending (its failure callback requeues it)
    // an async send failure: queue it again (audit W2-10)
    void onSendFailed(OutMsg m, const std::string& why);
    std::vector<OutMsg> m_outQ;                              // waits for the RLN budget, by priority
    long long m_outSeq = 0;
    double m_rlnTokens = 0; int64_t m_rlnRefillMs = 0;       // messages per 600 s epoch (default 10)
    std::map<std::string, long long> m_formSentMs;           // formId -> last FORM publish (creator / co-owner)
    std::map<std::string, int> m_formClosedSends;            // a closed form is published 3 times, then left
    std::map<std::string, long long> m_askSentMs;            // formId -> last ASK (respondent)
    std::map<std::string, int> m_askCount;
    std::map<std::string, long long> m_askAnsweredMs;    // formId -> last time we answered an ASK (creator side)
    std::map<std::string, long long> m_lastPullMs;           // bucket topic -> Store pulled up to (persisted)
    long long m_lastPullRoundMs = 0;
    std::set<std::string> m_pullWant;                        // buckets waiting for a Store pull
    bool m_pullBusy = false; long long m_pullRetryAt = 0, m_pullStartedMs = 0; int m_pullFailures = 0;
    std::vector<std::string> m_storePeers;                   // multiaddrs; from StoreNodes, else the preset fleet
    size_t m_storePeerIx = 0;
    bool m_storePeersAsked = false;
    std::set<std::string> relevantForms();
    void syncTopics();
    void enqueueSend(int prio, const std::string& topic, const whisperbox::json& env, const std::string& key);
    void drainSendQueue();
    void sendEvents(const std::string& formId, const whisperbox::json& events, int prio, const std::string& key);
    void publishFormState(const std::string& formId, int prio);
    void wireSchedule();
    void storePull(const std::string& topic);
    void storePullAll();
    void kickPull();
    void onAsk(const whisperbox::json& env);
    void loadPulls();
    void savePulls();
    bool ingestOne(whisperbox::json e, long long netMs, bool live, bool bundled);

    // --- state ---
    std::vector<whisperbox::json> m_log;              // merged, HLC-ordered (single shared log)
    whisperbox::Clock m_clock;
    whisperbox::SignId m_signId;          // local identity (persisted)
    std::string m_deviceId = "whisperbox-core";
    std::string m_dataDir;                // $WHISPERBOX_CORE_DATA, Basecamp module folder, or ~/.whisperbox-core
    std::set<std::string> m_watched;      // locally joined form ids
    std::string m_snapshot = "{}";
    std::string m_status = "Starting...";
    bool m_nodeReady = false;
    bool m_deliveryStarting = false;
    bool m_subscribed = false;
    int64_t m_lastStatusPollMs = 0;
    enum class Via { Unknown, Loam, Direct };
    Via m_via = Via::Unknown;
    bool m_probing = false;
    int m_probeTries = 0;
    int64_t m_probeAt = 0;

    // diagnostic counters (surfaced in snapshot, per logos-distributed-debugging)
    long m_rxRaw = 0, m_rxSeen = 0, m_rxNew = 0, m_rxDup = 0, m_txTotal = 0;
    long m_admDropSig = 0, m_admDropType = 0;
    long m_admDropShape = 0, m_admDropFuture = 0, m_rxBad = 0, m_loadDropped = 0;   // review 2026-10-22 (WB-1/WB-3)
    long m_netTs = 0;   // answers whose network time was recorded or moved earlier
    // answer event id -> earliest Logos Delivery timestamp (ms) seen for it (ADR 0019); nettime.json
    std::map<std::string, long long> m_netTimes;

    int64_t m_lastSyncReserveMs = 0;      // SYNC_REQ-driven re-serve throttle (3s)
    // Re-serving for others (RBSR, SYNC_REQ) is bounded (open-review FR-3): an event served in the
    // last kServeCooldownMs isn't served again, and at most kServeBudget a minute.
    std::map<std::string, int64_t> m_servedMs;   // event key -> last time we served it for a peer
    double m_serveTokens = 0; int64_t m_serveRefillMs = 0;
    long m_serveSkipped = 0;
    bool serveEvent(const whisperbox::json& e);
    int64_t m_lastSeedMs = 0;             // periodic seed throttle (60s)
    int64_t m_lastSyncReqMs = 0;          // last outgoing SYNC_REQ
    int m_syncReqTries = 0;               // outgoing SYNC_REQ attempts (backoff schedule)
    int64_t m_lastStatMs = 0;             // 30s counter dump throttle

    std::recursive_mutex m_mtx;
    QTimer* m_hubTimer = nullptr;
    std::set<std::string> m_mySubmissions; // NOTE: appended at end of class on purpose - see commit message (host SDK layout mismatch clobbers shifted offsets)
    // formId -> my random confirmationId (sealed in my response; lets me spot the
    // creator's public receipt without the receipt being linkable to my address).
    // Appended LAST for the same layout reason as m_mySubmissions.
    std::map<std::string, std::string> m_myConfirmIds;
    long m_rbsrRx = 0;   // RBSR control frames handled (appended last: layout rule above)
    long m_legacyReseeds = 0;   // whole-log answers to unflagged (0.1.x) SYNC_REQs
    // formId -> creator address pinned by the share link it was opened from (by=...).
    std::map<std::string, std::string> m_pinned;
    // Per-form keys: formId -> derived key (cache), and sealed-blob hex -> open result
    // (decrypted json or null + key count tried). Appended last: layout rule above.
    std::map<std::string, whisperbox::SignId> m_formKeyCache;
    struct Opened { whisperbox::json dec; size_t nKeys = 0; };
    std::unordered_map<std::string, Opened> m_openCache;
    whisperbox::OrderedJson decryptView(const whisperbox::OrderedJson& state);
    // Where data lives and whether it can be saved there (shown in the view when not).
    // Appended last: layout rule above.
    std::string m_storageNote;
    bool m_storageOk = true;
    // Local-only: forms hidden from my lists (nothing is deleted - the log is shared), and
    // a private copy of what I answered (the sealed blob only opens for the creator).
    std::set<std::string> m_hidden;
    std::map<std::string, whisperbox::json> m_myAnswers;
    void loadLocalPrefs();
    void saveHidden();
    void saveMyAnswers();
    // 0.3.2: local drafts (forms + half-filled answers), scheduled publishing, automatic
    // receipts per form. Appended last: layout rule above.
    std::map<std::string, whisperbox::json> m_drafts;        // draftId -> {id, def, publishAt|null, updatedAt}
    std::map<std::string, whisperbox::json> m_answerDrafts;  // formId -> answers array
    std::set<std::string> m_autoReceipts;                    // formIds with automatic receipts
    long long m_lastHousekeepMs = 0;
    void saveDrafts();
    void housekeeping();                                     // scheduled publish, auto-close, auto-receipts
    std::string publishDraftLocked(const std::string& draftId);
    // "New answers": responses seen per form (local). A form first seen with N responses
    // starts at N (no stale badge on upgrade). Appended last: layout rule above.
    std::map<std::string, long long> m_seen;
    void saveSeen();
    // Co-owned forms: formId|sealedKey -> the form key opened with my identity. Appended last.
    std::map<std::string, whisperbox::SignId> m_coKeyCache;
    bool isCoOwner(const whisperbox::OrderedJson& f) const;
    std::set<std::string> coOwnedForms(const whisperbox::OrderedJson& state);
    const whisperbox::SignId* coOwnerKey(const std::string& formId, const whisperbox::OrderedJson& f);
    // Quiz + private replies. Appended last.
    std::map<std::string, const whisperbox::SignId*> formKeysFor(const whisperbox::OrderedJson& state);
    std::map<std::string, nlohmann::json> m_quizCache;    // quizKey hex -> opened answer key
    std::map<std::string, nlohmann::json> m_replyCache;   // sealed reply hex -> opened reply
    nlohmann::json quizOf(const whisperbox::OrderedJson& f, const std::map<std::string, const whisperbox::SignId*>& keys);
    void enrichResponses(const whisperbox::OrderedJson& state, const std::string& formId, nlohmann::json& responses,
                         const std::map<std::string, const whisperbox::SignId*>& keys);
    std::string sendReply(const std::string& formId, const std::string& cid, const std::string& replyPub, const nlohmann::json& body);
    // open-review 2026-11-01, FR-3 (appended last: layout rule above): answers from the network have a
    // budget, the log a size cap, and a burst of received events is saved and published once, not per event
    long m_admDropBudget = 0, m_admDropFull = 0;
    double m_respTokens = 0; int64_t m_respRefillMs = 0;
    size_t m_logBytes = 0, m_logResponses = 0;
    void recountLog();
    QTimer* m_flushTimer = nullptr;
    bool m_logDirty = false, m_publishDirty = false;
    void scheduleFlush();
    void flushNow();
    // open-review 2026-11-02 (0.5.4; appended last: layout rule above).
    // FR-2/5/7: the fold and the creator view are cached until the log, the pins or the identity
    // change (every snapshot re-folded and re-verified the whole log), and signatures are checked
    // once, at admission and load.
    uint64_t m_logGen = 1, m_pinsGen = 1, m_netGen = 1;
    bool m_foldValid = false; uint64_t m_foldLogGen = 0, m_foldPinsGen = 0; std::string m_foldIdent;
    whisperbox::OrderedJson m_foldCache;
    std::unordered_set<std::string> m_foldIds;
    const whisperbox::OrderedJson& foldedState();
    bool m_cvValid = false; uint64_t m_cvLogGen = 0, m_cvPinsGen = 0, m_cvNetGen = 0; std::string m_cvIdent;
    whisperbox::OrderedJson m_cvCache;
    // FR-6: the held copy's HLC per event key: a duplicate is known without scanning the log
    std::unordered_map<std::string, whisperbox::json> m_heldHlc;
    bool m_netDirty = false;
    // FR-2/4: budgets for signed events and catch-up control frames from the network
    double m_sigTokens = 0; int64_t m_sigRefillMs = 0;
    double m_ctlTokens = 0; int64_t m_ctlRefillMs = 0;
    long m_ctlDropBudget = 0;
    bool takeToken(double& tokens, int64_t& refillMs, double budgetPerMin);
    // FR-4: a sorted id index for catch-up, rebuilt when the log changes
    uint64_t m_rbsrGen = 0;
    whisperbox::rbsr::Index m_rbsr;
    std::unordered_map<std::string, size_t> m_rbsrPos;   // event key -> index into m_log
    void rbsrIndex();
    void rbsrRespond(const whisperbox::json& msg);
    // FR-8: transport callbacks outlive the module; they reach it only through this
    struct Life { std::mutex mu; WhisperboxCoreImpl* self = nullptr; };
    std::shared_ptr<Life> m_life;
    static void withSelf(const std::shared_ptr<Life>& life, std::function<void(WhisperboxCoreImpl*)> fn);
    // FR-14: a failed transport start is retried
    int64_t m_lastStartMs = 0;
    long m_startFailures = 0;
    bool adoptChecked(const whisperbox::json& e);   // FR-9/10: only events peers accept
    // open-review 2026-11-03 (0.5.5; appended last: layout rule above).
    // FR-1: each held event's size, so a replacement is charged for what it adds
    std::unordered_map<std::string, size_t> m_heldBytes;
    // FR-5: the log on disk = events.json (base) + events.journal (appended lines)
    std::vector<whisperbox::json> m_journalPending;
    size_t m_journalBytes = 0, m_baseBytes = 0;
    void flushLog();
    // FR-3: when this device first saw each answer (local clock)
    std::map<std::string, long long> m_firstSeen;
    bool m_firstDirty = false;
    void noteFirstSeen(const whisperbox::json& e);
    void saveFirstSeen();
    // FR-12: quiz scores per answer, until the form or the answer changes
    std::unordered_map<std::string, whisperbox::json> m_scoreCache;
    // FR-13: an optional passphrase over the identity and the private local files
    bool m_protected = false, m_locked = false;
    std::string m_lockedAddress;
    whisperbox::json m_lockedIdentity;
    whisperbox::Bytes m_vaultKey, m_vaultSalt;
    std::string readPrivate(const std::string& name, bool& readable);
    void writePrivate(const std::string& name, const std::string& text);
    void loadPrivateFiles();
    // FR-7/14: deleted drafts kept (the last 20), drafts saved per flush, sizes bounded
    std::vector<whisperbox::json> m_draftTrash;
    bool m_draftsDirty = false;
    size_t draftsBytes() const;
};
