#!/usr/bin/env bash
# Interaction scenarios for the whisperbox view: renders every screen against the
# REAL-core fixtures (regenerate: WB_DUMP_FIXTURES=… whisperbox_core/test/run-e2e.sh)
# and asserts the view->core call contract (method, argc, argument shape).
# Run render.sh first (builds ./harness). Env: WB_DS, WB_OUT as for render.sh.
set -uo pipefail
HDIR="$(cd "$(dirname "$0")" && pwd)"
QML="$HDIR/../../module/Main.qml"
FX="$HDIR/fixtures"
OUT="${WB_OUT:-/tmp/wb-harness}/scenarios"
mkdir -p "$OUT"
[ -x "$HDIR/harness" ] || { echo "build the harness first: render.sh" >&2; exit 2; }
# shellcheck disable=SC1091
. "$HDIR/harness.env"   # written by render.sh: the Qt runtime the harness was linked against

# form id lookup: fid <fixture> <title>
fid() { python3 -c "import json,sys; d=json.load(open('$FX/$1.json')); print(next(k for k,v in d['state']['forms'].items() if v['title']=='$2'))"; }
pend() { python3 -c "import json; print(json.load(open('$FX/pending.json'))['pendingForms'][0])"; }

FAIL=0
# run <name> <fixture> <props-json> [invoke] ; then optional expectations via expect/deny
run() {
    local name=$1 fx=$2 props=$3 inv=${4:-}
    WB_PROPS="$props" WB_INVOKE="$inv" WB_CLICKS="${WB_CLICKS:-}" WB_DUMP="${WB_DUMP:-}" "$HDIR/harness" "$QML" "$FX/$fx.json" "$OUT/$name.png" > /dev/null 2> "$OUT/$name.log"
    local rc=$?
    local warn; warn=$(grep -cE '^\[(W|E)\]' "$OUT/$name.log")
    if [ $rc -ne 0 ] || [ "$warn" -ne 0 ]; then
        echo "FAIL: $name (rc=$rc warnings=$warn)"; grep -E '^\[(W|E)\]' "$OUT/$name.log" | head -5; FAIL=1
    else echo "ok:   $name"; fi
    LAST="$OUT/$name.log"
}
expect() { if grep -qE "$1" "$LAST"; then echo "      + $2"; else echo "FAIL:   $2 (no match: $1)"; grep '^CALL' "$LAST" | head -5; FAIL=1; fi; }
deny()   { if grep -qE "$1" "$LAST"; then echo "FAIL:   $2"; grep '^CALL' "$LAST" | head -5; FAIL=1; else echo "      + $2"; fi; }

LUNCH_A=$(fid creator "Lunch poll"); MEMBERS_A=$(fid creator "Members only")
LUNCH_C=$(fid outsider "Lunch poll"); MEMBERS_C=$(fid outsider "Members only")
LEGACY_B=$(fid respondent "Legacy"); LUNCH_B=$(fid respondent "Lunch poll")

run creator-detail   creator   "{\"selectedId\":\"$LUNCH_A\"}"
run creator-unconfirmed creator "{\"selectedId\":\"$MEMBERS_A\"}"
run creator-confirm  creator   "{\"selectedId\":\"$MEMBERS_A\"}" "closeSelected"
expect "CALL whisperbox_core closeForm argc=1 args=$MEMBERS_A\$" "close -> closeForm(formId)"
run creator-share    creator   "{\"selectedId\":\"$LUNCH_A\"}" "openShare"
expect "CALL whisperbox_core shareUri argc=1 args=$LUNCH_A\$" "share -> shareUri(formId)"
expect "CALL whisperbox_core shareQr argc=1 args=$LUNCH_A\$" "share -> shareQr(formId)"
run creator-csv      creator   "{\"selectedId\":\"$LUNCH_A\"}" "openCsv"
expect "CALL whisperbox_core exportCsv argc=1 args=$LUNCH_A\$" "csv -> exportCsv(formId)"
run create-dialog    creator   "{}" "openCreate,addDraftQuestion"
run create-publish   creator   '{"draftTitle":"Team offsite","draftDescription":"Where next?","draftRestrict":true,"draftAllowList":"0x1111111111111111111111111111111111111111\n0xBAD","draftQuestions":[{"type":"radioButtons","text":"Place","required":true,"optionsText":"Alps\nSea\n"},{"type":"textarea","text":"Why?","required":false,"optionsText":""}]}' "doCreate"
expect 'CALL whisperbox_core createForm argc=1 args=\{"title":"Team offsite","description":"Where next\?","questions":\[\{"id":"q1","type":"radioButtons","text":"Place","required":true,"options":\["Alps","Sea"\]\},\{"id":"q2","type":"textarea","text":"Why\?","required":false\}\],"whitelist":\{"type":"addresses","value":"0x1111111111111111111111111111111111111111"\}\}$' "publish -> createForm(def) with options + filtered allow-list"
run create-bad-choice creator  '{"draftTitle":"x","draftQuestions":[{"type":"checkbox","text":"Pick","required":true,"optionsText":"only one"}]}' "doCreate"
deny "CALL whisperbox_core createForm" "choice question with <2 options is not published"
# Real clicks on the builder's type/required chips (dialog at 1280x800: Q1 chips row
# y=381; "Single choice" x=548, "Required" x=798 since "Yes / No" was added). Regression: chip handlers used the
# CHIP repeater's index, so a click appended a phantom question instead.
WB_DUMP=draftQuestions WB_CLICKS="548,381;798,381" run create-chips creator "{}" "openCreate"
expect 'DUMP draftQuestions \[\{"optionsText":"","required":false,"text":"","type":"radioButtons"\}\]' "chip clicks edit Q1 in place (single choice, now optional) - no phantom question"
run respondent-done  respondent "{\"selectedId\":\"$LUNCH_B\"}"
run respondent-form  respondent "{\"selectedId\":\"$LEGACY_B\"}"
run submit-missing   outsider  "{\"selectedId\":\"$LUNCH_C\"}" "doSubmit"
deny "CALL whisperbox_core submitResponse" "required questions block submit"
run submit-ok        outsider  "{\"selectedId\":\"$LUNCH_C\",\"answers\":{\"q1\":2,\"q2\":[0,1],\"q3\":\"hi\"}}" "doSubmit"
expect "CALL whisperbox_core submitResponse argc=2 args=$LUNCH_C \| \[\{\"questionId\":\"q1\",\"value\":2\},\{\"questionId\":\"q2\",\"value\":\[0,1\]\},\{\"questionId\":\"q3\",\"value\":\"hi\"\}\]\$" "submit -> submitResponse(formId, [{questionId,value}]) with option indices"
run outsider-members outsider  "{\"selectedId\":\"$MEMBERS_C\"}"
deny "CALL whisperbox_core submitResponse" "no submit offered when not on the list"
run pending          pending   "{\"selectedId\":\"$(pend)\"}" "resync"
expect "CALL whisperbox_core resync argc=0" "pending -> resync()"
run contested        contested "{\"selectedId\":\"$(fid contested "Salary survey")\"}"
deny "CALL whisperbox_core submitResponse" "contested form offers no submit"
run identity         creator   '{"showIdentity":true}'
run join-id          empty     "{}" ""

