#pragma once
// whisperbox_core — shared types (mirrors packages/contract TS reference).
#include <string>
#include <nlohmann/json.hpp>

namespace whisperbox {

using json = nlohmann::json;

struct HLC { long long wall = 0; long long ctr = 0; std::string dev; };

// Event envelope (loam-sync shape) + optional authenticity layer.
struct Event {
    int v = 1;
    std::string id;
    std::string type;
    HLC hlc;
    std::string dev;
    json payload;
    std::string pub; // hex compressed pubkey (signed events)
    std::string sig; // hex compact r||s (signed events)
};

} // namespace whisperbox
