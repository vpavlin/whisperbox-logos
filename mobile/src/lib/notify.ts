// "New answers" notifications (Android). Best effort, local only - no push server exists:
// while the app process is alive in the background (it often is, kept up by the Loam
// connection), new answers to your forms raise one notification per form. Nothing about
// the answers themselves is shown - only the form title and how many came in.
import { AppState, Platform } from "react-native";
import * as Notifications from "expo-notifications";
import * as SecureStore from "expo-secure-store";
import { client } from "./whisperbox";

let notified: Record<string, number> = {};
let replied: Record<string, number> = {};   // replies / scores to MY answers already seen
let timer: ReturnType<typeof setInterval> | null = null;
let openForm: ((formId: string) => void) | null = null;

Notifications.setNotificationHandler({
  handleNotification: async () => ({ shouldShowBanner: false, shouldShowList: true, shouldPlaySound: false, shouldSetBadge: false } as any),
});

export async function notificationsEnabled(): Promise<boolean> {
  try { return (await SecureStore.getItemAsync("wb-notify")) !== "0"; } catch { return true; }
}
export async function setNotificationsEnabled(on: boolean) {
  await SecureStore.setItemAsync("wb-notify", on ? "1" : "0");
  if (on) await ensurePermission();
}
/** Ask once (Android 13+ needs it); called when the user first publishes a form. */
export async function ensurePermission(): Promise<boolean> {
  try {
    if (Platform.OS === "android") await Notifications.setNotificationChannelAsync("answers", { name: "New answers", importance: Notifications.AndroidImportance.DEFAULT });
    const cur = await Notifications.getPermissionsAsync();
    if (cur.granted) return true;
    if (!cur.canAskAgain) return false;
    return (await Notifications.requestPermissionsAsync()).granted;
  } catch { return false; }
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
      if (before !== undefined && n > before && !active) {
        const last = f.myReplies[n - 1];
        Notifications.scheduleNotificationAsync({
          content: { title: f.title || "WhisperBox", body: last?.kind === "score" ? "Your score is in - tap to see it" : "The creator replied to your answer - tap to read", data: { formId: f.id } },
          trigger: Platform.OS === "android" ? ({ channelId: "answers" } as any) : null,
        }).catch(() => {});
      }
    }
    if (!(f.mine || f.coOwner) || f.hidden) continue;
    const n = f.newResponses || 0;
    const before = notified[f.id] ?? 0;
    if (active || n <= before) { notified[f.id] = n; continue; }   // visible on screen, or nothing new
    notified[f.id] = n;
    Notifications.scheduleNotificationAsync({
      content: { title: f.title || "WhisperBox", body: `${n} new ${n === 1 ? "answer" : "answers"} - tap to open`, data: { formId: f.id } },
      trigger: Platform.OS === "android" ? ({ channelId: "answers" } as any) : null,
    }).catch(() => {});
  }
}

/** Start watching (after boot). onOpen navigates when a notification is tapped. */
export async function startAnswerNotifications(onOpen: (formId: string) => void) {
  openForm = onOpen;
  if (timer) return;
  Notifications.addNotificationResponseReceivedListener((r) => {
    const id = r?.notification?.request?.content?.data?.formId;
    if (typeof id === "string" && openForm) openForm(id);
  });
  if (!(await notificationsEnabled())) return;
  check();
  timer = setInterval(() => { notificationsEnabled().then((on) => { if (on) check(); }).catch(() => {}); }, 15000);
}
