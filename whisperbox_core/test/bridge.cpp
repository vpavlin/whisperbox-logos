// bridge.cpp — the REAL whisperbox_core (C++) on the fake delivery bus, with one external
// "phone" node piped over stdin/stdout, so a JS client (packages/client) can be tested
// against the desktop implementation byte-for-byte on the wire.
//
// stdin  (one JSON per line):
//   {"tx":"<base64 of the phone's envelope bytes>","layers":1|2}   phone publishes
//   {"call":"<method>","peer":"A","args":[...],"id":n}               call a core method
//   {"spawn":"B"}                                                    start another core peer
//   {"pump":ms}                                                      run the event loop
// stdout:
//   {"rx":"<base64 of payload bytes delivered to the phone>"}        traffic for the phone
//   {"id":n,"result":<json>}                                         call results
//   {"pumped":ms}
#include "whisperbox_core_impl.h"
#include "fake_bus.h"
#include <QElapsedTimer>
#include <QSocketNotifier>
#include <iostream>
#include <map>
#include <memory>
#include <unistd.h>

using whisperbox::json;
void WhisperboxCoreImpl::stateChanged(const std::string&) {}
void WhisperboxCoreImpl::statusChanged(const std::string&) {}

struct Peer {
    std::unique_ptr<FakeNode> node;
    std::unique_ptr<WhisperboxCoreImpl> core;
};
static std::map<std::string, Peer> peers;
static std::string base;

static void out(const json& j) { std::cout << j.dump() << "\n" << std::flush; }

static void spawn(const std::string& name) {
    setenv("WHISPERBOX_CORE_DATA", (base + "/" + name).c_str(), 1);
    Peer& p = peers[name];
    p.node = std::make_unique<FakeNode>(); p.node->name = name;
    p.core = std::make_unique<WhisperboxCoreImpl>();
    p.core->modules().delivery_module.node = p.node.get();
    FakeBus::get().nodes.push_back(p.node.get());
    p.core->fakeStart();
}
static void pump(int ms) {
    QElapsedTimer t; t.start();
    while (t.elapsed() < ms) { QCoreApplication::processEvents(QEventLoop::AllEvents, 20); usleep(2000); }
}
static json callCore(WhisperboxCoreImpl* c, const std::string& m, const json& a) {
    auto s = [&](int i) { return a.size() > (size_t)i ? a[i].get<std::string>() : std::string(); };
    std::string r;
    if (m == "snapshot") r = c->snapshot();
    else if (m == "createForm") r = c->createForm(s(0));
    else if (m == "closeForm") r = c->closeForm(s(0));
    else if (m == "confirmResponse") r = c->confirmResponse(s(0), s(1));
    else if (m == "submitResponse") r = c->submitResponse(s(0), s(1));
    else if (m == "getDecryptedResponses") r = c->getDecryptedResponses(s(0));
    else if (m == "importForm") r = c->importForm(s(0));
    else if (m == "shareUri") r = c->shareUri(s(0));
    else if (m == "exportCsv") r = c->exportCsv(s(0));
    else if (m == "resync") r = c->resync();
    else if (m == "reopenForm") r = c->reopenForm(s(0));
    else if (m == "confirmAll") r = c->confirmAll(s(0));
    else return json{{"error", "unknown method " + m}};
    return json::parse(r);
}

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    char tmpl[] = "/tmp/wb-bridge-XXXXXX"; base = mkdtemp(tmpl);

    // The phone: a node on the bus that hands everything it receives to stdout.
    FakeNode phone; phone.name = "phone"; phone.up = true; phone.subscribed = true; phone.channel = true; phone.senderId = "phone";
    auto toPhone = [](const std::string&, const std::string&, const LogosMap& p, int64_t) {
        out(json{{"rx", p["_bytes"].get<std::string>()}});
    };
    phone.onMsg = toPhone; phone.onCh = toPhone;
    FakeBus::get().nodes.push_back(&phone);
    spawn("A");

    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.empty()) continue;
        json cmd = json::parse(line, nullptr, false);
        if (!cmd.is_object()) continue;
        if (cmd.contains("tx")) {
            // Waku payload a phone produces: loam-transport hands the FFI base64(base64(bytes)),
            // the FFI decodes once, so the wire carries base64(envelope) - layers=1 (also what
            // the desktop core sends). layers=0 = raw envelope bytes, which the core accepts too.
            std::string env = whisperbox::b64decode(cmd["tx"].get<std::string>());
            std::string wire = cmd.value("layers", 1) == 0 ? env : whisperbox::b64encode(env);
            FakeBus::get().relay(&phone, whisperbox::TOPIC, wire);
        } else if (cmd.contains("call")) {
            Peer& p = peers[cmd.value("peer", "A")];
            out(json{{"id", cmd.value("id", 0)}, {"result", callCore(p.core.get(), cmd["call"], cmd.value("args", json::array()))}});
        } else if (cmd.contains("spawn")) {
            spawn(cmd["spawn"]); out(json{{"spawned", cmd["spawn"]}});
        } else if (cmd.contains("pump")) {
            pump(cmd["pump"].get<int>()); out(json{{"pumped", cmd["pump"]}});
        }
    }
    for (auto& kv : peers) {
        auto& v = FakeBus::get().nodes; v.erase(std::remove(v.begin(), v.end(), kv.second.node.get()), v.end());
        kv.second.core.reset();
    }
    std::system(("rm -rf '" + base + "'").c_str());
    return 0;
}
