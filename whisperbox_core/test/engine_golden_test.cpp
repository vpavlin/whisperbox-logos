// engine_golden_test.cpp — TS↔C++ parity for the ENGINE (merge + fold + creator
// view). Reads packages/engine/test/fixtures (written by gen-fixtures.mjs) and
// checks whisperbox_engine.hpp reproduces them key-order-exactly.
// Usage: engine_golden_test <repo-root>
#include <cstdio>
#include <fstream>
#include <random>
#include "src/whisperbox_identity.hpp"
#include "src/whisperbox_engine.hpp"

using namespace whisperbox;
static int failures = 0;
#define CHECK(cond, label) do { if (cond) std::printf("  ok   %s\n", label); else { std::printf("  FAIL %s\n", label); failures++; } } while (0)

static OrderedJson load(const std::string& p) {
    std::ifstream f(p); if (!f) { std::fprintf(stderr, "cannot open %s\n", p.c_str()); std::exit(2); }
    return OrderedJson::parse(f);
}

int main(int argc, char** argv) {
    const std::string fx = std::string(argc > 1 ? argv[1] : ".") + "/packages/engine/test/fixtures/";
    OrderedJson merged = load(fx + "golden-merged.json"), wantState = load(fx + "golden-state.json"),
                wantView = load(fx + "golden-creatorview.json"), meta = load(fx + "golden-meta.json");
    std::vector<json> log; for (auto& e : merged) log.push_back(json::parse(e.dump()));

    // merge: any arrival order / redelivery reproduces the golden merged log
    std::mt19937 rng(164); bool mergeOk = true;
    for (int t = 0; t < 20 && mergeOk; t++) {
        std::vector<json> a = log, b = log; std::shuffle(a.begin(), a.end(), rng); std::shuffle(b.begin(), b.end(), rng);
        std::vector<std::vector<json>> L; L.push_back(a); L.push_back(b);
        auto m = mergeWhisperbox(L);
        mergeOk = json(m).dump() == json(log).dump();
        std::vector<json> inc; for (auto& e : a) mergeOne(inc, e);
        mergeOk = mergeOk && json(inc).dump() == json(log).dump();
    }
    CHECK(mergeOk, "merge (batch + incremental) reproduces golden-merged under shuffles");

    const std::string ident = meta["identity"];
    OrderedJson state = computeState(log, ident);
    // Semantic equality (C++ events are nlohmann::json → nested payload keys are
    // alphabetical; the engine never reads bytes) + strict ORDER where it matters:
    // arrays compare in order, and the forms map must keep HLC publish order.
    auto keys = [](const OrderedJson& o) { std::string k; for (auto it = o.begin(); it != o.end(); ++it) k += it.key() + ","; return k; };
    CHECK(json::parse(state.dump()) == json::parse(wantState.dump()), "computeState == golden-state");
    CHECK(keys(state["forms"]) == keys(wantState["forms"]), "forms keep HLC publish order");
    if (json::parse(state.dump()) != json::parse(wantState.dump())) std::printf("    got:  %.300s\n    want: %.300s\n", state.dump().c_str(), wantState.dump().c_str());

    SignId id = identityFromPriv(fromHex(meta["privHex"].get<std::string>()));
    CHECK(id.valid && id.address == ident, "golden creator identity derives");
    auto open = [&](const std::string& hex) -> json {
        try { Bytes pt = eciesOpen(id.priv, fromHex(hex)); return json::parse(std::string(pt.begin(), pt.end())); }
        catch (...) { return json(); }
    };
    OrderedJson view = creatorView(state, ident, open);
    CHECK(json::parse(view.dump()) == json::parse(wantView.dump()), "creatorView == golden-creatorview (incl. response order)");
    if (json::parse(view.dump()) != json::parse(wantView.dump())) std::printf("    got:  %.400s\n    want: %.400s\n", view.dump().c_str(), wantView.dump().c_str());
    int n = 0; for (auto it = view["responses"].begin(); it != view["responses"].end(); ++it) n += (int)it.value().size();
    CHECK(n > 0, "golden creator view is non-trivial");

    std::printf(failures ? "ENGINE GOLDEN FAILED\n" : "ENGINE GOLDEN GREEN\n");
    return failures ? 1 : 0;
}
