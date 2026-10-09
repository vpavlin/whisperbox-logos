#pragma once
// FAKE logos SDK (test-only). Just enough of the universal-module surface for
// whisperbox_core_impl.cpp to compile and run OUTSIDE nix/Basecamp:
// LogosModuleContext + modules().loam_core backed by an in-process bus
// (fake_bus.h) that mimics loam_core semantics (shared node, SDS self-filter by
// senderId, base64 payloads, async callbacks on the Qt event loop). NOT shipped; the real header comes
// from logos-module-builder at nix build time.
#include <functional>
#include <string>
#include <vector>
#include <cstdint>
#include <nlohmann/json.hpp>

#define logos_events public

using LogosMap = nlohmann::json;
struct StdLogosResult { bool success = true; std::string error; LogosMap value; };

struct FakeNode;   // fake_bus.h
// loam_core as the app sees it (Basecamp 0.3): one shared transport; start -> statusChanged
// "Connected"; join(topic); sendSealed(topic, base64(bytes)); received(topic, senderId,
// base64(bytes), ts) for everyone else's frames on joined topics.
struct FakeLoamCore {
    FakeNode* node = nullptr;
    using RxFn = std::function<void(const std::string&, const std::string&, const std::string&, int64_t)>;
    using StatusFn = std::function<void(const std::string&)>;
    using StrCb = std::function<void(std::string)>;
    void onReceived(RxFn fn);
    void onStatusChanged(StatusFn fn);
    void setSenderIdAsync(const std::string& id, StrCb cb);
    void startAsync(const std::string& cfg, StrCb cb);
    void statusAsync(StrCb cb);
    void joinAsync(const std::string& topic, StrCb cb);
    void sendSealedAsync(const std::string& topic, const std::string& sealedB64, StrCb cb);
};
struct FakeModules { FakeLoamCore loam_core; };

class LogosModuleContext {
public:
    virtual ~LogosModuleContext() = default;
    FakeModules& modules() { return m_fakeModules; }
    void fakeStart() { onContextReady(); }
    const std::string& instancePersistencePath() const { return m_fakePersist; }
    std::string m_fakePersist;
    FakeModules m_fakeModules;
protected:
    virtual void onContextReady() {}
};