# ── 0.3.2: responses viewer, receipts, re-open, drafts, duplicate, yes/no ──
CAPPED=$(fid lifecycle "Capped"); LONG_G=$(fid answer-draft "Long form")
run creator-summary  lifecycle "{\"selectedId\":\"$CAPPED\",\"respMode\":\"summary\"}"
run creator-table    lifecycle "{\"selectedId\":\"$CAPPED\",\"respMode\":\"table\"}"
run creator-one      lifecycle "{\"selectedId\":\"$CAPPED\",\"respMode\":\"one\",\"respIndex\":1}"
run confirm-all      lifecycle "{\"selectedId\":\"$CAPPED\"}" "confirmAllSelected"
expect "CALL whisperbox_core confirmAll argc=1 args=$CAPPED\$" "Send all receipts -> confirmAll(formId)"
run auto-receipts    lifecycle "{\"selectedId\":\"$CAPPED\"}" "toggleAutoReceipts"
expect "CALL whisperbox_core setAutoReceipts argc=2 args=$CAPPED \| 1\$" "Automatic receipts toggle -> setAutoReceipts(formId, 1)"
run reopen           lifecycle "{\"selectedId\":\"$CAPPED\"}" "reopenSelected"
expect "CALL whisperbox_core reopenForm argc=1 args=$CAPPED\$" "Re-open -> reopenForm(formId)"
WB_DUMP=builderState run duplicate lifecycle "{\"selectedId\":\"$CAPPED\"}" "duplicateSelected"
expect 'DUMP builderState .*"max":"2".*"title":"Capped \(copy\)"' "Duplicate opens the builder prefilled (questions, cap, title)"
run drafts-sidebar   drafts    "{}"
WB_DUMP=draftId run save-draft creator '{"showCreate":true,"draftTitle":"Half done","draftQuestions":[{"type":"text","text":"Q","required":false,"optionsText":""}]}' "saveCurrentDraftNow"
expect 'CALL whisperbox_core saveDraft argc=1' "Save draft -> saveDraft(draft)"
expect 'DUMP draftId \["draft-harness1"\]' "the returned draft id is kept (autosave updates the same draft)"
run builder-schedule creator   '{"draftTitle":"Later","draftQuestions":[{"type":"boolean","text":"In?","required":true,"optionsText":""}],"draftPublishAt":"2099-01-01 10:00"}' "doSchedule"
expect 'CALL whisperbox_core saveDraft argc=1 args=\{"def":\{"title":"Later".*"type":"boolean".*\},"publishAt":[0-9]{13}\}$' "Schedule -> saveDraft with publishAt"
deny "CALL whisperbox_core createForm" "scheduling does not publish now"
run builder-max      creator   '{"draftTitle":"Cap","draftMax":"25","draftShowCount":true,"draftQuestions":[{"type":"text","text":"Q","required":false,"optionsText":""}]}' "doCreate"
expect 'CALL whisperbox_core createForm argc=1 args=.*"maxResponses":25,"showResponseCount":true\}$' "Publish carries the answer cap + show-count"
deny '_builder' "builder state never goes on the wire"
WB_DUMP=answers run answer-restore answer-draft "{\"selectedId\":\"$LONG_G\"}" "restoreAnswerDraft"
expect 'DUMP answers \{"q1":true\}' "unsent answers are restored into the form"
echo
[ $FAIL -eq 0 ] && echo "SCENARIOS GREEN" || echo "SCENARIOS FAILED"
exit $FAIL
