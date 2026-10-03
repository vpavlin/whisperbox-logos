// WhisperBox for Android — same flows and look as the Basecamp view (module/Main.qml),
// over the same protocol client the desktop is interop-tested against.
import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  View, Text, TextInput, Pressable, ScrollView, StyleSheet, BackHandler, Linking, Share,
  ActivityIndicator, Animated, RefreshControl, Switch, KeyboardAvoidingView, Platform,
} from "react-native";
import { SafeAreaProvider, SafeAreaView } from "react-native-safe-area-context";
import { StatusBar } from "expo-status-bar";
import * as Clipboard from "expo-clipboard";
import QRCode from "react-native-qrcode-svg";
import { CameraView, useCameraPermissions } from "expo-camera";
import { SharedNodeStatus } from "./src/lib/loam-transport-pkg/src/SharedNodeStatus";
import { boot, client, net, pullHistory, setSharedNode, parseLink } from "./src/lib/whisperbox";
import { startAnswerNotifications, ensurePermission, notificationsEnabled, setNotificationsEnabled } from "./src/lib/notify";
import { crumb, previousCrash, previousLog, currentLog, fatalError, onFatal, reportFatal, clearFatal } from "./src/lib/crashlog";
import { registerSheet, requestCardKeys, getKeycardPrefs, setKeycardPrefs, type CardRequest } from "./src/lib/keycard/flow";
// @ts-ignore - plain ESM shared with the desktop core's tests (same rules, same fixture)
import { validateAnswer, emptyAnswer as emptyVal } from "../packages/contract/src/answers.mjs";

// ── palette: the desktop view's indigo/charcoal ──
const C = {
  primary: "#7c6ff7", primaryHover: "#9187f9", primarySubtle: "#1e1b3a", accent: "#f7a44c",
  bg: "#0b0b10", surface: "#14141e", raised: "#1c1c2a", border: "#2a2a3e", borderSubtle: "#1e1e30",
  text: "#f0f0f8", text2: "#a0a0b8", text3: "#6b6b82",
  ok: "#4ade80", okSubtle: "#16301f", warn: "#fbbf24", warnSubtle: "#2e2714", err: "#f87171", errSubtle: "#341a1d",
};
const MONO: string = Platform.OS === "android" ? "monospace" : "Courier";

type Screen =
  | { k: "home" } | { k: "form"; id: string } | { k: "create"; draftId?: string; fromForm?: string; editFormId?: string } | { k: "share"; id: string }
  | { k: "scan" } | { k: "identity" } | { k: "csv"; id: string; csv: string } | { k: "preview"; def: any };

const QTYPES = [
  { t: "text", label: "Short text" }, { t: "textarea", label: "Paragraph" },
  { t: "radioButtons", label: "Single choice" }, { t: "checkbox", label: "Multiple choice" },
  { t: "boolean", label: "Yes / No" }, { t: "dropdown", label: "Dropdown" }, { t: "scale", label: "Scale" },
  { t: "number", label: "Number" }, { t: "date", label: "Date" }, { t: "time", label: "Time" },
  { t: "email", label: "Email" }, { t: "url", label: "Link" },
];
const KNOWN = ["text", "textarea", "radioButtons", "checkbox", "boolean", "dropdown", "scale", "number", "date", "time", "email", "url", "section"];
const normType = (t: any) => (KNOWN.includes(String(t)) ? String(t) : "text");
const isChoice = (t: string) => t === "radioButtons" || t === "checkbox" || t === "dropdown";
const isOtherVal = (v: any) => v !== null && typeof v === "object" && !Array.isArray(v) && "other" in v;
const answerOf = (r: any, qid: string) => (r?.answers || []).find((a: any) => a.questionId === qid)?.value;
// Deterministic per-respondent shuffle - the SAME arithmetic as the desktop view, so a
// respondent sees the same order on both apps.
function seededOrder(n: number, seed: string) {
  let h = 2166136261; for (let i = 0; i < seed.length; i++) { h ^= seed.charCodeAt(i); h = (h * 16777619) >>> 0; }
  const idx = Array.from({ length: n }, (_, k) => k);
  for (let j = n - 1; j > 0; j--) { h = (h * 1103515245 + 12345) >>> 0; const r = h % (j + 1); [idx[j], idx[r]] = [idx[r], idx[j]]; }
  return idx;
}
// Per-question aggregate (same as the desktop Summary).
function summarize(q: any, rs: any[]) {
  const t = normType(q.type);
  const bar = (labels: string[], count: (v: any, c: number[]) => boolean) => {
    const counts = labels.map(() => 0); let answered = 0;
    for (const r of rs) if (count(answerOf(r, q.id), counts)) answered++;
    const max = Math.max(1, ...counts);
    return { bars: labels.map((l, i) => ({ label: String(l), n: counts[i], pct: answered ? Math.round((100 * counts[i]) / answered) : 0, w: counts[i] / max })), answered, samples: [] as string[], stat: "" };
  };
  if (isChoice(t) || t === "boolean") {
    const labels: string[] = t === "boolean" ? ["Yes", "No"] : [...(q.options || [])];
    const other = !!q.allowOther && t !== "boolean"; if (other) labels.push("Other");
    const res = bar(labels, (v, c) => {
      if (t === "boolean") { if (v === true) { c[0]++; return true; } if (v === false) { c[1]++; return true; } return false; }
      let hit = false;
      for (const x of Array.isArray(v) ? v : [v]) {
        if (typeof x === "number" && x >= 0 && x < (q.options || []).length) { c[x]++; hit = true; }
        else if (other && isOtherVal(x)) { c[c.length - 1]++; hit = true; }
      }
      return hit;
    });
    if (other) res.samples = rs.slice().reverse().flatMap((r) => { const v = answerOf(r, q.id); return (Array.isArray(v) ? v : [v]).filter((x) => isOtherVal(x) && String(x.other).trim()).map((x: any) => "Other: " + x.other); }).slice(0, 5);
    return res;
  }
  if (t === "scale") {
    const lo = typeof q.min === "number" ? q.min : 1, hi = typeof q.max === "number" ? q.max : 5;
    let sum = 0, cnt = 0;
    const res = bar(Array.from({ length: hi - lo + 1 }, (_, i) => String(lo + i)), (v, c) => { if (typeof v === "number" && v >= lo && v <= hi) { c[v - lo]++; sum += v; cnt++; return true; } return false; });
    res.stat = cnt ? `average ${Math.round((10 * sum) / cnt) / 10}${q.style === "stars" ? " ★" : ""}  (${q.minLabel || lo} → ${q.maxLabel || hi})` : "";
    return res;
  }
  const samples = rs.map((r) => answerText(q, answerOf(r, q.id))).filter(Boolean).reverse();
  const nums = rs.map((r) => answerOf(r, q.id)).filter((v) => typeof v === "number") as number[];
  const stat = t === "number" && nums.length ? `min ${Math.min(...nums)}  ·  average ${Math.round((100 * nums.reduce((a, b) => a + b, 0)) / nums.length) / 100}  ·  max ${Math.max(...nums)}` : "";
  return { bars: [] as any[], answered: samples.length, samples: samples.slice(0, 5), stat };
}
const shortAddr = (a?: string) => (!a ? "-" : a.length > 14 ? a.slice(0, 6) + "…" + a.slice(-4) : a);
const fmtTime = (ms?: number) => {
  if (!ms) return "";
  const d = new Date(ms);
  return d.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" }) + ", " + d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
};
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;
const answerText = (q: any, v: any): string => {
  if (v === null || v === undefined || v === "") return "";
  const opts: string[] = q?.options || [];
  const one = (x: any) => (typeof x === "boolean" ? (x ? "Yes" : "No") : isOtherVal(x) ? "Other: " + x.other : typeof x === "number" && opts[x] !== undefined ? String(opts[x]) : String(x));
  return Array.isArray(v) ? v.map(one).join(", ") : one(v);
};

export default function App() {
  const [fatal, setFatal] = useState<string | null>(fatalError());
  const [gen, setGen] = useState(0);
  useEffect(() => onFatal(() => setFatal(fatalError())), []);
  return (
    <SafeAreaProvider>
      <StatusBar style="light" />
      {fatal ? <FatalScreen msg={fatal} onRetry={() => { clearFatal(); setGen((g) => g + 1); }} /> : (
        <Boundary key={gen}><Root /></Boundary>
      )}
    </SafeAreaProvider>
  );
}

// Render errors -> the same on-screen report (a release build would otherwise just die).
class Boundary extends React.Component<{ children: React.ReactNode }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  componentDidCatch(e: any) { reportFatal(e, "render"); }
  render() { return this.state.failed ? null : this.props.children; }
}

function FatalScreen({ msg, onRetry }: { msg: string; onRetry: () => void }) {
  const [copied, setCopied] = useState(false);
  return (
    <SafeAreaView style={[st.fill, st.pad]}>
      <LockMark size={28} tint={C.err} />
      <Text style={[st.h1, { marginTop: 14 }]}>WhisperBox hit an error</Text>
      <Text style={[st.muted, { marginTop: 6 }]}>Your forms and answers are safe on this phone. Please copy the details and send them to the developer.</Text>
      <ScrollView style={[st.card, { flex: 1, marginTop: 14 }]}>
        <Text style={st.csv} selectable>{msg + "\n\n" + currentLog()}</Text>
      </ScrollView>
      <View style={[st.joinRow, { marginTop: 12 }]}>
        <Btn label={copied ? "Copied" : "Copy details"} primary onPress={async () => { await Clipboard.setStringAsync(msg + "\n\n--- log ---\n" + currentLog()); setCopied(true); }} style={{ flex: 1 }} />
        <Btn label="Try again" onPress={onRetry} style={{ flex: 1 }} />
      </View>
    </SafeAreaView>
  );
}

function useSnapshot() {
  const [tick, setTick] = useState(0);
  useEffect(() => { const off = client.subscribe(() => setTick((t: number) => t + 1)); return () => { off(); }; }, []);
  return useMemo(() => (client.identity ? client.snapshot() : null), [tick]);
}

function Root() {
  const [ready, setReady] = useState(false);
  const [stack, setStack] = useState<Screen[]>([{ k: "home" }]);
  const [toastMsg, setToastMsg] = useState("");
  const toastTimer = useRef<any>(null);
  const snap = useSnapshot();
  const screen = stack[stack.length - 1];

  const toast = useCallback((m: string) => {
    setToastMsg(m);
    if (toastTimer.current) clearTimeout(toastTimer.current);
    toastTimer.current = setTimeout(() => setToastMsg(""), 3200);
  }, []);
  const push = useCallback((s: Screen) => setStack((st) => [...st, s]), []);
  const pop = useCallback(() => setStack((st) => (st.length > 1 ? st.slice(0, -1) : st)), []);
  const replace = useCallback((s: Screen) => setStack((st) => [...st.slice(0, -1), s]), []);

  const openLink = useCallback((input: string) => {
    const l = parseLink(input);
    if (!l) { toast("That's not a WhisperBox link or form id"); return false; }
    const r = client.importForm(input);
    if (!r.ok) { toast(r.error); return false; }
    setStack([{ k: "home" }, { k: "form", id: r.formId }]);
    if (r.pending) toast("Form added - waiting for it to sync");
    return true;
  }, [toast]);

  useEffect(() => {
    boot().then(() => {
      setReady(true);
      startAnswerNotifications((formId) => setStack([{ k: "home" }, { k: "form", id: formId }])).catch(() => {});
    });
    Linking.getInitialURL().then((u) => { if (u && u.startsWith("whisperbox://")) boot().then(() => openLink(u)); });
    const sub = Linking.addEventListener("url", ({ url }) => { if (url.startsWith("whisperbox://")) boot().then(() => openLink(url)); });
    return () => sub.remove();
  }, [openLink]);

  useEffect(() => {
    const h = BackHandler.addEventListener("hardwareBackPress", () => {
      if (stack.length > 1) { pop(); return true; }
      return false;
    });
    return () => h.remove();
  }, [stack, pop]);

  if (!ready || !snap) {
    return (
      <SafeAreaView style={[st.fill, st.center]}>
        <LockMark size={40} />
        <Text style={[st.h2, { marginTop: 16 }]}>WhisperBox</Text>
        <ActivityIndicator color={C.primary} style={{ marginTop: 18 }} />
      </SafeAreaView>
    );
  }

  const ctx = { snap, push, pop, replace, toast, openLink };
  return (
    <SafeAreaView style={st.fill} edges={["top", "bottom"]}>
      {screen.k === "home" && <Home {...ctx} />}
      {screen.k === "form" && <FormScreen key={screen.id} {...ctx} id={screen.id} />}
      {screen.k === "preview" && <FormScreen key="preview" {...ctx} id="preview" preview={screen.def} />}
      {screen.k === "create" && <CreateScreen {...ctx} draftId={screen.draftId} fromForm={screen.fromForm} editFormId={screen.editFormId} />}
      {screen.k === "share" && <ShareScreen {...ctx} id={screen.id} />}
      {screen.k === "scan" && <ScanScreen {...ctx} />}
      {screen.k === "identity" && <IdentityScreen {...ctx} />}
      {screen.k === "csv" && <CsvScreen {...ctx} csv={screen.csv} />}
      <KeycardSheet />
      {!!toastMsg && <Toast msg={toastMsg} />}
    </SafeAreaView>
  );
}
type Ctx = { snap: any; push: (s: Screen) => void; pop: () => void; replace: (s: Screen) => void; toast: (m: string) => void; openLink: (s: string) => boolean };

