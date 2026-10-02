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

    // Contested form id (id squatting): same projections as the TS reference, for any
    // arrival order of the five signed events.
    {
        OrderedJson sq = load(fx + "golden-squat.json");
        std::vector<json> evs; for (auto& e : sq["log"]) evs.push_back(json::parse(e.dump()));
        const std::string creator = sq["creator"];
        bool ok = true;
        for (int t = 0; t < 30 && ok; t++) {
            std::vector<json> order = evs; std::shuffle(order.begin(), order.end(), rng);
            std::vector<json> log; for (auto& e : order) mergeOne(log, e);
            ok = log.size() == evs.size()
              && json::parse(computeState(log, creator).dump()) == json::parse(sq["asCreator"].dump())
              && json::parse(computeState(log, "", nullptr, {{"fs", creator}}).dump()) == json::parse(sq["pinned"].dump())
              && json::parse(computeState(log).dump()) == json::parse(sq["browsing"].dump());
        }
        CHECK(ok, "contested id: creator / link-pinned / browsing projections == TS (30 arrival orders)");
    }

    // Lifecycle (0.3.2): close -> re-open -> close, answer cap, close-at date, batch receipts.
    {
        OrderedJson lf = load(fx + "golden-lifecycle.json");
        std::vector<json> evs; for (auto& e : lf["log"]) evs.push_back(json::parse(e.dump()));
        const std::string creator = lf["creator"];
        SignId cid = identityFromPriv(fromHex(lf["privHex"].get<std::string>()));
        auto openC = [&](const std::string& hex) -> json {
            try { Bytes pt = eciesOpen(cid.priv, fromHex(hex)); return json::parse(std::string(pt.begin(), pt.end())); } catch (...) { return json(); }
        };
        bool ok = true;
        for (int t = 0; t < 30 && ok; t++) {
            std::vector<json> order = evs; std::shuffle(order.begin(), order.end(), rng);
            std::vector<json> log; for (auto& e : order) mergeOne(log, e);
            OrderedJson st = computeState(log, creator);
            ok = json::parse(st.dump()) == json::parse(lf["state"].dump())
              && json::parse(creatorView(st, creator, openC).dump()) == json::parse(lf["view"].dump());
            if (!ok) std::printf("    got state: %.600s\n", st.dump().c_str());
        }
        CHECK(ok, "lifecycle: re-open spans, answer cap, close-at date, batch receipts == TS (30 arrival orders)");
        std::vector<std::string> ids = {"c-life-350", "c-life-150"};
        bool idOk = false;
        for (auto& e : lf["log"]) if (e["id"].get<std::string>().rfind("confirm:life:b:", 0) == 0) idOk = e["id"] == responseConfirmBatchId("life", ids);
        CHECK(idOk, "batch receipt id == TS (content-addressed over sorted ids)");
    }

    std::printf(failures ? "ENGINE GOLDEN FAILED\n" : "ENGINE GOLDEN GREEN\n");
    return failures ? 1 : 0;
}
