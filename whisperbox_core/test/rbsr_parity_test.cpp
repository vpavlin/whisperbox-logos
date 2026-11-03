// whisperbox_rbsr.hpp == logos_sync/catchup.hpp (open-review 2026-11-02, FR-4): the indexed responder
// must send byte-identical messages, or peers on the vendored responder would never agree.
#include "whisperbox_rbsr.hpp"
#include "logos_sync/catchup.hpp"
#include <cstdio>
#include <random>

using whisperbox::rbsr::json;
static int fails = 0, checks = 0;
#define CHECK(c, m) do { checks++; if (!(c)) { fails++; std::printf("  FAIL %s\n", m); } } while (0)

int main() {
    std::mt19937 rng(20261102);
    auto rid = [&]() { std::string s = "resp:"; for (int i = 0; i < 12; i++) s.push_back("0123456789abcdef"[rng() % 16]); return s; };
    for (int trial = 0; trial < 300; trial++) {
        // two overlapping sets
        std::vector<std::string> common, a, b;
        const int nc = rng() % 400, na = rng() % 60, nb = rng() % 60;
        for (int i = 0; i < nc; i++) common.push_back(rid());
        a = common; b = common;
        for (int i = 0; i < na; i++) a.push_back(rid());
        for (int i = 0; i < nb; i++) b.push_back(rid());
        std::vector<logos_sync::Event> ea, eb;
        for (auto& x : a) { logos_sync::Event e; e.id = x; ea.push_back(e); }
        for (auto& x : b) { logos_sync::Event e; e.id = x; eb.push_back(e); }
        whisperbox::rbsr::Index ia, ib; ia.build(a); ib.build(b);
        // initial message
        json want0 = logos_sync::catchup::buildInitial(eb, "B"), got0 = whisperbox::rbsr::initialMessage(ib, "B");
        CHECK(want0 == got0, "initial fp message");
        // run a full exchange A<->B with both responders, compare every step
        std::vector<json> queue{want0};
        int steps = 0;
        while (!queue.empty() && steps < 200) {
            json m = queue.front(); queue.erase(queue.begin()); steps++;
            const bool toA = m.value("from", "") == "B";
            const auto& evs = toA ? ea : eb; const auto& idx = toA ? ia : ib; const std::string me = toA ? "A" : "B";
            auto w = logos_sync::catchup::respond(evs, m, me);
            whisperbox::rbsr::Limits lim; lim.maxServe = 1u << 30; lim.maxNeed = 1u << 30;
            auto g = whisperbox::rbsr::respond(idx, m, me, lim);
            CHECK(!g.bad, "a well-formed frame is accepted");
            CHECK(w.replies.size() == g.replies.size(), "same number of replies");
            for (size_t i = 0; i < w.replies.size() && i < g.replies.size(); i++) CHECK(w.replies[i] == g.replies[i], "same reply");
            std::vector<std::string> ws; for (auto& e : w.serve) ws.push_back(e.id);
            CHECK(ws == g.serve, "same events served");
            for (auto& r : w.replies) queue.push_back(r);
        }
    }
    // hostile frames are refused
    whisperbox::rbsr::Index ix; ix.build({"a", "b", "c"});
    json fps = json::array(); for (int i = 0; i < 64; i++) fps.push_back("00");
    json bounds = json::array(); for (int i = 0; i < 63; i++) bounds.push_back("b" + std::to_string(i));
    CHECK(whisperbox::rbsr::respond(ix, json{{"v", 2}, {"t", "fp"}, {"from", "x"}, {"bounds", bounds}, {"fps", fps}}, "me").bad, "64 ranges are refused");
    CHECK(whisperbox::rbsr::respond(ix, json{{"v", 2}, {"t", "fp"}, {"from", "x"}, {"bounds", {"c", "a"}}, {"fps", {"00", "00", "00"}}}, "me").bad, "decreasing bounds are refused");
    std::vector<std::string> many; for (int i = 0; i < 5000; i++) many.push_back("z" + std::to_string(i));
    auto st = whisperbox::rbsr::respond(ix, json{{"v", 2}, {"t", "ids"}, {"from", "x"}, {"ids", many}}, "me");
    CHECK(st.replies.size() == 1 && st.replies[0]["ids"].size() == 500, "a need reply is capped at 500 ids");
    std::printf("%d/%d checks passed\n%s\n", checks - fails, checks, fails ? "RBSR PARITY FAILED" : "RBSR PARITY GREEN");
    return fails ? 1 : 0;
}
