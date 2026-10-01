#pragma once
// FAKE logos SDK (test-only). Just enough of the universal-module surface for
// whisperbox_core_impl.cpp to compile and run OUTSIDE nix/Basecamp:
// LogosModuleContext + modules().delivery_module backed by an in-process bus
// (fake_bus.h) that mimics delivery_module semantics (relay echo to self,
// SDS channel self-filter by senderId, {"_bytes": base64} receive wrapping,
// async callbacks on the Qt event loop). NOT shipped; the real header comes
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
struct FakeDeliveryModule {
    FakeNode* node = nullptr;
    using MsgFn = std::function<void(const std::string&, const std::string&, const LogosMap&, int64_t)>;
    bool onMessageReceived(MsgFn fn);
    bool onChannelMessageReceived(MsgFn fn);
    void createNodeAsync(const std::string& cfg, std::function<void(StdLogosResult)> cb);
    void startAsync(std::function<void(StdLogosResult)> cb);
    void subscribeAsync(const std::string& topic, std::function<void(StdLogosResult)> cb);
    void channelCreateAsync(const std::string& channelId, const std::string& topic, const std::string& senderId, std::function<void(StdLogosResult)> cb);
    void channelSendAsync(const std::string& channelId, const LogosMap& payload, std::function<void(StdLogosResult)> cb);
    void sendAsync(const std::string& topic, const std::vector<uint8_t>& raw, std::function<void(StdLogosResult)> cb);
};
struct FakeModules { FakeDeliveryModule delivery_module; };

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
