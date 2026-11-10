#pragma once
// FAKE logos::LpClient (test-only): raw event subscriptions to delivery_module for the direct
// transport (ADR 0021). The real client is created without a node, so a subscription waits here until
// the fake delivery_module next hears from that core (the transport always subscribes right before
// it calls createNode / start, on the same call stack) and binds it to its node.
#include <functional>
#include <string>
#include <utility>
#include <vector>
#include <nlohmann/json.hpp>

namespace logos {
using RawFn = std::function<void(nlohmann::json)>;
inline std::vector<std::pair<std::string, RawFn>>& fakeLpPending() { static std::vector<std::pair<std::string, RawFn>> v; return v; }
class LpSubscription {
public:
    LpSubscription() = default;
    explicit LpSubscription(bool ok) : m_ok(ok) {}
    bool valid() const { return m_ok; }
private:
    bool m_ok = false;
};
class LpClient {
public:
    LpClient(std::string target, std::string origin) : m_target(std::move(target)), m_origin(std::move(origin)) {}
    LpSubscription subscribe(const std::string& event, RawFn fn) { fakeLpPending().push_back({event, std::move(fn)}); return LpSubscription(true); }
private:
    std::string m_target, m_origin;
};
}
