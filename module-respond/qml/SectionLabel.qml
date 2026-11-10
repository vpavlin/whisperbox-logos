// SectionLabel.qml - shared by the WhisperBox studio and the respond module (keep both copies identical:
// scripts/sync-respond.sh copies, the view test checks).
import QtQuick
import "WbPalette.js" as P

Text { textFormat: Text.PlainText; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 0.6; color: P.wbTextTert }