// ── shared bits ──────────────────────────────────────────────────────────────────
function LockMark({ size = 22, tint = C.primary }: { size?: number; tint?: string }) {
  const w = size, h = size * 1.18;
  return (
    <View style={{ width: w, height: h }}>
      <View style={{ position: "absolute", left: w * 0.18, top: 0, width: w * 0.64, height: h * 0.62, borderRadius: w, borderWidth: Math.max(2, w * 0.13), borderColor: tint }} />
      <View style={{ position: "absolute", left: 0, bottom: 0, width: w, height: h * 0.62, borderRadius: w * 0.18, backgroundColor: tint, alignItems: "center", justifyContent: "center" }}>
        <View style={{ width: Math.max(2, w * 0.12), height: h * 0.24, borderRadius: w, backgroundColor: C.bg }} />
      </View>
    </View>
  );
}
function Btn({ label, onPress, primary, danger, disabled, style }: { label: string; onPress: () => void; primary?: boolean; danger?: boolean; disabled?: boolean; style?: any }) {
  return (
    <Pressable onPress={disabled ? undefined : onPress} accessibilityRole="button" accessibilityState={{ disabled: !!disabled }}
      style={({ pressed }) => [st.btn, primary && st.btnPrimary, danger && st.btnDanger, pressed && !disabled && { opacity: 0.75 }, disabled && { opacity: 0.4 }, style]}>
      <Text style={[st.btnT, primary && { color: "#fff" }, danger && { color: C.err }]}>{label}</Text>
    </Pressable>
  );
}
function Badge({ label, fg = C.ok, bg = C.okSubtle }: { label: string; fg?: string; bg?: string }) {
  return <View style={[st.badge, { backgroundColor: bg }]}><Text style={[st.badgeT, { color: fg }]}>{label}</Text></View>;
}
function Label({ children }: { children: React.ReactNode }) { return <Text style={st.label}>{children}</Text>; }
function Header({ title, onBack, right }: { title?: string; onBack?: () => void; right?: React.ReactNode }) {
  return (
    <View style={st.header}>
      {onBack ? <Pressable onPress={onBack} hitSlop={12} accessibilityLabel="Back"><Text style={st.back}>‹</Text></Pressable> : null}
      <Text style={st.headerT} numberOfLines={1}>{title}</Text>
      <View style={{ flex: 1 }} />
      {right}
    </View>
  );
}
function Toast({ msg }: { msg: string }) {
  const a = useRef(new Animated.Value(0)).current;
  useEffect(() => { Animated.timing(a, { toValue: 1, duration: 180, useNativeDriver: true }).start(); }, [a]);
  return <Animated.View pointerEvents="none" style={[st.toast, { opacity: a }]}><Text style={st.toastT}>{msg}</Text></Animated.View>;
}
function Banner({ text, tone = "info" }: { text: string; tone?: "ok" | "info" | "warn" | "err" }) {
  const map = { ok: [C.okSubtle, C.ok], info: [C.raised, C.text2], warn: [C.warnSubtle, C.warn], err: [C.errSubtle, C.err] } as const;
  const [bg, fg] = map[tone];
  return <View style={[st.banner, { backgroundColor: bg, borderColor: tone === "info" ? C.border : fg + "55" }]}><Text style={{ color: fg, fontSize: 14, lineHeight: 20 }}>{text}</Text></View>;
}

// ── Home ─────────────────────────────────────────────────────────────────────────
function Home({ snap, push, openLink }: Ctx) {
  const [link, setLink] = useState("");
  const [refreshing, setRefreshing] = useState(false);
  const [showHidden, setShowHidden] = useState(false);
  const forms = snap.state.forms as Record<string, any>;
  const all = Object.keys(forms).sort((a, b) => (forms[b].createdAt || 0) - (forms[a].createdAt || 0));
  const hidden = all.filter((i) => forms[i].hidden);   // local hide (Hide on the form screen)
  const ids = all.filter((i) => !forms[i].hidden);
  const mine = ids.filter((i) => forms[i].mine);
  const coOwned = ids.filter((i) => forms[i].coOwner);
  const answered = ids.filter((i) => !forms[i].mine && !forms[i].coOwner && forms[i].mySubmitted);
  // No public directory: only forms you own, answered, or opened from a link (anyone can
  // publish a form, so listing everything on the network would be a spam channel).
  const opened = new Set<string>(snap.watched || []);
  const open = ids.filter((i) => !forms[i].mine && !forms[i].coOwner && !forms[i].mySubmitted && opened.has(i));
  const pending: string[] = snap.pendingForms;
  const responsesFor = (id: string) => snap.creatorView?.responses?.[id]?.length || 0;

  const Row = ({ id }: { id: string }) => {
    const f = forms[id];
    const sub = !f ? "syncing…" : [plural(f.questions.length, "question", "questions"), f.mine ? plural(responsesFor(id), "response", "responses") : null, f.status === "closed" ? "closed" : null].filter(Boolean).join("  ·  ");
    return (
      <Pressable onPress={() => push({ k: "form", id })} style={({ pressed }) => [st.row, pressed && { backgroundColor: C.raised }]}>
        <View style={[st.glyph, f?.status === "closed" && { opacity: 0.5 }]}>{[14, 10, 12].map((w, i) => <View key={i} style={{ width: w, height: 2, borderRadius: 1, backgroundColor: C.primary, marginVertical: 1.5 }} />)}</View>
        <View style={{ flex: 1, minWidth: 0 }}>
          <Text style={st.rowT} numberOfLines={1}>{f ? f.title || "(untitled)" : id}</Text>
          <Text style={st.rowS} numberOfLines={1}>{sub}</Text>
        </View>
        {f && f.mine && f.newResponses > 0 ? <Badge label={`${f.newResponses} new`} fg="#fff" bg={C.primary} /> : null}
        {f && !f.mine && f.mySubmitted ? <Badge label={f.myConfirmed ? "Receipt" : "Sent"} fg={f.myConfirmed ? C.ok : C.text2} bg={f.myConfirmed ? C.okSubtle : C.raised} /> : null}
        {f?.contested ? <Badge label="Check link" fg={C.warn} bg={C.warnSubtle} /> : null}
      </Pressable>
    );
  };
  const newMine = mine.reduce((n, id) => n + (forms[id].newResponses || 0), 0);
  const Section = ({ title, list, pend }: { title: string; list: string[]; pend?: boolean }) =>
    list.length ? (<View style={{ marginTop: 18 }}><Label>{title}  {list.length}{title === "MY FORMS" && newMine ? `   ·  ${newMine} new` : ""}</Label>{list.map((id) => pend ? <Row key={id} id={id} /> : <Row key={id} id={id} />)}</View>) : null;

  const onRefresh = async () => { setRefreshing(true); try { await pullHistory(); } finally { setRefreshing(false); } };
  const empty = !mine.length && !answered.length && !open.length && !pending.length && !(snap.drafts || []).length;

  return (
    <View style={st.fill}>
      <View style={st.topbar}>
        <LockMark />
        <View style={{ marginLeft: 10 }}>
          <Text style={st.brand}>WhisperBox</Text>
          <Text style={st.brandSub}>end-to-end encrypted forms</Text>
        </View>
        <View style={{ flex: 1 }} />
        <Pressable onPress={() => push({ k: "identity" })} style={st.idPill} accessibilityLabel="Identity and network">
          <View style={[st.dot, { backgroundColor: net.started ? C.ok : C.warn }]} />
          <Text style={st.idPillT}>{shortAddr(snap.identity.address)}</Text>
        </Pressable>
      </View>
      <SharedNodeStatus appName="WhisperBox" />
      <CrashBanner />
      <ScrollView contentContainerStyle={st.pad} keyboardShouldPersistTaps="handled"
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={C.primary} colors={[C.primary]} progressBackgroundColor={C.surface} />}>
        <Label>OPEN A SHARED FORM</Label>
        <View style={st.joinRow}>
          <TextInput value={link} onChangeText={setLink} placeholder="whisperbox:// link or form id" placeholderTextColor={C.text3}
            style={[st.input, { flex: 1 }]} autoCapitalize="none" autoCorrect={false} onSubmitEditing={() => { if (openLink(link)) setLink(""); }} />
          <Btn label="Open" disabled={!link.trim()} onPress={() => { if (openLink(link)) setLink(""); }} />
        </View>
        <View style={[st.joinRow, { marginTop: 8 }]}>
          <Btn label="Scan QR" onPress={() => push({ k: "scan" })} style={{ flex: 1 }} />
          <Btn label="Paste link" onPress={async () => { const t = await Clipboard.getStringAsync(); if (t) openLink(t); }} style={{ flex: 1 }} />
        </View>

        {empty ? (
          <View style={st.empty}>
            <Text style={st.emptyT}>Psst… nothing to whisper about yet.</Text>
            <Text style={st.emptyS}>{net.started ? "Create a form, or open a link someone shared with you. Answers are sealed so only the person who asked can read them." : "Connecting to the network…"}</Text>
          </View>
        ) : null}
        {(snap.drafts || []).length ? (
          <View style={{ marginTop: 18 }}>
            <Label>DRAFTS  {snap.drafts.length}</Label>
            {snap.drafts.map((d: any) => (
              <Pressable key={d.id} onPress={() => push({ k: "create", draftId: d.id })} style={({ pressed }) => [st.row, pressed && { backgroundColor: C.raised }]}>
                <View style={[st.glyph, { opacity: 0.6 }]}>{[14, 10, 12].map((w, i) => <View key={i} style={{ width: w, height: 2, borderRadius: 1, backgroundColor: C.text2, marginVertical: 1.5 }} />)}</View>
                <View style={{ flex: 1, minWidth: 0 }}>
                  <Text style={st.rowT} numberOfLines={1}>{d.def?.title || "Untitled draft"}</Text>
                  <Text style={st.rowS} numberOfLines={1}>{d.publishAt ? "scheduled  ·  " + fmtTime(d.publishAt) : "draft  ·  edited " + fmtTime(d.updatedAt)}</Text>
                </View>
              </Pressable>
            ))}
          </View>
        ) : null}
        <Section title="WAITING FOR SYNC" list={pending} pend />
        <Section title="MY FORMS" list={mine} />
        <Section title="CO-OWNED" list={coOwned} />
        <Section title="ANSWERED" list={answered} />
        <Section title="OPENED FROM LINKS" list={open} />
        {hidden.length ? (
          <View style={{ marginTop: 18 }}>
            <Pressable onPress={() => setShowHidden((x) => !x)} accessibilityRole="button">
              <Label>HIDDEN  {hidden.length}   ·  {showHidden ? "hide" : "show"}</Label>
            </Pressable>
            {showHidden ? hidden.map((id) => <Row key={id} id={id} />) : null}
          </View>
        ) : null}
        <View style={{ height: 96 }} />
      </ScrollView>
      <Pressable onPress={() => push({ k: "create" })} style={({ pressed }) => [st.fab, pressed && { backgroundColor: C.primaryHover }]} accessibilityLabel="New form">
        <Text style={st.fabT}>+  New form</Text>
      </Pressable>
    </View>
  );
}

function CrashBanner() {
  const [crash] = useState(previousCrash);
  const [hidden, setHidden] = useState(false);
  const [copied, setCopied] = useState(false);
  if (!crash || hidden) return null;
  return (
    <View style={[st.banner, { backgroundColor: C.errSubtle, borderColor: C.err + "55", marginHorizontal: 18, marginBottom: 6 }]}>
      <Text style={{ color: C.err, fontSize: 14, lineHeight: 20 }}>WhisperBox closed unexpectedly last time ({crash.secs}s after starting). The debug log shows how far it got.</Text>
      <View style={[st.joinRow, { marginTop: 10 }]}>
        <Btn label={copied ? "Copied" : "Copy debug log"} onPress={async () => { await Clipboard.setStringAsync("WhisperBox previous session\n" + crash.log); setCopied(true); }} style={{ flex: 1 }} />
        <Btn label="Dismiss" onPress={() => setHidden(true)} style={{ flex: 1 }} />
      </View>
    </View>
  );
}

