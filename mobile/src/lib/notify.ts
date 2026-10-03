// "New answers" / "the creator replied" notifications (Android). Local only - there is no
// push server and no Google push stack: while the app process is alive in the background
// (it often is, kept up by the Loam connection) it checks its own synced state and posts
// one notification per form. Only the form title and a count are shown, never answers.
// Native side: plugins/withLocalNotify.js + native/localnotify (replaces expo-notifications,
// which bundled Firebase Cloud Messaging).
import { AppState, NativeModules, PermissionsAndroid, Platform } from "react-native";
import * as SecureStore from "expo-secure-store";
import { client } from "./whisperbox";

const Native: any = NativeModules.WhisperboxLocalNotify;
const CHANNEL = "answers";
let notified: Record<string, number> = {};
let replied: Record<string, number> = {};   // replies / scores to MY answers already seen
let timer: ReturnType<typeof setInterval> | null = null;

export async function notificationsEnabled(): Promise<boolean> {
  try { return (await SecureStore.getItemAsync("wb-notify")) !== "0"; } catch { return true; }
}
export async function setNotificationsEnabled(on: boolean) {
  await SecureStore.setItemAsync("wb-notify", on ? "1" : "0");
  if (on) await ensurePermission();
}
/** Ask once (Android 13+ needs it); called when the user first publishes a form. */
export async function ensurePermission(): Promise<boolean> {
  if (Platform.OS !== "android" || !Native) return false;
  try {
    await Native.createChannel(CHANNEL, "New answers");
    if (typeof Platform.Version === "number" && Platform.Version >= 33) {
      const p = (PermissionsAndroid.PERMISSIONS as any).POST_NOTIFICATIONS || "android.permission.POST_NOTIFICATIONS";
      if (await PermissionsAndroid.check(p)) return true;
      return (await PermissionsAndroid.request(p)) === PermissionsAndroid.RESULTS.GRANTED;
    }
    return !!(await Native.areEnabled());
  } catch { return false; }
}

const link = (f: any) => `whisperbox://form?id=${encodeURIComponent(f.id)}&by=${encodeURIComponent(f.creator || "")}`;
function post(f: any, tag: string, body: string) {
  if (!Native) return;
  Native.show(CHANNEL, tag, f.title || "WhisperBox", body, link(f)).catch(() => {});
}

function check() {
  let snap: any;
  try { snap = client.snapshot(); } catch { return; }
  const forms = snap?.state?.forms || {};
  const active = AppState.currentState === "active";
  for (const f of Object.values<any>(forms)) {
    if (f.mySubmitted && !f.hidden) {   // a private reply / quiz score from the creator
      const n = (f.myReplies || []).length;
      const before = replied[f.id];
      replied[f.id] = n;
      if (before !== undefined && n > before && !active)
        post(f, "reply:" + f.id, f.myReplies[n - 1]?.kind === "score" ? "Your score is in - tap to see it" : "The creator replied to your answer - tap to read");
    }
    if (!(f.mine || f.coOwner) || f.hidden) continue;
    const n = f.newResponses || 0;
    const before = notified[f.id] ?? 0;
    if (active || n <= before) { notified[f.id] = n; continue; }   // visible on screen, or nothing new
    notified[f.id] = n;
    post(f, "answers:" + f.id, `${n} new ${n === 1 ? "answer" : "answers"} - tap to open`);
  }
}

/** Start watching (after boot). Taps open the form through the app's whisperbox:// link
 *  handling; `_onOpen` is kept for the call site's signature. */
export async function startAnswerNotifications(_onOpen?: (formId: string) => void) {
  if (timer || Platform.OS !== "android" || !Native) return;
  await Native.createChannel(CHANNEL, "New answers").catch(() => {});
  if (!(await notificationsEnabled())) return;
  check();
  timer = setInterval(() => { notificationsEnabled().then((on) => { if (on) check(); }).catch(() => {}); }, 15000);
}
