// Offscreen QQuickView render harness for the whisperbox view.
// Loads the REAL module/Main.qml with a mock `logos` context property that
// serves a fixture snapshot, lets the poll timers fire, then saves a screenshot
// and reports any QML errors. Catches runtime QML errors qmllint cannot.
//
// Build: see render.sh (compiles against the nix-store Qt6 the design system
// was built with).
// Usage: harness <Main.qml> <fixture.json> [out.png]

#include <QGuiApplication>
#include <QQmlEngine>
#include <QQmlContext>
#include <QQmlComponent>
#include <QQuickView>
#include <QQuickItem>
#include <QWindow>
#include <QImage>
#include <QTimer>
#include <QFile>
#include <QMessageLogger>
#include <QString>
#include <QVariantList>
#include <cstdio>

static int g_qmlErrors = 0;
static bool g_viewError = false;

static void messageHandler(QtMsgType type, const QMessageLogContext &ctx, const QString &msg) {
    QString line = msg;
    if (type == QtWarningMsg || type == QtCriticalMsg || type == QtFatalMsg) {
        // Count real QML/runtime errors (typos, missing types/props, binding loops).
        if (line.contains("is not a type") || line.contains("Cannot assign to non-existent property")
            || line.contains("TypeError") || line.contains("ReferenceError")
            || line.contains("qrc:/") && line.contains("error")) {
            g_qmlErrors++;
        }
    }
    fprintf(stderr, "[%s] %s\n",
            type == QtDebugMsg ? "D" : type == QtInfoMsg ? "I" : type == QtWarningMsg ? "W" : "E",
            line.toUtf8().constData());
}

class MockLogos : public QObject {
    Q_OBJECT
public:
    explicit MockLogos(const QString &fixture, QObject *parent = nullptr)
        : QObject(parent), m_fixture(fixture) {}

    Q_INVOKABLE QString callModule(const QString &mod, const QString &method, const QVariantList &args) {
        if (mod != "whisperbox_core") return "{\"error\":\"unknown module\"}";
        if (method == "snapshot" || method == "status") return m_fixture;
        // Canned mutation responses so click-through paths don't error.
        if (method == "createForm") return "{\"ok\":true,\"formId\":\"form-harness1\",\"event\":{}}";
        if (method == "shareUri") return "{\"ok\":true,\"uri\":\"whisperbox://form?harness\"}";
        if (method == "shareQr") {
            // 5x5 all-dark matrix — exercises the Canvas paint path.
            QString cells;
            for (int i = 0; i < 25; i++) { cells += "true,"; }
            return "{\"ok\":true,\"n\":5,\"cells\":[" + cells.mid(0, cells.size() - 1) + "]}";
        }
        if (method == "exportCsv") return "{\"ok\":true,\"csv\":\"respondent,q1\\n0xabc,hi\"}";
        return "{\"ok\":true}";
    }

    Q_INVOKABLE void onModuleEvent(const QString &mod, const QString &ev) {}

signals:
    void moduleEventReceived(const QString &mod, const QString &ev, const QString &data);

private:
    QString m_fixture;
};

#include "harness.moc"

int main(int argc, char **argv) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
    qputenv("QT_QUICK_BACKEND", "software");
    QGuiApplication app(argc, argv);
    qInstallMessageHandler(messageHandler);

    if (argc < 3) {
        fprintf(stderr, "usage: harness <Main.qml> <fixture.json> [out.png]\n");
        return 2;
    }
    QFile fx(argv[2]);
    if (!fx.open(QIODevice::ReadOnly)) {
        fprintf(stderr, "cannot open fixture %s\n", argv[2]);
        return 2;
    }
    QString fixture = QString::fromUtf8(fx.readAll());

    QQuickView view;
    view.setResizeMode(QQuickView::SizeRootObjectToView);
    view.resize(1280, 800);

    // NOTE: QQuickView owns its OWN QQmlEngine — context properties must be set
    // on view.engine(), not a separate engine, or the component never sees them.
    auto *logos = new MockLogos(fixture, &view);
    view.engine()->rootContext()->setContextProperty("logos", logos);

    QObject::connect(&view, &QQuickView::statusChanged, [](QQuickView::Status s) {
        if (s == QQuickView::Error) {
            g_viewError = true;
            fprintf(stderr, "RENDER FAIL: view status Error\n");
        }
    });
    view.setSource(QUrl::fromLocalFile(argv[1]));
    view.show();   // offscreen: still triggers proper exposure + scene-graph frames
    QTimer::singleShot(1000, [&view] {
        QQuickItem *r = view.rootObject();
        fprintf(stderr, "DEBUG: view=%dx%d root=%s w=%.0f h=%.0f\n",
                (int)view.width(), (int)view.height(), r ? "ok" : "null",
                r ? r->width() : -1, r ? r->height() : -1);
    });

    // Let the 2.5s poll + Qt.callLater deferrals run, then screenshot.
    QString outPath = argc > 3 ? QString::fromLocal8Bit(argv[3]) : QString();
    QTimer::singleShot(4500, [&view, &outPath] {
        if (!outPath.isEmpty()) view.grabWindow().save(outPath);
        bool ok = (g_qmlErrors == 0) && !g_viewError;
        fprintf(stderr, "RENDER %s: qmlErrors=%d viewError=%d\n", ok ? "OK" : "FAIL", g_qmlErrors, (int)g_viewError);
        QGuiApplication::exit(ok ? 0 : 1);
    });
    QTimer::singleShot(20000, [] {
        fprintf(stderr, "RENDER TIMEOUT\n");
        QGuiApplication::exit(3);
    });

    return app.exec();
}