// ── Keycard: PIN + "hold your card" sheet (one tap per request) ──────────────────
// Rendered conditionally (not an RN <Modal>, whose body renders even when hidden). The PIN
// stays in this component's state only for the request; it is never stored.
function KeycardSheet() {
  const [req, setReq] = useState<CardRequest | null>(null);
  const [pin, setPin] = useState("");
  const [phase, setPhase] = useState<"pin" | "tap">("pin");
  const [err, setErr] = useState("");
  const [nfc, setNfc] = useState<"ok" | "off" | "unsupported" | "">("");
  useEffect(() => { registerSheet((r) => { setReq(r); setPin(""); setErr(""); setPhase("pin"); }); return () => registerSheet(null); }, []);
  useEffect(() => {
    if (!req) return;
    import("./src/lib/keycard/nfc").then((m) => m.nfcStatus()).then(setNfc).catch(() => setNfc("unsupported"));
  }, [req]);
  if (!req) return null;
  const close = (e?: Error) => { const r = req; setReq(null); setPin(""); if (e) r.reject(e); };
  const go = async () => {
    if (pin.length < 4) { setErr("Enter your Keycard PIN"); return; }
    setErr(""); setPhase("tap");
    try {
      const nfcMod = await import("./src/lib/keycard/nfc");
      const { pairing } = await getKeycardPrefs();
      const res = await nfcMod.tapExportFormKeys({ pin, pairingPassword: pairing }, req.formIds);
      crumb("keycard export ok n=" + res.keys.length + " app=" + res.appVersion);
      const r = req; setReq(null); setPin(""); r.resolve(res.keys);
    } catch (e: any) {
      crumb("keycard error " + (e?.code || "") + " " + (e?.message || e));
      if (e?.code === "cancelled") { close(e); return; }
      setPhase("pin"); setErr(String(e?.message || e));
      if (e?.code === "pin") setPin("");
    }
  };
  const cancel = async () => { try { (await import("./src/lib/keycard/nfc")).cancelTap(); } catch { /* */ } close(Object.assign(new Error("Cancelled"), { code: "cancelled" })); };
  return (
    <View style={st.sheetWrap}>
      <View style={st.sheet}>
        <Text style={st.h2}>{req.title}</Text>
        {nfc === "unsupported" ? <Banner tone="err" text="This phone has no NFC, so it can't talk to a Keycard." /> : null}
        {nfc === "off" ? <><Banner tone="warn" text="NFC is turned off." /><Btn label="Open NFC settings" onPress={() => import("./src/lib/keycard/nfc").then((m) => m.openNfcSettings())} style={{ marginTop: 8 }} /></> : null}
        {phase === "pin" ? (
          <>
            <Text style={[st.muted, { marginTop: 8 }]}>{req.formIds.length === 1 ? "The form's key comes from your card; " : `${req.formIds.length} forms' keys come from your card; `}your PIN is used for this tap only and never stored.</Text>
            <TextInput value={pin} onChangeText={(t) => setPin(t.replace(/\D/g, "").slice(0, 6))} placeholder="Keycard PIN" placeholderTextColor={C.text3}
              secureTextEntry keyboardType="number-pad" autoFocus style={[st.input, { marginTop: 14, letterSpacing: 6, fontSize: 20, textAlign: "center" }]} onSubmitEditing={go} />
          </>
        ) : (
          <View style={{ alignItems: "center", paddingVertical: 22 }}>
            <ActivityIndicator color={C.primary} size="large" />
            <Text style={[st.h2, { marginTop: 16, textAlign: "center" }]}>Hold your Keycard to the back of the phone</Text>
            <Text style={[st.muted, { marginTop: 6, textAlign: "center" }]}>Keep it still until this closes.</Text>
          </View>
        )}
        {err ? <Banner tone="err" text={err} /> : null}
        <View style={[st.joinRow, { marginTop: 16, justifyContent: "flex-end" }]}>
          <Btn label="Cancel" onPress={cancel} />
          {phase === "pin" ? <Btn label="Continue" primary disabled={nfc === "unsupported" || pin.length < 4} onPress={go} /> : null}
        </View>
      </View>
    </View>
  );
}

// One question as the respondent sees it (all types). value/onChange use the wire format.
function QuestionInput({ q, n, value, onChange, error, order }: { q: any; n: number; value: any; onChange: (v: any) => void; error: string; order: number[] | null }) {
  const t = normType(q.type);
  const invalid = !!error;
  const multi = t === "checkbox";
  const opts: string[] = q.options || [];
  const idx = order || opts.map((_, i) => i);
  const list: any[] = Array.isArray(value) ? value : [];
  const otherNow = isOtherVal(value) ? value : list.find(isOtherVal);
  const setOther = (text: string, on: boolean) => {
    if (!multi) { onChange(on ? { other: text } : null); return; }
    const rest = list.filter((x) => !isOtherVal(x));
    onChange(on ? [...rest, { other: text }] : rest);
  };
  if (t === "section") return <Text style={[st.h2, { marginTop: 26, color: C.text }]}>{q.text}</Text>;
  const kb: any = { number: "decimal-pad", email: "email-address", url: "url", date: "numbers-and-punctuation", time: "numbers-and-punctuation" }[t] || "default";
  const ph: string = ({ email: "name@example.com", url: "https://...", number: "A number", date: "YYYY-MM-DD", time: "HH:MM" } as any)[t] || "Your answer";
  return (
    <View style={{ marginTop: 18 }}>
      <Text style={[st.q, invalid && { color: C.err }]}>{n}. {q.text}{q.required ? "  *" : ""}</Text>
      {q.help ? <Text style={[st.muted, { marginTop: -4, marginBottom: 8 }]}>{q.help}</Text> : null}
      {t === "text" || t === "textarea" || t === "email" || t === "url" || t === "number" || t === "date" || t === "time" ? (
        <TextInput multiline={t === "textarea"} keyboardType={kb} autoCapitalize={t === "email" || t === "url" ? "none" : "sentences"}
          value={value === undefined || value === null ? "" : String(value)} placeholder={ph} placeholderTextColor={C.text3}
          onChangeText={(x) => { if (t !== "number") { onChange(x); return; } const s2 = x.trim().replace(",", "."); onChange(s2 === "" ? null : isNaN(Number(s2)) ? x : Number(s2)); }}
          style={[st.input, t === "textarea" && { minHeight: 104, textAlignVertical: "top" }, invalid && { borderColor: C.err }]} />
      ) : null}
      {t === "dropdown" ? (
        <View style={st.chips}>
          {idx.map((oi) => (
            <Pressable key={oi} onPress={() => onChange(value === oi && !q.required ? null : oi)} style={[st.chip, value === oi && st.chipOn, invalid && value !== oi && { borderColor: C.err }]}>
              <Text style={[st.chipT, { fontSize: 14 }, value === oi && { color: C.primary }]}>{opts[oi]}</Text>
            </Pressable>
          ))}
        </View>
      ) : null}
      {t === "radioButtons" || t === "checkbox" || t === "boolean" ? (t === "boolean" ? [0, 1] : idx).map((oi) => {
        const label = t === "boolean" ? (oi === 0 ? "Yes" : "No") : opts[oi];
        const val = t === "boolean" ? oi === 0 : oi;   // yes/no answers are true / false
        const on = multi ? list.includes(oi) : value === val;
        return (
          <Pressable key={oi} accessibilityRole={multi ? "checkbox" : "radio"} accessibilityState={{ checked: on }}
            onPress={() => multi ? onChange(on ? list.filter((x) => x !== oi) : [...list, oi]) : onChange(val)}
            style={[st.opt, on && { borderColor: C.primary, backgroundColor: C.primarySubtle }, invalid && !on && { borderColor: C.err }]}>
            <View style={[st.tick, { borderRadius: multi ? 4 : 9, borderColor: on ? C.primary : C.text3 }]}>{on ? <View style={[st.tickIn, { borderRadius: multi ? 2 : 5 }]} /> : null}</View>
            <Text style={st.optT}>{label}</Text>
          </Pressable>
        );
      }) : null}
      {isChoice(t) && q.allowOther ? (
        <View style={[st.opt, { paddingVertical: 4 }, otherNow && { borderColor: C.primary, backgroundColor: C.primarySubtle }]}>
          <Pressable onPress={() => setOther(otherNow ? String(otherNow.other) : "", !otherNow)} hitSlop={10}>
            <View style={[st.tick, { borderRadius: multi ? 4 : 9, borderColor: otherNow ? C.primary : C.text3 }]}>{otherNow ? <View style={[st.tickIn, { borderRadius: multi ? 2 : 5 }]} /> : null}</View>
          </Pressable>
          <TextInput value={otherNow ? String(otherNow.other) : ""} onChangeText={(x) => setOther(x, x.trim() !== "")} placeholder="Other…" placeholderTextColor={C.text3}
            style={[st.optT, { paddingVertical: 8 }]} />
        </View>
      ) : null}
      {t === "scale" ? (() => {
        const lo = typeof q.min === "number" ? q.min : 1, hi = typeof q.max === "number" ? q.max : 5, stars = q.style === "stars";
        return (
          <View>
            <View style={[st.chips, { gap: stars ? 2 : 6 }]}>
              {Array.from({ length: hi - lo + 1 }, (_, i) => lo + i).map((v) => {
                const on = stars ? typeof value === "number" && v <= value : value === v;
                return stars ? (
                  <Pressable key={v} onPress={() => onChange(v)} hitSlop={4} accessibilityLabel={`${v} stars`}><Text style={{ fontSize: 34, color: on ? C.accent : C.border }}>★</Text></Pressable>
                ) : (
                  <Pressable key={v} onPress={() => onChange(v)} style={[st.scaleBtn, on && { backgroundColor: C.primary, borderColor: C.primary }, invalid && !on && { borderColor: C.err }]}>
                    <Text style={{ color: on ? "#fff" : C.text, fontWeight: "700" }}>{v}</Text>
                  </Pressable>
                );
              })}
            </View>
            {q.minLabel || q.maxLabel ? <View style={{ flexDirection: "row", justifyContent: "space-between", marginTop: 4 }}><Text style={st.time}>{q.minLabel || ""}</Text><Text style={st.time}>{q.maxLabel || ""}</Text></View> : null}
          </View>
        );
      })() : null}
      {invalid ? <Text style={{ color: C.err, fontSize: 12, marginTop: 6 }}>{error}</Text> : null}
    </View>
  );
}

