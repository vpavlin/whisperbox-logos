#!/usr/bin/env bash
# publish.sh <apkver> <prev-apkver> <prev-versionCode> <new-versionCode> <lgxver> <prev-lgxver> "<what's new>"
#
# After release.sh: replace the binaries on the `artifacts` branch (releases/0.3.x/),
# regenerate SHA256SUMS, bump the versions / commit / what's-new line in that branch's
# README, push, then re-download each file from raw.githubusercontent.com and print its
# sha256 next to the local one (the two columns must match).
# Example: publish.sh 0.3.9 0.3.8 12 13 0.3.8 0.3.7 "quiz mode + private replies"
set -e
[ $# -eq 7 ] || { sed -n 2,9p "$0"; exit 2; }
AV=$1; PAV=$2; PC=$3; NC=$4; LV=$5; PLV=$6; WN=$7
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WB_OUT="${WB_OUT:-$HOME/.cache/whisperbox-release}"
REPO_SLUG="${WB_REPO_SLUG:-vpavlin/whisperbox-logos}"
cd "$ROOT"
SRC_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
cp mobile/android/app/build/outputs/apk/release/app-release.apk "$WB_OUT/whisperbox-$AV.apk"
W="$WB_OUT/artifacts-wt"; git worktree remove --force "$W" 2>/dev/null || true; rm -rf "$W"
git fetch -q origin artifacts; git worktree add -q "$W" -B artifacts origin/artifacts >/dev/null 2>&1; cd "$W"
D=releases/0.3.x; git rm -q $D/*.apk $D/*.lgx
cp "$WB_OUT/whisperbox-$AV.apk" $D/
cp "$WB_OUT"/relN/logos-whisperbox_core-module-lib.lgx "$D/logos-whisperbox_core-module-lib-$LV.lgx"
cp "$WB_OUT"/relN-1/logos-whisperbox-module.lgx "$D/logos-whisperbox-module-$LV.lgx"
chmod 644 $D/*; (cd $D && sha256sum *.apk *.lgx > SHA256SUMS)
C=$(git -C "$ROOT" rev-parse --short HEAD)
E() { echo "$1" | sed 's/\./\\./g'; }
sed -i "s/commit \`[0-9a-f]*\`/commit \`$C\`/; s/whisperbox-$(E $PAV)\.apk/whisperbox-$AV.apk/g; s/versionName $(E $PAV), versionCode $PC/versionName $AV, versionCode $NC/; s/-$(E $PLV)\.lgx/-$LV.lgx/g; s/module \`whisperbox_core\` $(E $PLV)/module \`whisperbox_core\` $LV/; s/view \`whisperbox\` $(E $PLV)/view \`whisperbox\` $LV/; s/core and view, $(E $PLV)/core and view, $LV/" README.md
WN="$WN" SB="$SRC_BRANCH" python3 - <<'PY'
import re,os
p='README.md'; s=open(p).read()
s=re.sub(r"What's new: [^\n]*\n[^\n]*\n[^\n]*\n", "What's new: "+os.environ["WN"]+"\n- see CHANGELOG.md on `"+os.environ["SB"]+"`.\n\n", s, count=1)
open(p,'w').write(s)
PY
git add -A && git -c user.name="$(git -C "$ROOT" config user.name)" -c user.email="$(git -C "$ROOT" config user.email)" \
  commit -q -m "artifacts: Android $AV + Basecamp $LV (from $SRC_BRANCH @ $C)" && git push -q origin HEAD:artifacts
cd "$ROOT" && git worktree remove --force "$W"
echo "remote (raw.githubusercontent.com) vs local sha256:"
for f in whisperbox-$AV.apk logos-whisperbox_core-module-lib-$LV.lgx logos-whisperbox-module-$LV.lgx; do
  r=$(curl -sL "https://raw.githubusercontent.com/$REPO_SLUG/artifacts/releases/0.3.x/$f" | sha256sum | cut -c1-12); echo "$r $f"
done
sha256sum "$WB_OUT/whisperbox-$AV.apk" "$WB_OUT"/relN/*.lgx "$WB_OUT"/relN-1/*.lgx | cut -c1-12