// ── Form (creator + respondent) ─────────────────────────────────────────────────
function FormScreen({ snap, pop, push, toast, id, preview }: Ctx & { id: string; preview?: any }) {
  // preview: the builder's form exactly as respondents see it; nothing is ever sent
  const f = preview ? { id: "preview", creator: snap.identity.address, status: "open", canRespond: true, allowed: true, confirmations: [], ...preview } : snap.state.forms[id];
  const pending = !f;
  // unsent answers saved while typing come back (crash, restart, leaving the screen)
  // Read the draft from the client itself: the snapshot this screen got may predate the last
  // save (saving a draft doesn't re-render the app), which made re-opened forms come back empty.
  const savedDraft = (): any[] | null => (f && !f.mySubmitted ? client.answerDrafts?.[String(id).toLowerCase()] || null : null);
  const [answers, setAnswers] = useState<Record<string, any>>(() => {
    const a: Record<string, any> = {};
    for (const x of savedDraft() || []) a[x.questionId] = x.value;
    return a;
  });
  const [restored] = useState(() => !!savedDraft());
  const [showErrors, setShowErrors] = useState(false);
  const [confirmClose, setConfirmClose] = useState(false);
  const [mode, setMode] = useState<"summary" | "question" | "table" | "one">("summary");
  const [editing, setEditing] = useState(false);   // changing an already-sent answer (within the window)
  const [tick, setTick] = useState(Date.now());
  useEffect(() => { const t = setInterval(() => setTick(Date.now()), 20000); return () => clearInterval(t); }, []);
  const [qIdx, setQIdx] = useState(0);
  const [showCo, setShowCo] = useState(false);
  const [coCode, setCoCode] = useState("");
  const [idx, setIdx] = useState(0);
  const [filter, setFilter] = useState("");
  const [jump, setJump] = useState("");
  const typed = useRef(false);
  const latest = useRef(answers); latest.current = answers;
  const saveNow = () => {
    if (preview || !typed.current || !f || f.mine || f.mySubmitted) return;
    client.saveAnswerDraft(id, Object.entries(latest.current).map(([questionId, value]) => ({ questionId, value })));
  };
  useEffect(() => {
    const t = setTimeout(saveNow, 600);
    return () => clearTimeout(t);
  }, [answers]);
  // leaving the screen (back, switching forms) saves at once instead of dropping the pending save
  useEffect(() => () => saveNow(), []);
  // looking at your own form = its answers are seen (clears the "N new" badge)
  const newHere = !preview && (f?.mine || f?.coOwner) ? f.newResponses || 0 : 0;
  useEffect(() => { if (newHere > 0) client.markSeen(id); }, [newHere]);

  if (pending) {
    return (
      <View style={st.fill}>
        <Header title="Waiting for sync" onBack={pop} />
        <View style={[st.fill, st.center, { padding: 28 }]}>
          <ActivityIndicator color={C.primary} />
          <Text style={[st.h2, { marginTop: 18, textAlign: "center" }]}>Waiting for the form to sync</Text>
          <Text style={[st.muted, { textAlign: "center", marginTop: 8 }]}>The link only carries the form id ({id}). Its questions arrive from peers on the network, usually within seconds.</Text>
          <Btn label="Ask peers again" onPress={() => { pullHistory(); toast("Asked peers for the form"); }} style={{ marginTop: 18 }} />
        </View>
      </View>
    );
  }
  const responses: any[] = snap.creatorView?.responses?.[id] || [];
  const confirmed = responses.filter((r) => r.confirmed).length;
  const qOf = (qid: string) => (f.questions || []).find((q: any) => q.id === qid);
  const set = (qid: string, v: any) => { typed.current = true; setAnswers((a) => ({ ...a, [qid]: v })); };
  const problem = (q: any): string => validateAnswer(q, answers[q.id]);   // shared rules (core enforces them too)
  const shown: any[] = f.shuffleQuestions ? seededOrder(f.questions.length, snap.identity.address + "|" + f.id).map((i) => f.questions[i]) : f.questions || [];
  const asked = shown.filter((q) => normType(q.type) !== "section");
  const done = asked.filter((q) => !emptyVal(answers[q.id])).length;
  const startEditing = () => {
    const a: Record<string, any> = {};
    for (const x of f.myAnswers?.answers || []) a[x.questionId] = x.value;
    setAnswers(a); setShowErrors(false); setEditing(true);
  };
  const answering = f.canRespond || (editing && f.canEdit);
  const submit = () => {
    if (preview) { toast("This is a preview - answers aren't sent"); return; }
    for (const q of f.questions) { const e = problem(q); if (e) { setShowErrors(true); toast(q.text + ": " + e); return; } }
    const arr = f.questions.filter((q: any) => normType(q.type) !== "section").map((q: any) => {
      const t = normType(q.type);
      return { questionId: q.id, value: answers[q.id] ?? (t === "checkbox" ? [] : t === "text" || t === "textarea" || t === "email" || t === "url" ? "" : null) };
    });
    typed.current = false;   // submitting drops the answer draft (client)
    const r = client.submitResponse(id, arr);
    if (r.ok) { toast(editing ? "Your edited answer is sealed and sent" : "Answers sealed and sent"); setAnswers({}); setShowErrors(false); setEditing(false); } else toast(r.error);
  };
  const unconfirmed = responses.length - confirmed;
  const list = (() => {
    const t = filter.trim().toLowerCase();
    if (!t) return responses;
    return responses.filter((r) => (r.respondent + " " + (r.answers || []).map((a: any) => answerText(qOf(a.questionId), a.value)).join(" ")).toLowerCase().includes(t));
  })();
  const at = Math.max(0, Math.min(idx, list.length - 1));
  const cur = list[at];
  const atCap = !!(f.maxResponses && responses.length >= f.maxResponses);
  const ended = !!(f.expiresAt && Date.now() > f.expiresAt);
  const info = [
    f.showResponseCount ? plural((f.confirmations || []).length, "response", "responses") + (f.mine ? " visible to respondents" : " received so far") : null,
    f.maxResponses ? (f.mine ? "closes automatically at " : "limited to ") + f.maxResponses : null,
    f.expiresAt ? (f.status === "closed" || ended ? "closed " : "closes ") + fmtTime(f.expiresAt) : null,
    restored && !f.mine && !f.mySubmitted ? "your unsent answers were restored" : null,
    f.anonymous && !f.mine ? "anonymous: you answer under a one-off identity for this form - the creator can't link it to your address" : null,
  ].filter(Boolean).join("  ·  ");
  const banner = (() => {
    if (f.linkMismatch) return { tone: "err", text: `This form's creator (${shortAddr(f.creator)}) is not the one in the link you opened (${shortAddr(f.pinnedCreator)}). WhisperBox won't send your answers to it.` } as const;
    if (f.contested && !f.mine && f.pinnedCreator !== f.creator) return { tone: "warn", text: "Two different people published a form with this id. Open it from the creator's own link to answer - your answers are only ever sealed to the creator that link names." } as const;
    if (f.mySubmitted) return { tone: "ok", text: (f.thankYou ? f.thankYou + "\n\n" : "") + (f.myConfirmed ? "Your answers were received - the creator sent you a receipt." : "Your answers are sealed and sent. You'll see a receipt here once the creator opens them.") } as const;
    if (f.status === "closed") return { tone: "info", text: "This form is closed and no longer accepts answers." } as const;
    if (!f.allowed) return { tone: "info", text: `This form only accepts answers from specific addresses, and yours (${shortAddr(snap.identity.address)}) isn't on the list.` } as const;
    return null;
  })();

  return (
    <View style={st.fill}>
      <Header onBack={pop} right={preview ? undefined :
        <View style={st.joinRow}>
          <Btn label={f.hidden ? "Unhide" : "Hide"} onPress={() => {
            if (f.hidden) { client.unhideForm(id); toast("Back in your lists"); }
            else { client.hideForm(id); toast("Hidden - find it under Hidden on the home screen"); pop(); }
          }} />
          <Btn label="Share" onPress={() => push({ k: "share", id })} />
        </View>
      } />
      <KeyboardAvoidingView style={st.fill} behavior={Platform.OS === "ios" ? "padding" : undefined}>
        <ScrollView contentContainerStyle={st.pad} keyboardShouldPersistTaps="handled">
          {preview ? <Banner tone="warn" text="Preview - this is what respondents will see. Nothing you enter here is sent." /> : null}
          <Text style={st.h1}>{f.title || "(untitled)"}</Text>
          <View style={st.badges}>
            <Badge label={f.status === "closed" ? "Closed" : "Open"} fg={f.status === "closed" ? C.text2 : C.ok} bg={f.status === "closed" ? C.raised : C.okSubtle} />
            {f.mine ? <Badge label="Yours" fg={C.primary} bg={C.primarySubtle} /> : null}
            {f.mine && f.keycard ? <Badge label="Keycard" fg={C.accent} bg={C.warnSubtle} /> : null}
            {f.whitelist?.type === "addresses" ? <Badge label="Members only" fg={C.accent} bg={C.warnSubtle} /> : null}
            {f.contested ? <Badge label="Contested id" fg={C.warn} bg={C.warnSubtle} /> : null}
            {f.anonymous ? <Badge label="Anonymous" fg={C.primary} bg={C.primarySubtle} /> : null}
          </View>
          <Text style={st.meta}>by {shortAddr(f.creator)}{f.createdAt ? "  ·  " + fmtTime(f.createdAt) : ""}{f.version > 1 && f.updatedAt ? "  ·  updated " + fmtTime(f.updatedAt) : ""}</Text>
          {f.description ? <Text style={st.desc}>{f.description}</Text> : null}
          {f.mine && f.keyMissing ? (
            <View style={{ marginTop: 14 }}>
              <Banner tone="warn" text="Answers to this form are sealed to a key from your Keycard, and that key isn't on this phone (new install?). Tap your card to unlock them - every form missing its key at once." />
              <Btn label="Unlock answers with Keycard" primary onPress={async () => {
                const ids: string[] = client.formsMissingKeys();
                try {
                  const keys = await requestCardKeys(ids, "Unlock answers with Keycard");
                  let ok = 0, bad = 0;
                  for (const k of keys) { const r = await client.addFormKey(k.formId, k.privHex); r.ok ? ok++ : bad++; }
                  toast(bad ? `${ok} unlocked, ${bad} didn't match this card - a different Keycard?` : `Unlocked ${plural(ok, "form", "forms")}`);
                } catch (e: any) { if (e?.code !== "cancelled") toast(String(e?.message || e)); }
              }} style={{ marginTop: 8 }} />
            </View>
          ) : null}

          {f.mine || f.coOwner ? (
            <View style={{ marginTop: 18 }}>
              <View style={st.stats}>
                {[{ n: responses.length, l: "Responses", c: C.primary }, { n: confirmed, l: "Receipts sent", c: C.ok }, { n: responses.length - confirmed, l: "Awaiting", c: C.warn }].map((x) => (
                  <View key={x.l} style={st.stat}><Text style={[st.statN, { color: x.c }]}>{x.n}</Text><Text style={st.statL}>{x.l}</Text></View>
                ))}
              </View>
              <View style={[st.chips, { marginTop: 12 }]}>
                {f.mine && f.status === "open" ? <Btn label={confirmClose ? "Tap again to close" : "Close form"} danger onPress={() => {
                  if (!confirmClose) { setConfirmClose(true); setTimeout(() => setConfirmClose(false), 3000); return; }
                  const r = client.closeForm(id); toast(r.ok ? "Form closed - no new answers" : r.error); setConfirmClose(false);
                }} /> : null}
                {f.mine && f.status === "closed" && !atCap && !ended ? <Btn label="Re-open" onPress={() => { const r = client.reopenForm(id); toast(r.ok ? "Re-opened - answers sealed while it was closed still don't count" : r.error); }} /> : null}
                {unconfirmed > 0 ? <Btn label={`Send all receipts (${unconfirmed})`} primary onPress={() => { const r = client.confirmAll(id); toast(r.ok ? `Receipts sent for ${plural(r.confirmed, "response", "responses")}` : r.error); }} /> : null}
                <Btn label="Export CSV" disabled={!responses.length} onPress={() => { const r = client.exportCsv(id); if (r.ok) push({ k: "csv", id, csv: r.csv }); else toast(r.error); }} />
                {f.mine ? <Btn label="Edit" onPress={() => push({ k: "create", editFormId: id })} /> : null}
                {f.mine ? <Btn label={showCo ? "Hide co-owners" : `Co-owners${(f.coOwners || []).length ? ` (${f.coOwners.length})` : ""}`} onPress={() => setShowCo((x) => !x)} /> : null}
                <Btn label="Duplicate" onPress={() => push({ k: "create", fromForm: id })} />
              </View>
              {f.coOwner ? <Text style={[st.muted, { marginTop: 10 }]}>You co-own this form: you can read its answers and send receipts. Closing and editing stay with its creator ({shortAddr(f.creator)}).</Text> : null}
              {f.mine && showCo ? (
                <View style={st.card}>
                  <Text style={st.muted}>A co-owner can read every answer and send receipts. They give you their co-owner code (Identity in their WhisperBox). Access can't be taken back once given, and the list of co-owner addresses is public.</Text>
                  {(f.coOwners || []).map((c: any) => <Text key={c.address} style={[st.addr, { marginTop: 6 }]}>• {c.address}</Text>)}
                  <View style={[st.joinRow, { marginTop: 10 }]}>
                    <TextInput value={coCode} onChangeText={setCoCode} autoCapitalize="none" placeholder="Co-owner code (66 characters)" placeholderTextColor={C.text3} style={[st.input, { flex: 1, fontFamily: MONO, fontSize: 12 }]} />
                    <Btn label="Add" primary disabled={!coCode.trim()} onPress={() => { const r = client.addCoOwner(id, coCode); toast(r.ok ? "Co-owner added - they can read answers now" : r.error); if (r.ok) setCoCode(""); }} />
                  </View>
                </View>
              ) : null}
              <View style={[st.card, st.cardHead]}>
                <View style={{ flex: 1, paddingRight: 12 }}>
                  <Text style={{ color: C.text, fontWeight: "600" }}>Automatic receipts</Text>
                  <Text style={st.muted}>Send a receipt as each answer arrives (while this phone is online).</Text>
                </View>
                <Switch value={!!f.autoReceipts} onValueChange={(v) => { client.setAutoReceipts(id, v); toast(v ? "Receipts now go out automatically" : "Automatic receipts off"); }} trackColor={{ true: C.ok, false: C.border }} thumbColor="#fff" />
              </View>
              {info ? <Text style={[st.muted, { marginTop: 8 }]}>{info}</Text> : null}

              {responses.length ? (
                <View style={[st.chips, { marginTop: 16 }]}>
                  {([["summary", "Summary"], ["question", "By question"], ["table", "Table"], ["one", "One by one"]] as const).map(([m, l]) => (
                    <Pressable key={m} onPress={() => setMode(m)} style={[st.chip, mode === m && st.chipOn]}><Text style={[st.chipT, mode === m && { color: C.primary }]}>{l}</Text></Pressable>
                  ))}
                </View>
              ) : <Text style={[st.muted, { marginTop: 16 }]}>No responses yet. Share the link - answers arrive sealed and only this phone can open them.</Text>}
              {responses.length && mode !== "summary" ? (
                <TextInput value={filter} onChangeText={(t) => { setFilter(t); setIdx(0); }} placeholder="Search answers or address" placeholderTextColor={C.text3} style={[st.input, { marginTop: 10 }]} />
              ) : null}
              {responses.length && mode !== "summary" && !list.length ? <Text style={[st.muted, { marginTop: 10 }]}>Nothing matches "{filter}".</Text> : null}

              {responses.length && mode === "summary" ? (f.questions || []).map((q: any, qi: number) => {
                const sm = summarize(q, responses);
                return (
                  <View key={q.id} style={st.card}>
                    <Text style={st.q}>{qi + 1}. {q.text}</Text>
                    <Text style={[st.time, { marginBottom: 6 }]}>{sm.answered} of {responses.length} answered</Text>
                    {sm.bars.map((b) => (
                      <View key={b.label} style={{ marginTop: 6 }}>
                        <View style={{ flexDirection: "row", justifyContent: "space-between" }}>
                          <Text style={[st.optT, { flex: 1 }]} numberOfLines={1}>{b.label}</Text>
                          <Text style={st.time}>{b.n}  ({b.pct}%)</Text>
                        </View>
                        <View style={st.barTrack}><View style={[st.barFill, { width: `${Math.max(b.n ? 3 : 0, b.w * 100)}%` }]} /></View>
                      </View>
                    ))}
                    {sm.stat ? <Text style={[st.muted, { marginTop: 6 }]}>{sm.stat}</Text> : null}
                    {sm.samples.map((t, i) => <Text key={i} style={[st.answer, { color: C.text2, marginTop: 6 }]}>“{t}”</Text>)}
                    {!sm.bars.length && sm.answered > sm.samples.length ? <Text style={[st.time, { marginTop: 6 }]}>+ {sm.answered - sm.samples.length} more - see Table or One by one</Text> : null}
                  </View>
                );
              }) : null}

              {mode === "question" && list.length ? (
                <View style={{ marginTop: 10 }}>
                  <ScrollView horizontal showsHorizontalScrollIndicator={false}>
                    {(f.questions || []).map((q: any, i: number) => (
                      <Pressable key={q.id} onPress={() => setQIdx(i)} style={[st.chip, { marginRight: 6 }, i === qIdx && st.chipOn]}>
                        <Text style={[st.chipT, i === qIdx && { color: C.primary }]} numberOfLines={1}>{i + 1}. {q.text}</Text>
                      </Pressable>
                    ))}
                  </ScrollView>
                  {(() => { const q = (f.questions || [])[Math.min(qIdx, (f.questions || []).length - 1)]; return q ? list.map((r, i) => {
                    const t = answerText(q, answerOf(r, q.id));
                    return (
                      <View key={i} style={[st.card, { flexDirection: "row", alignItems: "center", gap: 10 }]}>
                        <Text style={[st.answer, { flex: 1 }, !t && { color: C.text3 }]}>{t || "(no answer)"}</Text>
                        <Text style={[st.time, { fontFamily: MONO }]}>{shortAddr(r.respondent)}</Text>
                      </View>
                    );
                  }) : null; })()}
                </View>
              ) : null}
              {mode === "table" && list.length ? (
                <ScrollView horizontal style={[st.card, { padding: 0 }]} contentContainerStyle={{ flexDirection: "column" }}>
                  <View style={st.trow}>
                    {["#", "From", ...(f.questions || []).map((q: any) => q.text), "Receipt"].map((h, i) => (
                      <Text key={i} style={[st.th, { width: i === 0 ? 36 : i === 1 ? 110 : 160 }]} numberOfLines={1}>{h}</Text>
                    ))}
                  </View>
                  {list.map((r, ri) => (
                    <Pressable key={r.respondent + ri} onPress={() => { setIdx(ri); setMode("one"); }} style={[st.trow, ri % 2 ? { backgroundColor: C.raised } : null]}>
                      <Text style={[st.td, { width: 36 }]}>{ri + 1}{r.edits > 0 ? " ✎" : ""}</Text>
                      <Text style={[st.td, { width: 110, fontFamily: MONO }]} numberOfLines={1}>{shortAddr(r.respondent)}</Text>
                      {(f.questions || []).map((q: any) => <Text key={q.id} style={[st.td, { width: 160 }]} numberOfLines={2}>{answerText(q, answerOf(r, q.id))}</Text>)}
                      <Text style={[st.td, { width: 160, color: r.confirmed ? C.ok : C.warn }]}>{r.confirmed ? "sent" : "pending"}</Text>
                    </Pressable>
                  ))}
                </ScrollView>
              ) : null}
              {mode === "table" && list.length ? <Text style={[st.time, { marginTop: 6 }]}>Tap a row to open it. Swipe sideways for more questions.</Text> : null}

              {mode === "one" && cur ? (
                <View style={{ marginTop: 12 }}>
                  <View style={[st.joinRow, { justifyContent: "space-between" }]}>
                    <Btn label="‹ Prev" disabled={at === 0} onPress={() => setIdx(at - 1)} />
                    <View style={[st.joinRow, { gap: 6 }]}>
                      <TextInput value={jump} onChangeText={setJump} placeholder={String(at + 1)} placeholderTextColor={C.text2} keyboardType="number-pad"
                        onSubmitEditing={() => { const n = parseInt(jump, 10); if (n >= 1) setIdx(Math.min(list.length, n) - 1); setJump(""); }}
                        style={[st.input, { width: 56, textAlign: "center", paddingVertical: 6 }]} />
                      <Text style={st.muted}>of {list.length}</Text>
                    </View>
                    <Btn label="Next ›" disabled={at >= list.length - 1} onPress={() => setIdx(at + 1)} />
                  </View>
                  {list.length > 1 && list.length <= 60 ? (
                    <ScrollView horizontal showsHorizontalScrollIndicator={false} style={{ marginTop: 10 }}>
                      {list.map((r, i) => (
                        <Pressable key={i} onPress={() => setIdx(i)} style={[st.numChip, i === at && { backgroundColor: C.primary, borderColor: C.primary }, r.confirmed && i !== at && { borderColor: C.ok }]}>
                          <Text style={{ color: i === at ? "#fff" : C.text2, fontSize: 11 }}>{i + 1}</Text>
                        </Pressable>
                      ))}
                    </ScrollView>
                  ) : null}
                  <View style={st.card}>
                    <View style={st.cardHead}>
                      <Pressable onPress={async () => { await Clipboard.setStringAsync(cur.respondent); toast("Address copied"); }}><Text style={st.addr}>{shortAddr(cur.respondent)}</Text></Pressable>
                      <Text style={st.time}>{fmtTime(cur.submittedAt)}</Text>
                      <View style={{ flex: 1 }} />
                      {cur.edits > 0 ? <Badge label="edited" fg={C.accent} bg={C.warnSubtle} /> : null}
                      {cur.confirmed ? <Badge label="Receipt sent" /> : <Btn label="Send receipt" onPress={() => { const x = client.confirmResponse(id, cur.respondent); toast(x.ok ? "Receipt sent" : x.error); }} />}
                    </View>
                    {(f.questions || []).map((q: any, qi: number) => {
                      const v = answerText(q, answerOf(cur, q.id));
                      return (
                        <View key={q.id} style={{ marginTop: 12 }}>
                          <Text style={st.qSmall}>{qi + 1}. {q.text}</Text>
                          <Text style={[st.answer, { fontSize: 16 }, !v && { color: C.text3 }]}>{v || "(no answer)"}</Text>
                        </View>
                      );
                    })}
                  </View>
                </View>
              ) : null}
            </View>
          ) : (
            <View style={{ marginTop: 18 }}>
              {info ? <Text style={[st.muted, { marginBottom: 8 }]}>{info}</Text> : null}
              {banner ? <Banner tone={banner.tone} text={banner.text} /> : null}
              {f.mySubmitted && !editing ? (
                <View style={{ marginTop: 16 }}>
                  <View style={[st.cardHead, { justifyContent: "space-between" }]}>
                    <Label>YOUR ANSWERS</Label>
                    {f.canEdit ? <Btn label={`Edit (${Math.max(0, Math.ceil((f.editUntil - tick) / 60000))} min left)`} onPress={startEditing} /> : null}
                  </View>
                  {f.myAnswers ? (
                    <>
                      {(f.questions || []).map((q: any) => {
                        const v = (f.myAnswers.answers || []).find((a: any) => a.questionId === q.id)?.value;
                        const t = answerText(q, v);
                        return (
                          <View key={q.id} style={{ marginTop: 10 }}>
                            <Text style={st.qSmall}>{q.text}</Text>
                            <Text style={[st.answer, !t && { color: C.text3 }]}>{t || "(no answer)"}</Text>
                          </View>
                        );
                      })}
                      <Text style={[st.muted, { marginTop: 12, fontSize: 12 }]}>Kept only on this phone. What went out is sealed - only the creator can open it.</Text>
                    </>
                  ) : <Text style={st.muted}>Sent from an older WhisperBox that didn't keep a copy. Only the creator can read them now.</Text>}
                </View>
              ) : null}
              {answering && asked.length >= 4 ? (
                <View style={{ marginTop: 14 }}>
                  <Text style={st.time}>{done} of {asked.length} answered</Text>
                  <View style={[st.barTrack, { height: 4 }]}><View style={[st.barFill, { height: 4, width: `${(100 * done) / asked.length}%` }]} /></View>
                </View>
              ) : null}
              {answering ? shown.map((q: any, qi: number) => (
                <QuestionInput key={q.id} q={q} n={qi + 1} value={answers[q.id]} onChange={(v) => set(q.id, v)}
                  error={showErrors ? problem(q) : ""} order={q.shuffleOptions ? seededOrder((q.options || []).length, snap.identity.address + "|" + f.id + "|" + q.id) : null} />
              )) : null}
              {answering ? <Btn label={editing ? "Seal and send the edited answer" : "Seal and send answers"} primary onPress={submit} style={{ marginTop: 22, paddingVertical: 15 }} /> : null}
              <View style={st.privacy}>
                <LockMark size={14} tint={C.ok} />
                <Text style={st.privacyT}>Answers are encrypted to the creator's key before they leave this phone. Everyone else on the network - including peers that relay and store them - sees only an opaque blob. The receipt the creator sends back can't be linked to your address.</Text>
              </View>
            </View>
          )}
          <View style={{ height: 40 }} />
        </ScrollView>
      </KeyboardAvoidingView>
    </View>
  );
}

// ── Create ─────────────────────────────────────────────────────────────────────
type Draft = { id?: string; type: string; text: string; required: boolean; optionsText: string; help?: string; allowOther?: boolean; shuffleOptions?: boolean;
  min?: number; max?: number; minLabel?: string; maxLabel?: string; style?: string; numMin?: string; numMax?: string };
// Same starting points as the desktop builder.
const TEMPLATES: { name: string; b: any }[] = [
  { name: "Event RSVP", b: { title: "Are you coming?", description: "Let us know by Friday.", thankYou: "Thanks - see you there!", questions: [
    { type: "boolean", text: "Will you attend?", required: true, optionsText: "" },
    { type: "number", text: "How many guests are you bringing?", required: false, optionsText: "", numMin: "0", numMax: "10" },
    { type: "radioButtons", text: "Food preference", required: false, optionsText: "Anything\nVegetarian\nVegan", allowOther: true },
    { type: "textarea", text: "Anything we should know?", required: false, optionsText: "" }] } },
  { name: "Feedback", b: { title: "How did we do?", description: "", thankYou: "Thank you for the feedback!", questions: [
    { type: "scale", text: "Overall, how satisfied are you?", required: true, optionsText: "", min: 1, max: 5, style: "stars" },
    { type: "checkbox", text: "What did you like?", required: false, optionsText: "Content\nSpeakers\nVenue\nPeople", allowOther: true },
    { type: "textarea", text: "What should we improve?", required: false, optionsText: "" }] } },
  { name: "Quick poll", b: { title: "Quick poll", description: "", questions: [
    { type: "radioButtons", text: "Which option do you prefer?", required: true, optionsText: "Option A\nOption B\nOption C", shuffleOptions: true }] } },
  { name: "Sign-up sheet", b: { title: "Sign up", description: "", questions: [
    { type: "text", text: "Name", required: true, optionsText: "" },
    { type: "email", text: "Email (optional - only the organiser sees it)", required: false, optionsText: "" },
    { type: "dropdown", text: "Slot", required: true, optionsText: "Morning\nAfternoon\nEvening" }] } },
  { name: "NPS", b: { title: "Would you recommend us?", description: "", questions: [
    { type: "scale", text: "How likely are you to recommend us to a friend?", required: true, optionsText: "", min: 0, max: 10, minLabel: "Not likely", maxLabel: "Very likely" },
    { type: "textarea", text: "What's the main reason for your score?", required: false, optionsText: "" }] } },
];
// "yyyy-MM-dd HH:mm" (local) -> ms, or NaN
function parseLocal(t: string) {
  const m = /^\s*(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{1,2}):(\d{2}))?\s*$/.exec(t || "");
  return m ? new Date(+m[1], +m[2] - 1, +m[3], m[4] ? +m[4] : 23, m[5] ? +m[5] : 59).getTime() : NaN;
}
const fmtInput = (ms: number) => { const d = new Date(ms); const z = (n: number) => String(n).padStart(2, "0"); return `${d.getFullYear()}-${z(d.getMonth() + 1)}-${z(d.getDate())} ${z(d.getHours())}:${z(d.getMinutes())}`; };
type Builder = { title: string; description: string; questions: Draft[]; restrict: boolean; allowList: string; max: string; closeAt: string; showCount: boolean; thankYou?: string; shuffle?: boolean };
function CreateScreen({ replace, pop, push, toast, draftId, fromForm, editFormId }: Ctx & { draftId?: string; fromForm?: string; editFormId?: string }) {
  // Start from: a saved draft, a form to duplicate, or empty.
  const init = useMemo<Builder>(() => {
    const d = draftId ? client.drafts[draftId] : null;
    if (d?.def?._builder) return d.def._builder as Builder;
    const src = fromForm || editFormId;
    const f = src ? client.snapshot().state.forms[src] : null;
    // editing keeps question ids (answers are stored by id); a duplicate gets fresh ones
    if (f) return {
      title: editFormId ? f.title || "" : (f.title || "") + " (copy)", description: f.description || "",
      questions: (f.questions || []).map((q: any) => { const { id: qid, options: _o, ...rest } = q; return { ...rest, ...(editFormId ? { id: qid } : {}), type: normType(q.type), text: q.text || "", required: !!q.required, optionsText: (q.options || []).join("\n"),
        ...(q.type === "number" ? { numMin: q.min !== undefined ? String(q.min) : "", numMax: q.max !== undefined ? String(q.max) : "" } : {}) }; }),
      thankYou: f.thankYou || "", shuffle: !!f.shuffleQuestions, allowEdits: !!f.allowEdits, anonymous: !!f.anonymous,
      restrict: f.whitelist?.type === "addresses", allowList: String(f.whitelist?.value || "").split(",").join("\n"),
      max: f.maxResponses ? String(f.maxResponses) : "", closeAt: editFormId && f.expiresAt ? fmtInput(f.expiresAt) : "", showCount: !!f.showResponseCount,
    };
    return { title: "", description: "", questions: [{ type: "text", text: "", required: true, optionsText: "" }], restrict: false, allowList: "", max: "", closeAt: "", showCount: false };
  }, []);
  const [title, setTitle] = useState(init.title);
  const [desc, setDesc] = useState(init.description);
  const [qs, setQs] = useState<Draft[]>(init.questions);
  const [restrict, setRestrict] = useState(init.restrict);
  const [allow, setAllow] = useState(init.allowList);
  const [max, setMax] = useState(init.max);
  const [closeAt, setCloseAt] = useState(init.closeAt);
  const [showCount, setShowCount] = useState(init.showCount);
  const [thankYou, setThankYou] = useState(init.thankYou || "");
  const [shuffle, setShuffle] = useState(!!init.shuffle);
  const [allowEdits, setAllowEdits] = useState(!!(init as any).allowEdits);
  const [anonymous, setAnonymous] = useState(!!(init as any).anonymous);
  const useTemplate = (b: any) => { setTitle(b.title); setDesc(b.description || ""); setQs(JSON.parse(JSON.stringify(b.questions))); setThankYou(b.thankYou || ""); };
  const [scheduling, setScheduling] = useState(!!(draftId && client.drafts[draftId]?.publishAt));
  const [publishAt, setPublishAt] = useState(draftId && client.drafts[draftId]?.publishAt ? fmtInput(client.drafts[draftId].publishAt) : "");
  const [useCard, setUseCard] = useState(false);
  const [busy, setBusy] = useState(false);
  const did = useRef<string | undefined>(draftId);
  const dirty = useRef(!!fromForm);
  useEffect(() => { getKeycardPrefs().then((p) => setUseCard(p.useForNewForms)).catch(() => {}); }, []);
  const upd = (i: number, p: Partial<Draft>) => setQs((a) => a.map((q, j) => (j === i ? { ...q, ...p } : q)));
  const move = (i: number, d: number) => setQs((a) => { const j = i + d; if (j < 0 || j >= a.length) return a; const b = a.slice(); [b[i], b[j]] = [b[j], b[i]]; return b; });
  const builder: Builder = { title, description: desc, questions: qs, restrict, allowList: allow, max, closeAt, showCount, thankYou, shuffle, allowEdits, anonymous } as any;
  const empty = !title.trim() && !desc.trim() && !qs.some((q) => q.text.trim());

  // -> {ok, def} | {ok:false, error}. strict=false never fails (autosave of a half-done form).
  const buildDef = (strict: boolean): { ok: true; def: any } | { ok: false; error: string } => {
    const fail = (error: string) => ({ ok: false as const, error });
    if (strict && !title.trim()) return fail("Give the form a title");
    const questions: any[] = [];
    const used = new Set(qs.map((d) => d.id).filter(Boolean) as string[]);
    let next = 1 + Math.max(0, ...[...used].map((x) => Number(/^q(\d+)$/.exec(x)?.[1] || 0)));
    const fresh = () => { while (used.has("q" + next)) next++; used.add("q" + next); return "q" + next++; };
    for (const d of qs) {
      const text = d.text.trim(); if (!text) continue;
      // existing questions keep their id; new ones get a fresh one (no ids yet = q1..qn)
      const q: any = { id: d.id || (used.size ? fresh() : "q" + (questions.length + 1)), type: d.type, text, required: d.required };
      if ((d.help || "").trim()) q.help = d.help!.trim();
      if (isChoice(d.type)) {
        q.options = d.optionsText.split("\n").map((x) => x.trim()).filter(Boolean);
        if (strict && q.options.length < 2) return fail(`"${text}" needs at least two options`);
        if (d.allowOther) q.allowOther = true;
        if (d.shuffleOptions) q.shuffleOptions = true;
      }
      if (d.type === "scale") {
        q.min = d.min === 0 ? 0 : 1; q.max = [3, 4, 5, 7, 10].includes(d.max as number) ? d.max : 5;
        if ((d.minLabel || "").trim()) q.minLabel = d.minLabel!.trim();
        if ((d.maxLabel || "").trim()) q.maxLabel = d.maxLabel!.trim();
        if (d.style === "stars") q.style = "stars";
      }
      if (d.type === "number") {
        const mn = (d.numMin || "").trim(), mx = (d.numMax || "").trim();
        if (mn !== "" && !isNaN(Number(mn))) q.min = Number(mn);
        if (mx !== "" && !isNaN(Number(mx))) q.max = Number(mx);
        if (strict && q.min !== undefined && q.max !== undefined && q.min > q.max) return fail(`"${text}": minimum is above maximum`);
      }
      questions.push(q);
    }
    if (strict && !questions.length) return fail("Add at least one question");
    let whitelist = { type: "none", value: "" };
    if (restrict) {
      const addrs = allow.split(/[\s,]+/).filter((a) => /^0x[0-9a-fA-F]{40}$/.test(a)).map((a) => a.toLowerCase());
      if (strict && !addrs.length) return fail("Add at least one 0x address, or allow anyone");
      whitelist = { type: "addresses", value: addrs.join(",") };
    }
    const def: any = { title: title.trim(), description: desc.trim(), questions, whitelist };
    if (max.trim()) { const n = parseInt(max, 10); if (strict && (!(n > 0) || String(n) !== max.trim())) return fail("Max answers must be a whole number"); if (n > 0) def.maxResponses = n; }
    if (closeAt.trim()) { const t = parseLocal(closeAt); if (strict && isNaN(t)) return fail("Close date: use yyyy-MM-dd HH:mm"); if (strict && t <= Date.now()) return fail("Close date is in the past"); if (!isNaN(t)) def.expiresAt = t; }
    if (showCount) def.showResponseCount = true;
    if (thankYou.trim()) def.thankYou = thankYou.trim();
    if (shuffle) def.shuffleQuestions = true;
    if (allowEdits) { def.allowEdits = true; def.editWindowMinutes = 15; }
    if (anonymous) { if (strict && restrict) return fail("An anonymous form can't be members-only - it would need real addresses"); def.anonymous = true; }
    return { ok: true, def };
  };
  const saveDraft = (publishAtMs?: number | null) => {
    const b = buildDef(!!publishAtMs);
    if (!b.ok) { toast(b.error); return false; }
    const r = client.saveDraft({ id: did.current, def: { ...b.def, _builder: builder }, publishAt: publishAtMs ?? null });
    if (r.ok) { did.current = r.draftId; dirty.current = false; }
    return r.ok;
  };
  // Autosave: drafts never get lost to a crash or an unfinished form.
  useEffect(() => {
    if (!dirty.current) { dirty.current = true; return; }   // skip the initial render
    if (empty || editFormId) return;   // editing a published form: saved with "Save", no draft
    const t = setTimeout(() => saveDraft(scheduling ? parseLocal(publishAt) || null : null), 1500);
    return () => clearTimeout(t);
  }, [title, desc, qs, restrict, allow, max, closeAt, showCount, thankYou, shuffle, allowEdits, anonymous]);
  const leave = () => {
    if (editFormId) { pop(); return; }
    if (!empty && dirty.current) { saveDraft(scheduling && !isNaN(parseLocal(publishAt)) ? parseLocal(publishAt) : null); toast("Saved as a draft"); }
    else if (empty && did.current) client.deleteDraft(did.current);
    pop();
  };
  const schedule = () => {
    if (useCard) { toast("Keycard forms need a tap when they go out - publish now instead"); return; }
    const t = parseLocal(publishAt);
    if (isNaN(t)) { toast("Publish time: use yyyy-MM-dd HH:mm"); return; }
    if (t <= Date.now()) { toast("That time has passed - use Publish"); return; }
    if (saveDraft(t)) { toast(`Scheduled for ${fmtTime(t)} - goes out when WhisperBox is open then (or the next time you open it)`); pop(); }
  };
  const done = (formId: string) => {
    if (did.current) client.deleteDraft(did.current);
    notificationsEnabled().then((on) => { if (on) ensurePermission(); }).catch(() => {});   // tell me when answers arrive
    replace({ k: "form", id: formId });
  };
  const publish = async () => {
    if (busy) return;
    const b = buildDef(true);
    if (!b.ok) { toast(b.error); return; }
    const def = b.def;
    if (editFormId) {
      const r = client.updateForm(editFormId, def);
      if (r.ok) { toast("Form updated - everyone sees the new version"); pop(); } else toast(r.error);
      return;
    }
    if (!useCard) {
      const r = client.createForm(def);
      if (r.ok) { toast("Form published"); done(r.formId); } else toast(r.error);
      return;
    }
    // Keycard: the form's key is exported from the card BEFORE publishing, and stored here
    // first - a form never goes out without its key on this phone.
    setBusy(true);
    try {
      const id = client.newFormId();
      const [k] = await requestCardKeys([id], "Seal this form with your Keycard");
      const saved = await client.addFormKey(id, k.privHex);
      if (!saved.ok) { toast(saved.error); return; }
      const r = client.createForm({ ...def, id }, { publicKey: k.pubHex });
      if (r.ok) { toast("Form published - answers open only with your Keycard's key"); done(r.formId); } else toast(r.error);
    } catch (e: any) {
      if (e?.code !== "cancelled") toast(String(e?.message || e));
    } finally { setBusy(false); }
  };

  return (
    <View style={st.fill}>
      <Header title={editFormId ? "Edit form" : draftId ? "Edit draft" : fromForm ? "Duplicate form" : "New form"} onBack={leave} right={<Btn label={busy ? "Publishing…" : editFormId ? "Save" : "Publish"} primary disabled={busy} onPress={publish} />} />
      <KeyboardAvoidingView style={st.fill} behavior={Platform.OS === "ios" ? "padding" : undefined}>
        <ScrollView contentContainerStyle={st.pad} keyboardShouldPersistTaps="handled">
          {editFormId ? <Banner tone="warn" text="Editing a published form: everyone gets the new version. Answers already sent stay attached to their questions; removing a question hides its answers." /> : null}
          {!did.current && !editFormId && empty ? (
            <View style={{ marginBottom: 14 }}>
              <Label>START FROM A TEMPLATE</Label>
              <View style={st.chips}>{TEMPLATES.map((t) => <Pressable key={t.name} onPress={() => useTemplate(t.b)} style={st.chip}><Text style={st.chipT}>{t.name}</Text></Pressable>)}</View>
            </View>
          ) : null}
          <Label>TITLE</Label>
          <TextInput value={title} onChangeText={setTitle} placeholder="What are you asking about?" placeholderTextColor={C.text3} style={[st.input, { fontWeight: "600" }]} />
          <View style={{ marginTop: 14 }}><Label>DESCRIPTION (OPTIONAL)</Label></View>
          <TextInput value={desc} onChangeText={setDesc} multiline placeholder="Context for respondents" placeholderTextColor={C.text3} style={[st.input, { minHeight: 70, textAlignVertical: "top" }]} />
          <View style={{ marginTop: 18 }}><Label>QUESTIONS ({qs.length})</Label></View>
          {qs.map((q, i) => {
            const choice = isChoice(q.type);
            return (
              <View key={i} style={st.card}>
                <View style={st.cardHead}>
                  <Text style={{ color: C.primary, fontWeight: "700", marginRight: 8 }}>Q{i + 1}</Text>
                  <TextInput value={q.text} onChangeText={(t) => upd(i, { text: t })} placeholder="Question" placeholderTextColor={C.text3} style={[st.input, { flex: 1, backgroundColor: C.surface }]} />
                </View>
                <View style={st.chips}>
                  {QTYPES.map((t) => (
                    <Pressable key={t.t} onPress={() => upd(i, { type: t.t })} style={[st.chip, q.type === t.t && st.chipOn]}>
                      <Text style={[st.chipT, q.type === t.t && { color: C.primary }]}>{t.label}</Text>
                    </Pressable>
                  ))}
                  <Pressable onPress={() => upd(i, { required: !q.required })} style={[st.chip, q.required && { borderColor: C.accent, backgroundColor: C.warnSubtle }]}>
                    <Text style={[st.chipT, q.required && { color: C.accent }]}>{q.required ? "Required" : "Optional"}</Text>
                  </Pressable>
                </View>
                <View style={[st.chips, { marginTop: 6 }]}>
                  {i > 0 ? <Pressable onPress={() => move(i, -1)} style={[st.chip, { borderColor: "transparent" }]} accessibilityLabel={`Move question ${i + 1} up`}><Text style={st.chipT}>↑ Up</Text></Pressable> : null}
                  {i < qs.length - 1 ? <Pressable onPress={() => move(i, 1)} style={[st.chip, { borderColor: "transparent" }]} accessibilityLabel={`Move question ${i + 1} down`}><Text style={st.chipT}>↓ Down</Text></Pressable> : null}
                  <Pressable onPress={() => setQs((a) => { const { id: _x, ...c } = a[i]; return [...a.slice(0, i + 1), c, ...a.slice(i + 1)]; })} style={[st.chip, { borderColor: "transparent" }]}><Text style={st.chipT}>Copy</Text></Pressable>
                  {qs.length > 1 ? (
                    <Pressable onPress={() => setQs((a) => a.filter((_, j) => j !== i))} style={[st.chip, { borderColor: "transparent" }]} accessibilityLabel={`Remove question ${i + 1}`}>
                      <Text style={[st.chipT, { color: C.err }]}>Remove</Text>
                    </Pressable>
                  ) : null}
                </View>
                <TextInput value={q.help || ""} onChangeText={(t) => upd(i, { help: t })} placeholder="Help text (optional)" placeholderTextColor={C.text3} style={[st.input, { backgroundColor: C.surface, marginTop: 10, fontSize: 13, paddingVertical: 8 }]} />
                {choice ? <TextInput value={q.optionsText} onChangeText={(t) => upd(i, { optionsText: t })} multiline placeholder="One option per line" placeholderTextColor={C.text3} style={[st.input, { minHeight: 84, textAlignVertical: "top", backgroundColor: C.surface, marginTop: 10 }]} /> : null}
                {choice ? (
                  <View style={st.chips}>
                    {([["allowOther", 'Allow "Other"'], ["shuffleOptions", "Shuffle options"]] as const).map(([k, l]) => (
                      <Pressable key={k} onPress={() => upd(i, { [k]: !q[k] } as any)} style={[st.chip, q[k] && st.chipOn]}><Text style={[st.chipT, q[k] && { color: C.primary }]}>{q[k] ? "✓ " : ""}{l}</Text></Pressable>
                    ))}
                  </View>
                ) : null}
                {q.type === "scale" ? (
                  <View>
                    <View style={st.chips}>
                      {([["min", 0, "from 0"], ["min", 1, "from 1"], ["max", 3, "to 3"], ["max", 4, "4"], ["max", 5, "5"], ["max", 7, "7"], ["max", 10, "10"], ["style", "numbers", "Numbers"], ["style", "stars", "Stars ★"]] as const).map(([k, v, l]) => {
                        const cur = (q as any)[k] ?? (k === "min" ? 1 : k === "max" ? 5 : "numbers"); const on = cur === v;
                        return <Pressable key={k + String(v)} onPress={() => upd(i, { [k]: v } as any)} style={[st.chip, on && st.chipOn]}><Text style={[st.chipT, on && { color: C.primary }]}>{l}</Text></Pressable>;
                      })}
                    </View>
                    <View style={[st.joinRow, { marginTop: 8 }]}>
                      <TextInput value={q.minLabel || ""} onChangeText={(t) => upd(i, { minLabel: t })} placeholder="Low-end label" placeholderTextColor={C.text3} style={[st.input, { flex: 1, backgroundColor: C.surface, fontSize: 13, paddingVertical: 8 }]} />
                      <TextInput value={q.maxLabel || ""} onChangeText={(t) => upd(i, { maxLabel: t })} placeholder="High-end label" placeholderTextColor={C.text3} style={[st.input, { flex: 1, backgroundColor: C.surface, fontSize: 13, paddingVertical: 8 }]} />
                    </View>
                  </View>
                ) : null}
                {q.type === "number" ? (
                  <View style={[st.joinRow, { marginTop: 8 }]}>
                    <TextInput value={q.numMin || ""} onChangeText={(t) => upd(i, { numMin: t })} keyboardType="numbers-and-punctuation" placeholder="Minimum (optional)" placeholderTextColor={C.text3} style={[st.input, { flex: 1, backgroundColor: C.surface, fontSize: 13, paddingVertical: 8 }]} />
                    <TextInput value={q.numMax || ""} onChangeText={(t) => upd(i, { numMax: t })} keyboardType="numbers-and-punctuation" placeholder="Maximum (optional)" placeholderTextColor={C.text3} style={[st.input, { flex: 1, backgroundColor: C.surface, fontSize: 13, paddingVertical: 8 }]} />
                  </View>
                ) : null}
              </View>
            );
          })}
          <Btn label="+ Add question" onPress={() => setQs((a) => [...a, { type: "text", text: "", required: false, optionsText: "" }])} style={{ marginTop: 12 }} />
          <View style={{ marginTop: 22 }}><Label>WHO CAN ANSWER</Label></View>
          <View style={st.chips}>
            {[{ r: false, l: "Anyone with the link" }, { r: true, l: "Only listed addresses" }].map((x) => (
              <Pressable key={x.l} onPress={() => { setRestrict(x.r); if (x.r) setAnonymous(false); }} style={[st.chip, restrict === x.r && st.chipOn]}>
                <Text style={[st.chipT, restrict === x.r && { color: C.primary }]}>{x.l}</Text>
              </Pressable>
            ))}
          </View>
          {restrict ? <TextInput value={allow} onChangeText={setAllow} multiline autoCapitalize="none" placeholder="0x addresses, one per line (respondents find theirs under Identity)" placeholderTextColor={C.text3} style={[st.input, { minHeight: 80, textAlignVertical: "top", fontFamily: MONO, fontSize: 12, marginTop: 10 }]} /> : null}
          <View style={{ marginTop: 22 }}><Label>ANSWERS OPEN WITH</Label></View>
          <View style={st.chips}>
            {[{ c: false, l: "A key on this phone" }, { c: true, l: "My Keycard" }].map((x) => (
              <Pressable key={x.l} onPress={() => setUseCard(x.c)} style={[st.chip, useCard === x.c && st.chipOn]}>
                <Text style={[st.chipT, useCard === x.c && { color: C.primary }]}>{x.l}</Text>
              </Pressable>
            ))}
          </View>
          <Text style={[st.muted, { marginTop: 8 }]}>{useCard
            ? "One tap when you publish. The form gets its own key from your card; reinstalling or switching phones only needs another tap. Other forms and your card's other keys stay on the card."
            : "Each form gets its own key, derived from this phone's identity key."}</Text>
          <Pressable onPress={() => setShuffle((x) => !x)} style={[st.chip, { marginTop: 18, alignSelf: "flex-start" }, shuffle && st.chipOn]}>
            <Text style={[st.chipT, shuffle && { color: C.primary }]}>{shuffle ? "✓ " : ""}Shuffle question order for each respondent</Text>
          </Pressable>
          <Pressable onPress={() => setAllowEdits((x) => !x)} style={[st.chip, { marginTop: 8, alignSelf: "flex-start" }, allowEdits && st.chipOn]}>
            <Text style={[st.chipT, allowEdits && { color: C.primary }]}>{allowEdits ? "✓ " : ""}Let people edit their answer for 15 minutes (until you send a receipt)</Text>
          </Pressable>
          <Pressable onPress={() => { setAnonymous((x) => !x); if (!anonymous) setRestrict(false); }} style={[st.chip, { marginTop: 8, alignSelf: "flex-start" }, anonymous && st.chipOn]}>
            <Text style={[st.chipT, anonymous && { color: C.primary }]}>{anonymous ? "✓ " : ""}Anonymous answers (you can't link them to anyone's address)</Text>
          </Pressable>
          <View style={{ marginTop: 18 }}><Label>THANK-YOU MESSAGE (OPTIONAL)</Label></View>
          <TextInput value={thankYou} onChangeText={setThankYou} placeholder="Shown to respondents after they send their answers" placeholderTextColor={C.text3} style={st.input} />
          <View style={{ marginTop: 22 }}><Label>LIMITS & TIMING (OPTIONAL)</Label></View>
          <View style={[st.joinRow, { alignItems: "flex-start" }]}>
            <View style={{ width: 120 }}>
              <Text style={st.time}>Close after N answers</Text>
              <TextInput value={max} onChangeText={(t) => setMax(t.replace(/\D/g, ""))} keyboardType="number-pad" placeholder="no limit" placeholderTextColor={C.text3} style={[st.input, { marginTop: 4 }]} />
            </View>
            <View style={{ flex: 1 }}>
              <Text style={st.time}>Close at (yyyy-MM-dd HH:mm)</Text>
              <TextInput value={closeAt} onChangeText={setCloseAt} placeholder="no end date" placeholderTextColor={C.text3} style={[st.input, { marginTop: 4 }]} />
            </View>
          </View>
          <Pressable onPress={() => setShowCount((x) => !x)} style={[st.chip, { marginTop: 10, alignSelf: "flex-start" }, showCount && st.chipOn]}>
            <Text style={[st.chipT, showCount && { color: C.primary }]}>{showCount ? "✓ " : ""}Show respondents how many answers came in</Text>
          </Pressable>
          <Text style={[st.muted, { marginTop: 14 }]}>The form (title, questions, who may answer) is public on the network. Answers are encrypted to this form's key. Drafts stay on this phone.</Text>

          <View style={{ marginTop: 22 }}><Label>PUBLISH</Label></View>
          <View style={st.chips}>
            {editFormId ? null : <Btn label="Preview" onPress={() => {
              const b = buildDef(false); if (!b.ok) return;
              // only the top screen is mounted: keep the edits as a draft and come back to it
              if (!empty && saveDraft(null) && did.current) replace({ k: "create", draftId: did.current });
              push({ k: "preview", def: b.def });
            }} />}
            {!editFormId ? <Btn label="Save draft" onPress={() => { if (saveDraft(null)) toast("Draft saved"); }} /> : null}
            {!editFormId ? <Btn label={scheduling ? "Don't schedule" : "Schedule…"} onPress={() => setScheduling((x) => !x)} /> : null}
            {did.current ? <Btn label="Delete draft" danger onPress={() => { client.deleteDraft(did.current!); dirty.current = false; toast("Draft deleted"); pop(); }} /> : null}
          </View>
          {scheduling ? (
            <View style={{ marginTop: 10 }}>
              <View style={st.joinRow}>
                <TextInput value={publishAt} onChangeText={setPublishAt} placeholder="yyyy-MM-dd HH:mm" placeholderTextColor={C.text3} style={[st.input, { flex: 1 }]} />
                <Btn label="Schedule" primary onPress={schedule} />
              </View>
              <Text style={[st.muted, { marginTop: 6 }]}>There's no server: the form goes out when WhisperBox is open on this phone at that time, or the next time you open it.</Text>
            </View>
          ) : null}
          <View style={{ height: 40 }} />
        </ScrollView>
      </KeyboardAvoidingView>
    </View>
  );
}

// ── Share / CSV / Scan / Identity ──────────────────────────────────────────────
function ShareScreen({ pop, toast, id }: Ctx & { id: string }) {
  const r = client.shareUri(id);
  const uri: string = r.ok ? r.uri : "";
  return (
    <View style={st.fill}>
      <Header title="Share form" onBack={pop} />
      <ScrollView contentContainerStyle={[st.pad, { alignItems: "center" }]}>
        <View style={st.qr}>{uri ? <QRCode value={uri} size={220} color={C.bg} backgroundColor="#ffffff" ecl="M" /> : null}</View>
        <Text style={st.link} selectable>{uri}</Text>
        <View style={[st.joinRow, { marginTop: 14, alignSelf: "stretch" }]}>
          <Btn label="Copy link" primary onPress={async () => { await Clipboard.setStringAsync(uri); toast("Link copied"); }} style={{ flex: 1 }} />
          <Btn label="Share…" onPress={() => Share.share({ message: uri })} style={{ flex: 1 }} />
        </View>
        <Text style={[st.muted, { marginTop: 16, textAlign: "center" }]}>The link names the form and its creator, so a respondent's answers are sealed only to you even if someone else copies the form id. The questions sync from the network.</Text>
      </ScrollView>
    </View>
  );
}
function CsvScreen({ pop, toast, csv }: Ctx & { csv: string }) {
  return (
    <View style={st.fill}>
      <Header title="Responses as CSV" onBack={pop} right={<Btn label="Share…" primary onPress={() => Share.share({ message: csv })} />} />
      <ScrollView contentContainerStyle={st.pad}>
        <Text style={st.muted}>Decrypted on this phone only. Nothing is uploaded unless you share it.</Text>
        <ScrollView horizontal style={[st.card, { marginTop: 12 }]}>
          <Text style={st.csv} selectable>{csv}</Text>
        </ScrollView>
        <Btn label="Copy CSV" onPress={async () => { await Clipboard.setStringAsync(csv); toast("CSV copied"); }} style={{ marginTop: 12 }} />
      </ScrollView>
    </View>
  );
}
function ScanScreen({ pop, openLink, toast }: Ctx) {
  const [perm, request] = useCameraPermissions();
  const done = useRef(false);
  useEffect(() => { if (perm && !perm.granted && perm.canAskAgain) request(); }, [perm, request]);
  return (
    <View style={st.fill}>
      <Header title="Scan a form's QR" onBack={pop} />
      {perm?.granted ? (
        <View style={st.fill}>
          <CameraView style={st.fill} facing="back" barcodeScannerSettings={{ barcodeTypes: ["qr"] }}
            onBarcodeScanned={({ data }) => {
              if (done.current) return;
              if (!String(data).startsWith("whisperbox://")) { toast("That QR isn't a WhisperBox link"); return; }
              done.current = true; openLink(String(data));
            }} />
          <View pointerEvents="none" style={st.scanFrame} />
        </View>
      ) : (
        <View style={[st.fill, st.center, { padding: 28 }]}>
          <Text style={[st.muted, { textAlign: "center" }]}>WhisperBox needs the camera only to read a form's QR code.</Text>
          <Btn label="Allow camera" primary onPress={request} style={{ marginTop: 16 }} />
        </View>
      )}
    </View>
  );
}
function IdentityScreen({ snap, pop, toast }: Ctx) {
  const [shared, setShared] = useState(net.shared);
  const d = snap.diagnostics;
  const rows: [string, string][] = [
    ["Network", net.started ? (net.shared ? "Loam shared node" : "Own node") : net.status],
    ["Status", net.status], ["Device", snap.deviceId], ["Events", String(d.logSize)],
    ["Received", String(d.rxRaw)], ["New", String(d.rxNew)], ["Sent", String(d.txTotal)],
    ["Catch-up frames", String(d.rbsrRx)], ["Rejected", String(d.admDropSig + d.admDropType)],
  ];
  return (
    <View style={st.fill}>
      <Header title="Identity & network" onBack={pop} />
      <ScrollView contentContainerStyle={st.pad}>
        <Label>YOUR ADDRESS</Label>
        <Pressable onPress={async () => { await Clipboard.setStringAsync(snap.identity.address); toast("Address copied"); }} style={st.card}>
          <Text style={[st.addr, { fontSize: 13 }]} selectable>{snap.identity.address}</Text>
          <Text style={[st.muted, { marginTop: 6 }]}>Tap to copy. Creators of members-only forms need this address. The key behind it never leaves this phone.</Text>
        </Pressable>
        <View style={{ marginTop: 18 }}><Label>YOUR CO-OWNER CODE</Label></View>
        <Pressable onPress={async () => { await Clipboard.setStringAsync(snap.identity.pubHex); toast("Co-owner code copied"); }} style={st.card}>
          <Text style={[st.addr, { fontSize: 12 }]} selectable>{snap.identity.pubHex}</Text>
          <Text style={[st.muted, { marginTop: 6 }]}>Tap to copy. Give it to a form's creator to become a co-owner - you'll be able to read that form's answers.</Text>
        </Pressable>
        <View style={{ marginTop: 18 }}><Label>NETWORK</Label></View>
        <View style={st.card}>
          {rows.map(([k, v]) => (
            <View key={k} style={st.kv}><Text style={st.kvK}>{k}</Text><Text style={st.kvV} numberOfLines={1}>{v}</Text></View>
          ))}
        </View>
        <View style={[st.card, st.cardHead]}>
          <View style={{ flex: 1, paddingRight: 12 }}>
            <Text style={{ color: C.text, fontWeight: "600" }}>Use the Loam shared node</Text>
            <Text style={st.muted}>One network node for all your Logos apps (saves battery). Takes effect after restarting WhisperBox.</Text>
          </View>
          <Switch value={shared} onValueChange={async (v) => { setShared(v); await setSharedNode(v); toast("Applies after restarting WhisperBox"); }} trackColor={{ true: C.primary, false: C.border }} thumbColor="#fff" />
        </View>
        <NotifySetting toast={toast} />
        <KeycardSettings toast={toast} snap={snap} />
        <Btn label="Ask peers for anything I'm missing" onPress={() => { pullHistory(); toast("Catch-up requested"); }} style={{ marginTop: 12 }} />
        <Btn label="Copy debug log" onPress={async () => {
          await Clipboard.setStringAsync(`WhisperBox ${snap.deviceId}\nlastError: ${client.lastError || "-"}\ndiag: ${JSON.stringify(snap.diagnostics)}\n--- this session ---\n${currentLog()}\n--- previous session ---\n${previousLog()}`);
          toast("Debug log copied");
        }} style={{ marginTop: 10 }} />
        {net.error ? <Banner tone="err" text={"Network error: " + net.error} /> : null}
      </ScrollView>
    </View>
  );
}

function NotifySetting({ toast }: { toast: (m: string) => void }) {
  const [on, setOn] = useState(true);
  useEffect(() => { notificationsEnabled().then(setOn).catch(() => {}); }, []);
  return (
    <View style={[st.card, st.cardHead, { marginTop: 18 }]}>
      <View style={{ flex: 1, paddingRight: 12 }}>
        <Text style={{ color: C.text, fontWeight: "600" }}>Notify me about new answers</Text>
        <Text style={st.muted}>While WhisperBox runs in the background. Shows the form title and how many - never the answers.</Text>
      </View>
      <Switch value={on} onValueChange={async (v) => { setOn(v); await setNotificationsEnabled(v); toast(v ? "You'll be notified about new answers" : "No answer notifications"); }} trackColor={{ true: C.primary, false: C.border }} thumbColor="#fff" />
    </View>
  );
}

function KeycardSettings({ toast, snap }: { toast: (m: string) => void; snap: any }) {
  const [use, setUse] = useState(false);
  const [pairing, setPairing] = useState("");
  const [showAdv, setShowAdv] = useState(false);
  useEffect(() => { getKeycardPrefs().then((p) => { setUse(p.useForNewForms); setPairing(p.pairing); }).catch(() => {}); }, []);
  const cardForms = Object.values(snap.state.forms).filter((f: any) => f.mine && f.keycard).length;
  return (
    <>
      <View style={{ marginTop: 18 }}><Label>KEYCARD</Label></View>
      <View style={[st.card, st.cardHead]}>
        <View style={{ flex: 1, paddingRight: 12 }}>
          <Text style={{ color: C.text, fontWeight: "600" }}>Seal new forms with my Keycard</Text>
          <Text style={st.muted}>Each form's key is exported from your card's encryption keys (one tap when publishing). {cardForms ? `${plural(cardForms, "form uses", "forms use")} a Keycard key on this phone.` : ""}</Text>
        </View>
        <Switch value={use} onValueChange={async (v) => { setUse(v); await setKeycardPrefs({ useForNewForms: v }); }} trackColor={{ true: C.primary, false: C.border }} thumbColor="#fff" />
      </View>
      <Pressable onPress={() => setShowAdv((x) => !x)}><Text style={[st.muted, { marginTop: 8 }]}>{showAdv ? "▾" : "▸"} Pairing password (older cards)</Text></Pressable>
      {showAdv ? (
        <View style={[st.joinRow, { marginTop: 6 }]}>
          <TextInput value={pairing} onChangeText={setPairing} autoCapitalize="none" secureTextEntry placeholder="KeycardDefaultPairing" placeholderTextColor={C.text3} style={[st.input, { flex: 1 }]} />
          <Btn label="Save" onPress={async () => { await setKeycardPrefs({ pairing: pairing.trim() }); toast("Pairing password saved"); }} />
        </View>
      ) : null}
    </>
  );
}

const st = StyleSheet.create({
  barTrack: { height: 10, borderRadius: 5, backgroundColor: C.surface, marginTop: 4, overflow: "hidden" },
  barFill: { height: 10, borderRadius: 5, backgroundColor: C.primary },
  trow: { flexDirection: "row", alignItems: "center", minHeight: 40 },
  th: { color: C.text3, fontSize: 11, fontWeight: "700", paddingHorizontal: 8, paddingVertical: 10, backgroundColor: C.surface },
  td: { color: C.text, fontSize: 13, paddingHorizontal: 8, paddingVertical: 8 },
  scaleBtn: { minWidth: 40, height: 40, borderRadius: 8, borderWidth: 1, borderColor: C.border, backgroundColor: C.raised, alignItems: "center", justifyContent: "center", paddingHorizontal: 6 },
  numChip: { minWidth: 30, height: 26, borderRadius: 7, borderWidth: 1, borderColor: C.border, backgroundColor: C.raised, alignItems: "center", justifyContent: "center", marginRight: 4, paddingHorizontal: 4 },
  sheetWrap: { position: "absolute", left: 0, right: 0, top: 0, bottom: 0, backgroundColor: "rgba(0,0,0,0.6)", justifyContent: "flex-end" },
  sheet: { backgroundColor: C.surface, borderTopLeftRadius: 20, borderTopRightRadius: 20, borderWidth: 1, borderColor: C.border, padding: 20, paddingBottom: 28 },
  fill: { flex: 1, backgroundColor: C.bg },
  center: { alignItems: "center", justifyContent: "center" },
  pad: { padding: 18 },
  topbar: { flexDirection: "row", alignItems: "center", paddingHorizontal: 18, paddingVertical: 14 },
  brand: { color: C.text, fontSize: 18, fontWeight: "700" },
  brandSub: { color: C.text3, fontSize: 11 },
  idPill: { flexDirection: "row", alignItems: "center", borderWidth: 1, borderColor: C.border, borderRadius: 999, paddingHorizontal: 10, paddingVertical: 6 },
  idPillT: { color: C.text2, fontFamily: MONO, fontSize: 11 },
  dot: { width: 8, height: 8, borderRadius: 4, marginRight: 6 },
  header: { flexDirection: "row", alignItems: "center", paddingHorizontal: 12, paddingVertical: 10, borderBottomWidth: 1, borderBottomColor: C.borderSubtle, minHeight: 56 },
  back: { color: C.text, fontSize: 32, lineHeight: 34, paddingHorizontal: 8 },
  headerT: { color: C.text, fontSize: 17, fontWeight: "700", marginLeft: 4, flexShrink: 1 },
  h1: { color: C.text, fontSize: 26, fontWeight: "800", lineHeight: 32 },
  h2: { color: C.text2, fontSize: 18, fontWeight: "600" },
  label: { color: C.text3, fontSize: 11, fontWeight: "700", letterSpacing: 1, marginBottom: 8 },
  muted: { color: C.text3, fontSize: 13, lineHeight: 19 },
  meta: { color: C.text3, fontSize: 12, marginTop: 8 },
  desc: { color: C.text2, fontSize: 15, lineHeight: 22, marginTop: 10 },
  input: { backgroundColor: C.raised, borderWidth: 1, borderColor: C.border, borderRadius: 10, color: C.text, paddingHorizontal: 12, paddingVertical: 10, fontSize: 15 },
  joinRow: { flexDirection: "row", gap: 8, alignItems: "center" },
  btn: { backgroundColor: C.raised, borderWidth: 1, borderColor: C.border, borderRadius: 10, paddingHorizontal: 14, paddingVertical: 10, alignItems: "center", justifyContent: "center" },
  btnPrimary: { backgroundColor: C.primary, borderColor: C.primary },
  btnDanger: { borderColor: C.err, backgroundColor: "transparent" },
  btnT: { color: C.text, fontWeight: "700", fontSize: 14 },
  badges: { flexDirection: "row", flexWrap: "wrap", gap: 6, marginTop: 10 },
  badge: { borderRadius: 999, paddingHorizontal: 9, paddingVertical: 3 },
  badgeT: { fontSize: 11, fontWeight: "700" },
  row: { flexDirection: "row", alignItems: "center", gap: 12, paddingVertical: 10, paddingHorizontal: 8, borderRadius: 10 },
  rowT: { color: C.text, fontSize: 15, fontWeight: "600" },
  rowS: { color: C.text3, fontSize: 12, marginTop: 1 },
  glyph: { width: 36, height: 36, borderRadius: 9, backgroundColor: C.primarySubtle, alignItems: "center", justifyContent: "center" },
  empty: { marginTop: 36, alignItems: "center", paddingHorizontal: 18 },
  emptyT: { color: C.text2, fontSize: 17, fontWeight: "600", textAlign: "center" },
  emptyS: { color: C.text3, fontSize: 13, lineHeight: 19, textAlign: "center", marginTop: 8 },
  fab: { position: "absolute", right: 18, bottom: 18, backgroundColor: C.primary, borderRadius: 16, paddingHorizontal: 20, paddingVertical: 15, elevation: 6 },
  fabT: { color: "#fff", fontWeight: "800", fontSize: 15 },
  stats: { flexDirection: "row", gap: 8 },
  stat: { flex: 1, backgroundColor: C.raised, borderRadius: 12, paddingVertical: 14, alignItems: "center" },
  statN: { fontSize: 26, fontWeight: "800" },
  statL: { color: C.text3, fontSize: 11, marginTop: 2 },
  card: { backgroundColor: C.raised, borderWidth: 1, borderColor: C.borderSubtle, borderRadius: 12, padding: 14, marginTop: 10 },
  cardHead: { flexDirection: "row", alignItems: "center", flexWrap: "wrap", gap: 6 },
  addr: { color: C.text2, fontFamily: MONO, fontSize: 12 },
  time: { color: C.text3, fontSize: 11 },
  qSmall: { color: C.text3, fontSize: 12 },
  answer: { color: C.text, fontSize: 15, marginTop: 2 },
  q: { color: C.text, fontSize: 15, fontWeight: "700", marginBottom: 8 },
  opt: { flexDirection: "row", alignItems: "center", gap: 12, borderWidth: 1, borderColor: C.border, backgroundColor: C.raised, borderRadius: 10, padding: 13, marginTop: 6 },
  optT: { color: C.text, fontSize: 15, flex: 1 },
  tick: { width: 18, height: 18, borderWidth: 2, alignItems: "center", justifyContent: "center" },
  tickIn: { width: 9, height: 9, backgroundColor: C.primary },
  banner: { borderWidth: 1, borderRadius: 12, padding: 13, marginTop: 4 },
  privacy: { flexDirection: "row", gap: 10, backgroundColor: "#141c18", borderColor: "#24392d", borderWidth: 1, borderRadius: 12, padding: 13, marginTop: 22 },
  privacyT: { color: C.ok, fontSize: 12, lineHeight: 18, flex: 1 },
  chips: { flexDirection: "row", flexWrap: "wrap", gap: 6, marginTop: 10 },
  chip: { borderWidth: 1, borderColor: C.border, borderRadius: 999, paddingHorizontal: 11, paddingVertical: 6 },
  chipOn: { borderColor: C.primary, backgroundColor: C.primarySubtle },
  chipT: { color: C.text2, fontSize: 12 },
  qr: { backgroundColor: "#fff", padding: 16, borderRadius: 16, marginTop: 8 },
  link: { color: C.text2, fontFamily: MONO, fontSize: 12, marginTop: 16, textAlign: "center" },
  csv: { color: C.text, fontFamily: MONO, fontSize: 12, lineHeight: 18 },
  scanFrame: { position: "absolute", top: "25%", left: "15%", right: "15%", aspectRatio: 1, borderWidth: 3, borderColor: C.primary, borderRadius: 20 },
  kv: { flexDirection: "row", justifyContent: "space-between", paddingVertical: 5 },
  kvK: { color: C.text3, fontSize: 13 },
  kvV: { color: C.text2, fontSize: 13, fontFamily: MONO, maxWidth: "62%" },
  toast: { position: "absolute", left: 24, right: 24, bottom: 96, backgroundColor: C.raised, borderColor: C.border, borderWidth: 1, borderRadius: 14, padding: 14 },
  toastT: { color: C.text, textAlign: "center", fontSize: 14 },
});
