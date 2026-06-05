// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
//! "Cascade Hands" — the computer-use agents.
//!
//! EVERY installed agent can work on-screen at once, each with ITS OWN labeled
//! cursor. 5 installed agents → 5 cursors flying around doing their tasks while
//! the employee keeps working; their real pointer is never seized. Per agent the
//! loop is: screenshot -> Claude (vision) -> next action -> fly that agent's
//! cursor + narrate -> act via synthesized events (cascade_input), snapping the
//! user's pointer back. Actual input is serialized through one lock so the
//! agents don't fight over the keyboard/mouse, but their cursors move in
//! parallel. A stacked floating panel shows each agent with a STOP + per-step
//! approval on supervised runs.

#![cfg(target_os = "macos")]

use crate::cascade_input;
use crate::cascade_llm::{call_anthropic_vision, extract_json_str, MODEL_SONNET};
use base64::{engine::general_purpose::STANDARD, Engine};
use cascade_schema::{
    get_agent_spec, insert_agent_action, insert_agent_run, list_deployed_specs, open,
    AgentActionInput, AgentRunInput,
};
use serde::{Deserialize, Serialize};
use specta::Type;
use std::collections::HashMap;
use std::io::Cursor;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::Duration;
use tauri::{Emitter, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};
use tauri_nspanel::WebviewWindowExt;

/// Promote an overlay window to a non-activating panel that floats above
/// everything (incl. other apps + fullscreen) WITHOUT stealing focus and —
/// critically — WITHOUT hiding when Cascade loses focus. This is the whole
/// point: the box must stay visible over your other apps while you work
/// elsewhere. Mirrors the app's proven shortcut-reminder panel setup.
/// `click_through` true for the cursor layer.
fn promote_overlay(win: &WebviewWindow, click_through: bool) {
    let _ = win.show();
    if click_through {
        let _ = win.set_ignore_cursor_events(true);
    }
    if let Ok(panel) = win.to_panel() {
        use objc::{msg_send, sel, sel_impl};
        use tauri_nspanel::cocoa::appkit::NSWindowCollectionBehavior;

        panel.set_level(1001); // above CGShieldingWindowLevel
        panel.set_style_mask(128); // NSWindowStyleMaskNonactivatingPanel
        // KEY: NSPanel hides on app deactivation by default — that's why the box
        // vanished the instant you switched to another app. Keep it visible.
        panel.set_hides_on_deactivate(false);
        // EXCLUDE the box from screen capture (NSWindowSharingNone = 0) so the
        // agent's screenshots don't contain the box itself (no infinite mirror).
        let _: () = unsafe { msg_send![&*panel, setSharingType: 0_u64] };
        // Show on every Space, ignore window cycling, allow over fullscreen apps.
        panel.set_collection_behaviour(
            NSWindowCollectionBehavior::NSWindowCollectionBehaviorCanJoinAllSpaces
                | NSWindowCollectionBehavior::NSWindowCollectionBehaviorIgnoresCycle
                | NSWindowCollectionBehavior::NSWindowCollectionBehaviorFullScreenAuxiliary,
        );
        panel.order_front_regardless();
    }
}

const MAX_STEPS: i64 = 24;
const MAX_TRANSIENT_RETRIES: u32 = 3;
const RETRY_DELAY_SECS: u64 = 10;
const STALL_WARN_AFTER: u32 = 2;
const STALL_FAIL_AFTER: u32 = 4;
const CURSOR_WINDOW: &str = "cascade-cursor";
const HANDS_WINDOW: &str = "cascade-hands";
const EVT_CURSOR: &str = "cascade-hands-cursor";
const EVT_STATUS: &str = "cascade-hands-status";
const EVT_FRAME: &str = "cascade-hands-frame";

/// Per-agent control block.
#[derive(Default)]
struct AgentCtl {
    running: bool,
    stop: bool,
    paused: bool,
    approval: Option<bool>,
    awaiting: bool,
}

static AGENTS: LazyLock<Mutex<HashMap<i64, AgentCtl>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Per-agent start URL, resolved from the Rewind (the site the employee actually
/// uses for this work). The run loop opens the agent's browser here.
static START_URLS: LazyLock<Mutex<HashMap<i64, String>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn set_start_url(spec_id: i64, url: String) {
    if let Ok(mut m) = START_URLS.lock() {
        m.insert(spec_id, url);
    }
}
fn get_start_url(spec_id: i64) -> Option<String> {
    START_URLS.lock().ok().and_then(|m| m.get(&spec_id).cloned())
}

/// The ONLY two ways an agent does its work, chosen by the user in Settings and
/// applied to every agent. There is no third path.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum RunTarget {
    /// Isolated sandbox browser, shown in the floating box. Web apps only; the
    /// user keeps working uninterrupted while it runs. (Default.)
    Sandbox,
    /// The user's REAL screen — synthesized mouse/keyboard via `cascade_input`,
    /// so the agent can drive ANY app, not just websites.
    Screen,
}

impl RunTarget {
    fn from_opt(s: Option<&str>) -> RunTarget {
        match s {
            Some("screen") => RunTarget::Screen,
            _ => RunTarget::Sandbox,
        }
    }
}

/// Only one agent drives the real input at a time — their cursors still move in
/// parallel, but clicks/keystrokes are serialized so they don't collide.
static INPUT_LOCK: LazyLock<tokio::sync::Mutex<()>> =
    LazyLock::new(|| tokio::sync::Mutex::new(()));

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ComputerAction {
    #[serde(default)]
    narration: String,
    action: String,
    #[serde(default)]
    x: f64,
    #[serde(default)]
    y: f64,
    #[serde(default)]
    text: String,
    #[serde(default)]
    app: String,
    #[serde(default)]
    key: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct FrameEvent {
    image_base64: String,
    img_w: f64,
    img_h: f64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct CursorEvent {
    spec_id: i64,
    name: String,
    x: f64,
    y: f64,
    clicking: bool,
    visible: bool,
    hue: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct StatusEvent {
    spec_id: i64,
    name: String,
    goal: String,
    narration: String,
    step: i64,
    supervised: bool,
    awaiting_approval: bool,
    done: bool,
    error: Option<String>,
    hue: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ComputerAgentStatus {
    pub spec_id: i64,
    pub awaiting_approval: bool,
}

// ─── per-agent state helpers ────────────────────────────────────────

fn try_begin(spec_id: i64) -> bool {
    let mut m = AGENTS.lock().unwrap();
    let ctl = m.entry(spec_id).or_default();
    if ctl.running {
        return false;
    }
    ctl.running = true;
    ctl.stop = false;
    ctl.approval = None;
    ctl.awaiting = false;
    true
}

fn end_agent(spec_id: i64) -> usize {
    let mut m = AGENTS.lock().unwrap();
    m.remove(&spec_id);
    m.values().filter(|c| c.running).count()
}

fn set_stop(spec_id: i64) {
    if let Ok(mut m) = AGENTS.lock() {
        if let Some(c) = m.get_mut(&spec_id) {
            c.stop = true;
        }
    }
}
fn stop_requested(spec_id: i64) -> bool {
    AGENTS.lock().map(|m| m.get(&spec_id).map(|c| c.stop).unwrap_or(true)).unwrap_or(true)
}
fn set_approval(spec_id: i64, v: bool) {
    if let Ok(mut m) = AGENTS.lock() {
        if let Some(c) = m.get_mut(&spec_id) {
            c.approval = Some(v);
            c.awaiting = false;
        }
    }
}
fn is_paused(spec_id: i64) -> bool {
    AGENTS.lock().map(|m| m.get(&spec_id).map(|c| c.paused).unwrap_or(false)).unwrap_or(false)
}
fn set_paused(spec_id: i64, v: bool) {
    if let Ok(mut m) = AGENTS.lock() {
        if let Some(c) = m.get_mut(&spec_id) {
            c.paused = v;
        }
    }
}

async fn await_approval(spec_id: i64) -> bool {
    if let Ok(mut m) = AGENTS.lock() {
        if let Some(c) = m.get_mut(&spec_id) {
            c.awaiting = true;
            c.approval = None;
        }
    }
    loop {
        if stop_requested(spec_id) {
            return false;
        }
        let decided = AGENTS.lock().ok().and_then(|m| m.get(&spec_id).and_then(|c| c.approval));
        if let Some(v) = decided {
            return v;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

// ─── overlay windows ────────────────────────────────────────────────

fn primary_logical_size(app: &tauri::AppHandle) -> (f64, f64) {
    if let Ok(Some(m)) = app.primary_monitor() {
        let s = m.size();
        let sf = m.scale_factor();
        if sf > 0.0 {
            return ((s.width as f64) / sf, (s.height as f64) / sf);
        }
    }
    (1440.0, 900.0)
}

/// Screen mode: show ONLY the click-through agent-cursor overlay on the user's
/// REAL screen — NO floating box. The agent's own pointer (labeled + colored, one
/// per agent) flies to where it's about to act so the user can watch it work.
/// `promote_overlay(.., true)` makes it click-through and `setSharingType:0` keeps
/// it out of the agent's own screenshots (so it never sees/clicks its own cursor).
/// Covers the primary display in logical points, matching the screenshot coords
/// the vision model returns, so the pointer lands exactly where the agent acts.
fn ensure_cursor_overlay(app: &tauri::AppHandle) {
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        let (w, h) = primary_logical_size(&app2);
        if app2.get_webview_window(CURSOR_WINDOW).is_none() {
            if let Ok(win) = WebviewWindowBuilder::new(
                &app2,
                CURSOR_WINDOW,
                WebviewUrl::App("hands-cursor".into()),
            )
            .title("")
            .inner_size(w, h)
            .position(0.0, 0.0)
            .always_on_top(true)
            .decorations(false)
            .skip_taskbar(true)
            .focused(false)
            .transparent(true)
            .shadow(false)
            .resizable(false)
            .visible(false)
            .build()
            {
                promote_overlay(&win, true);
            }
        }
        if let Some(win) = app2.get_webview_window(CURSOR_WINDOW) {
            let _ = win.show();
        }
    });
}

fn hide_overlays(app: &tauri::AppHandle) {
    if let Some(w) = app.get_webview_window(CURSOR_WINDOW) {
        let _ = w.hide();
    }
    if let Some(w) = app.get_webview_window(HANDS_WINDOW) {
        let _ = w.hide();
    }
}

fn emit_cursor(app: &tauri::AppHandle, ev: CursorEvent) {
    let _ = app.emit(EVT_CURSOR, ev);
}
fn emit_status(app: &tauri::AppHandle, ev: StatusEvent) {
    let _ = app.emit(EVT_STATUS, ev);
}

// ─── Floating box for BACKGROUND runs (no cursor, just narration) ───
//
// Lets the non-computer-use runtime (cascade_agents::run_agent) surface the
// same Cascade floating box so the employee can see the agent doing the work
// in every mode. Reference-counted so the box hides only when nothing's working.

static BOX_USERS: AtomicI64 = AtomicI64::new(0);

fn ensure_box_window(app: &tauri::AppHandle) {
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        let (w, _h) = primary_logical_size(&app2);
        if app2.get_webview_window(HANDS_WINDOW).is_none() {
            if let Ok(win) = WebviewWindowBuilder::new(&app2, HANDS_WINDOW, WebviewUrl::App("hands-box".into()))
                .title("")
                .inner_size(500.0, 470.0)
                .min_inner_size(280.0, 90.0)
                .position((w - 520.0).max(20.0), 44.0)
                .always_on_top(true)
                .decorations(false)
                .skip_taskbar(true)
                .focused(false)
                .transparent(true)
                .shadow(false)
                .resizable(true)
                .visible(false)
                .build()
            {
                promote_overlay(&win, false);
            }
        } else if let Some(win) = app2.get_webview_window(HANDS_WINDOW) {
            let _ = win.show();
        }
    });
}

fn box_status(spec_id: i64, name: &str, goal: &str, narration: &str, step: i64, done: bool) -> StatusEvent {
    StatusEvent {
        spec_id,
        name: name.to_string(),
        goal: goal.to_string(),
        narration: narration.to_string(),
        step,
        supervised: false,
        awaiting_approval: false,
        done,
        error: None,
        hue: hue_for(spec_id),
    }
}

/// A background agent run is starting — show the box. The first status is
/// emitted after a short delay so the freshly-created webview has registered
/// its event listener (otherwise the opening event is dropped and the box looks
/// empty / never appears).
pub fn box_begin(app: &tauri::AppHandle, spec_id: i64, name: &str, goal: &str) {
    BOX_USERS.fetch_add(1, Ordering::SeqCst);
    ensure_box_window(app);
    let app2 = app.clone();
    let name = name.to_string();
    let goal = goal.to_string();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_millis(750)).await;
        let _ = app2.emit(EVT_STATUS, box_status(spec_id, &name, &goal, "Working…", 0, false));
    });
}

/// Narrate one step of a background run in the box.
pub fn box_step(app: &tauri::AppHandle, spec_id: i64, name: &str, goal: &str, narration: &str, step: i64) {
    emit_status(app, box_status(spec_id, name, goal, narration, step, false));
}

/// Surface the REAL produced deliverable (from a headless run) as a result card
/// in the box. Emitted on its own channel so it doesn't disturb the sandbox's
/// frame/cursor/status stream. `open_ref` is "app:Notes", "url:…", or "path:…".
pub fn box_result(
    app: &tauri::AppHandle,
    spec_id: i64,
    _name: &str,
    app_label: &str,
    title: &str,
    content: &str,
    open_ref: Option<&str>,
) {
    #[derive(Clone, Serialize)]
    #[serde(rename_all = "camelCase")]
    struct ResultEvent {
        spec_id: i64,
        app: String,
        title: String,
        content: String,
        open: Option<String>,
    }
    let _ = app.emit(
        "cascade-hands-result",
        ResultEvent {
            spec_id,
            app: app_label.to_string(),
            title: title.to_string(),
            content: content.chars().take(1600).collect(),
            open: open_ref.map(|s| s.to_string()),
        },
    );
}

/// A background run finished — emit done + hide the box when nothing's working.
pub fn box_end(app: &tauri::AppHandle, spec_id: i64, name: &str, goal: &str, summary: &str) {
    emit_status(app, box_status(spec_id, name, goal, summary, -1, true));
    let remaining = BOX_USERS.fetch_sub(1, Ordering::SeqCst) - 1;
    let computer_use_active = AGENTS.lock().map(|m| m.values().filter(|c| c.running).count()).unwrap_or(0);
    if remaining <= 0 && computer_use_active == 0 {
        let app2 = app.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(Duration::from_millis(4000)).await;
            let cu = AGENTS.lock().map(|m| m.values().filter(|c| c.running).count()).unwrap_or(0);
            if BOX_USERS.load(Ordering::SeqCst) <= 0 && cu == 0 {
                if let Some(w) = app2.get_webview_window(HANDS_WINDOW) {
                    let _ = w.hide();
                }
            }
        });
    }
}

fn capture_logical_screenshot(app: &tauri::AppHandle) -> Result<(String, f64, f64), String> {
    let (lw, lh) = primary_logical_size(app);
    let path = std::env::temp_dir().join("cascade-hands.png");
    let out = std::process::Command::new("screencapture")
        .args(["-x", "-t", "png", path.to_string_lossy().as_ref()])
        .output()
        .map_err(|e| format!("screencapture failed: {e}"))?;
    if !out.status.success() {
        return Err("screencapture returned an error".to_string());
    }
    let bytes = std::fs::read(&path).map_err(|e| format!("read screenshot: {e}"))?;
    let img = image::load_from_memory(&bytes).map_err(|e| format!("decode screenshot: {e}"))?;
    let resized = img.resize_exact(lw as u32, lh as u32, image::imageops::FilterType::Triangle);
    let mut buf = Vec::new();
    resized
        .write_to(&mut Cursor::new(&mut buf), image::ImageFormat::Png)
        .map_err(|e| format!("encode screenshot: {e}"))?;
    Ok((STANDARD.encode(&buf), lw, lh))
}

fn frame_fingerprint(image_base64: &str) -> Option<u64> {
    let bytes = STANDARD.decode(image_base64).ok()?;
    let img = image::load_from_memory(&bytes).ok()?.to_luma8();
    let small = image::imageops::resize(&img, 8, 8, image::imageops::FilterType::Triangle);
    let pixels: Vec<u8> = small.pixels().map(|p| p.0[0]).collect();
    let avg = pixels.iter().map(|v| *v as u32).sum::<u32>() / pixels.len().max(1) as u32;
    let mut hash = 0u64;
    for (idx, value) in pixels.iter().enumerate() {
        if *value as u32 >= avg {
            hash |= 1u64 << idx;
        }
    }
    Some(hash)
}

fn frames_look_same(before: &str, after: &str) -> bool {
    match (frame_fingerprint(before), frame_fingerprint(after)) {
        (Some(a), Some(b)) => (a ^ b).count_ones() <= 3,
        _ => before == after,
    }
}

fn computer_system_prompt(name: &str, w: f64, h: f64, target: RunTarget) -> String {
    if target == RunTarget::Screen {
        return computer_system_prompt_screen(name, w, h);
    }
    format!(
        "You are \"{name}\", a careful Cascade agent operating YOUR OWN web browser (a {w:.0}x{h:.0} \
viewport, top-left origin). This is an isolated browser — NOT the user's screen — so the user keeps \
working while you do the task here. You're given a screenshot of your browser and a GOAL.\n\n\
IMPORTANT — you have ALREADY been opened on the correct website for this task and you are SIGNED IN. \
Accomplish the goal by working WITHIN this site: CLICK links/menus/tabs, SCROLL to read, and read what's \
on screen. Do NOT navigate to some other tool's home page, and do NOT keep returning to the landing/home \
page — that just loops. Only use `navigate` if you genuinely need a different URL on this same site. Make \
real forward progress every step toward the goal.\n\n\
PRIMARY PLAN — if the GOAL includes a \"STEPS THE EMPLOYEE ACTUALLY TOOK\" list, that is the real path for \
this task: reproduce that exact sequence of clicks/navigation here, in order, adapting only to what the \
current screen actually shows. Find the on-screen element that matches each recorded step and click it; \
don't re-derive the route from scratch or explore elsewhere. If a step's target isn't visible yet, scroll \
or open the menu that would reveal it, just as the employee did.\n\n\
Coordinates: (x,y) are EXACT pixels in the screenshot you were given (its top-left is 0,0). To click a \
thing, give the pixel at its CENTER. After each action you'll get a fresh screenshot — verify it changed; \
if nothing changed, your last click missed, so pick a clearer target or scroll.\n\n\
Be conservative; never take destructive or irreversible actions (deleting, submitting, sending, paying, \
changing account/security settings, posting publicly).\n\n\
Actions:\n\
- click / double_click: click at (x,y)\n\
- type: type `text` into the focused field\n\
- key: press a key (`key`, e.g. \"Enter\")\n\
- scroll: scroll the page (put pixels in `y`, negative = up)\n\
- navigate: go to a URL on THIS site (full https URL in `text`) — use sparingly. Never navigate from a course code, page title, or free-text guess.\n\
- NEVER navigate to API, JSON, feed, export, or raw-data endpoints to fetch information. Use the visible page UI only.\n\
- record: save a finding into your notes (`text`) WITHOUT touching the page. Use this on read-only sites whenever you learn something important.\n\
- wait: let the page load\n\
- done: the goal is complete. Before `done`, make sure every important finding is already captured with `record`. You may put a 1-2 sentence wrap-up in `text`.\n\n\
Return ONLY JSON: {{\"narration\":\"short present-tense\",\"action\":\"click|double_click|type|key|scroll|navigate|record|wait|done\",\
\"x\":0,\"y\":0,\"text\":\"\",\"app\":\"\",\"key\":\"\"}}"
    )
}

fn is_committing(action: &str) -> bool {
    matches!(action, "click" | "double_click" | "type" | "key" | "navigate" | "open_app")
}

/// Real-screen variant: the agent drives the USER'S actual screen, so it can use
/// any application — not just a website.
fn computer_system_prompt_screen(name: &str, w: f64, h: f64) -> String {
    format!(
        "You are \"{name}\", a careful Cascade agent operating the USER'S REAL SCREEN (a {w:.0}x{h:.0} \
desktop, top-left origin). Your clicks and keystrokes move the user's actual mouse and keyboard, so act \
deliberately. You're given a screenshot of the whole screen and a GOAL.\n\n\
You can use ANY application to accomplish the goal: switch or launch apps with `open_app`, then click \
menus/buttons and type, exactly as a person would. Read what's on screen before each move and make real \
forward progress every step.\n\n\
PRIMARY PLAN — if the GOAL includes a \"STEPS THE EMPLOYEE ACTUALLY TOOK\" list, that is the real path for \
this task: reproduce that exact sequence of app switches / clicks / typing here, in order, adapting only to \
what the current screen actually shows. Find the on-screen element that matches each recorded step and \
click it; don't re-derive the route from scratch.\n\n\
Coordinates: (x,y) are EXACT pixels in the screenshot you were given (its top-left is 0,0). To click a \
thing, give the pixel at its CENTER. After each action you'll get a fresh screenshot — verify it changed; \
if nothing changed, your last click missed, so pick a clearer target or scroll.\n\n\
Be conservative; never take destructive or irreversible actions (deleting, submitting, sending, paying, \
changing account/security settings, posting publicly).\n\n\
Actions:\n\
- click / double_click: click at (x,y)\n\
- type: type `text` into the focused field\n\
- key: press a key (`key`, e.g. \"Enter\")\n\
- scroll: scroll the page (put pixels in `y`, negative = up)\n\
- open_app: launch or focus an application by name (`app`, e.g. \"Obsidian\")\n\
- navigate: open a URL in the browser (full https URL in `text`)\n\
- record: save a finding into your notes (`text`) WITHOUT touching anything on screen.\n\
- wait: let the screen settle\n\
- done: the goal is complete. Before `done`, make sure every important finding is already captured with \
`record`. You may put a 1-2 sentence wrap-up in `text`.\n\n\
Return ONLY JSON: {{\"narration\":\"short present-tense\",\"action\":\"click|double_click|type|key|scroll|open_app|navigate|record|wait|done\",\
\"x\":0,\"y\":0,\"text\":\"\",\"app\":\"\",\"key\":\"\"}}"
    )
}

/// Open a URL in the user's default browser — the real-screen target's `navigate`.
fn open_url_real(action: &ComputerAction) {
    let raw = if action.text.starts_with("http") {
        action.text.as_str()
    } else if action.app.starts_with("http") {
        action.app.as_str()
    } else {
        return;
    };
    let _ = std::process::Command::new("open").arg(raw).spawn();
}

fn execute_action(action: &ComputerAction) {
    match action.action.as_str() {
        "click" => cascade_input::click(action.x, action.y),
        "double_click" => cascade_input::double_click(action.x, action.y),
        "type" => cascade_input::type_text(&action.text),
        "key" => cascade_input::press_key(&action.key),
        "open_app" => cascade_input::open_app(&action.app),
        "scroll" => cascade_input::scroll(if action.y != 0.0 { action.y } else { 500.0 }),
        "navigate" => open_url_real(action),
        _ => {}
    }
}

fn narrate(a: &ComputerAction) -> String {
    if !a.narration.is_empty() {
        return a.narration.clone();
    }
    match a.action.as_str() {
        "open_app" => format!("Open {}", a.app),
        "click" => format!("Click ({:.0},{:.0})", a.x, a.y),
        "type" => format!("Type \"{}\"", a.text.chars().take(40).collect::<String>()),
        "key" => format!("Press {}", a.key),
        other => other.to_string(),
    }
}

fn goal_headline(goal: &str) -> String {
    goal.lines()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("Do the task this agent was created for")
        .trim()
        .chars()
        .take(140)
        .collect()
}

fn recorded_text(raw: &str) -> String {
    raw.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn build_recorded_digest(
    name: &str,
    goal: &str,
    notes: &[String],
    final_summary: &str,
) -> Option<String> {
    let mut deduped: Vec<String> = Vec::new();
    for note in notes {
        let note = recorded_text(note.trim());
        if note.is_empty() {
            continue;
        }
        if deduped
            .iter()
            .any(|existing| existing.eq_ignore_ascii_case(&note))
        {
            continue;
        }
        deduped.push(note);
    }

    let final_summary = recorded_text(final_summary.trim());
    if deduped.is_empty() && final_summary.is_empty() {
        return None;
    }

    let mut out = format!(
        "# {name}\n\nGoal: {}\nSource: Browser agent run on the site you use for this work.\n",
        goal_headline(goal)
    );

    if !deduped.is_empty() {
        out.push_str("\n## Findings\n");
        for note in deduped {
            out.push_str("- ");
            out.push_str(&note);
            out.push('\n');
        }
    }

    if !final_summary.is_empty() {
        out.push_str("\n## Summary\n");
        out.push_str(&final_summary);
        out.push('\n');
    }

    Some(out.trim().to_string())
}

/// Stable per-agent hue so each cursor/row has a consistent color.
fn hue_for(spec_id: i64) -> i64 {
    ((spec_id.unsigned_abs() % 360) as i64 + 145) % 360
}

async fn record_run_start(
    app: &tauri::AppHandle,
    spec_id: i64,
) -> Option<(cascade_schema::sqlx::sqlite::SqlitePool, i64)> {
    if spec_id <= 0 {
        return None;
    }
    let pool = crate::cascade_agents::cascade_pool(app).await.ok()?;
    let run_id = insert_agent_run(
        &pool,
        &AgentRunInput {
            spec_id,
            mode: "live".to_string(),
            status: "running".to_string(),
            summary: "computer-use run".to_string(),
            steps_json: "[]".to_string(),
            anomalies_json: "[]".to_string(),
            cost_usd: 0.0,
            duration_ms: 0,
        },
    )
    .await
    .ok()?;
    Some((pool, run_id))
}

/// One agent's computer-use loop.
// ════════════════════════════════════════════════════════════════════
// Agent BROWSER sandbox — each agent works in its OWN offscreen browser,
// driven entirely by JS injection (NEVER the user's real screen/cursor/
// keyboard). The box streams this browser so the employee can watch while
// continuing their own work uninterrupted.
// (Phase-2 seam: swap this layer for a cloud VM sandbox for native-app tasks.)
// ════════════════════════════════════════════════════════════════════

const BROWSER_W: f64 = 1280.0;
const BROWSER_H: f64 = 820.0;

fn browser_label(spec_id: i64) -> String {
    format!("cascade-agent-browser-{spec_id}")
}

fn parse_external_url(url: &str) -> Result<tauri::Url, String> {
    let trimmed = url.trim();
    if trimmed.is_empty() {
        return Err("missing Rewind-grounded start URL".to_string());
    }
    let parsed = tauri::Url::parse(trimmed).map_err(|e| format!("invalid start URL `{trimmed}`: {e}"))?;
    match parsed.scheme() {
        "http" | "https" => Ok(parsed),
        other => Err(format!("unsupported start URL scheme `{other}`")),
    }
}

/// Copy the user's existing browser session into the sandbox browser before it
/// opens. This uses cookies only; saved passwords are never read. Sites that
/// keep auth in localStorage/IndexedDB or require WebAuthn still fall back to
/// the visible login window.
async fn hydrate_sandbox_session(app: &tauri::AppHandle, url: &str) -> Result<usize, String> {
    let parsed = parse_external_url(url)?;
    let host = parsed
        .host_str()
        .ok_or_else(|| "sandbox URL has no host".to_string())?
        .to_string();
    let cookies = crate::owned_browser_cookies::cookies_for_host(&host).await;
    if cookies.is_empty() {
        return Err(format!("no browser session cookies found for {host}"));
    }
    let injected = inject_sandbox_cookies_macos(app, cookies).await;
    if injected == 0 {
        Err(format!("browser session cookies for {host} could not be injected"))
    } else {
        eprintln!("[cascade-login] {host}: hydrated sandbox with {injected} browser cookie(s)");
        Ok(injected)
    }
}

async fn inject_sandbox_cookies_macos(
    app: &tauri::AppHandle,
    cookies: Vec<crate::owned_browser_cookies::Cookie>,
) -> usize {
    use cocoa::base::{id, nil};
    use cocoa::foundation::{NSArray, NSDictionary, NSString};
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};

    let (tx, rx) = tokio::sync::oneshot::channel::<usize>();
    let _ = app.run_on_main_thread(move || {
        let mut injected = 0usize;
        unsafe {
            let ds_class = class!(WKWebsiteDataStore);
            let ds: id = msg_send![ds_class, defaultDataStore];
            if ds.is_null() {
                let _ = tx.send(0);
                return;
            }
            let store: id = msg_send![ds, httpCookieStore];
            if store.is_null() {
                let _ = tx.send(0);
                return;
            }

            for c in &cookies {
                let mut keys: Vec<id> = Vec::with_capacity(8);
                let mut vals: Vec<id> = Vec::with_capacity(8);
                let push = |k: &str, v: id, keys: &mut Vec<id>, vals: &mut Vec<id>| {
                    if !v.is_null() {
                        keys.push(NSString::alloc(nil).init_str(k));
                        vals.push(v);
                    }
                };

                push("Name", NSString::alloc(nil).init_str(&c.name), &mut keys, &mut vals);
                push("Value", NSString::alloc(nil).init_str(&c.value), &mut keys, &mut vals);
                push("Domain", NSString::alloc(nil).init_str(&c.domain), &mut keys, &mut vals);
                push(
                    "Path",
                    NSString::alloc(nil).init_str(if c.path.is_empty() { "/" } else { &c.path }),
                    &mut keys,
                    &mut vals,
                );
                if c.secure {
                    push("Secure", NSString::alloc(nil).init_str("TRUE"), &mut keys, &mut vals);
                }
                if c.http_only {
                    push("HttpOnly", NSString::alloc(nil).init_str("TRUE"), &mut keys, &mut vals);
                }
                if let Some(secs) = c.expires_at {
                    let date_class = class!(NSDate);
                    let date: id = msg_send![date_class, dateWithTimeIntervalSince1970: secs as f64];
                    push("Expires", date, &mut keys, &mut vals);
                } else {
                    push("Discard", NSString::alloc(nil).init_str("TRUE"), &mut keys, &mut vals);
                }
                if let Some(same_site) = match c.same_site {
                    0 => Some("None"),
                    1 => Some("Lax"),
                    2 => Some("Strict"),
                    _ => None,
                } {
                    push("SameSite", NSString::alloc(nil).init_str(same_site), &mut keys, &mut vals);
                }
                push("Version", NSString::alloc(nil).init_str("0"), &mut keys, &mut vals);

                let keys_arr = NSArray::arrayWithObjects(nil, &keys);
                let vals_arr = NSArray::arrayWithObjects(nil, &vals);
                let dict: id = NSDictionary::dictionaryWithObjects_forKeys_(nil, vals_arr, keys_arr);
                let cookie_class = class!(NSHTTPCookie);
                let ns_cookie: id = msg_send![cookie_class, cookieWithProperties: dict];
                if ns_cookie.is_null() {
                    continue;
                }
                let _: () = msg_send![store as *mut Object,
                    setCookie: ns_cookie
                    completionHandler: std::ptr::null_mut::<Object>()];
                injected += 1;
            }
        }
        let _ = tx.send(injected);
    });

    let injected = rx.await.unwrap_or(0);
    tokio::time::sleep(Duration::from_millis(50)).await;
    injected
}

/// Latest main-document URL each agent browser has finished loading, recorded by
/// the browser's `on_page_load`. Read right after the sandbox opens to tell
/// whether a hydrated session landed us authenticated or on a login/SSO page.
static AGENT_BROWSER_URL: LazyLock<Mutex<HashMap<i64, String>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn note_agent_browser_url(spec_id: i64, url: &str) {
    if let Ok(mut m) = AGENT_BROWSER_URL.lock() {
        m.insert(spec_id, url.to_string());
    }
}
fn clear_agent_browser_url(spec_id: i64) {
    if let Ok(mut m) = AGENT_BROWSER_URL.lock() {
        m.remove(&spec_id);
    }
}
fn agent_browser_url(spec_id: i64) -> Option<String> {
    AGENT_BROWSER_URL
        .lock()
        .ok()
        .and_then(|m| m.get(&spec_id).cloned())
}

/// True if the agent browser, after loading its start URL with the hydrated
/// cookies, ended up on the target host and NOT on a login/SSO/MFA page — i.e. the
/// reused session actually authenticated us. Conservative: an unknown/blank URL
/// counts as not-authenticated, so we fall back to the visible login.
fn sandbox_landed_authenticated(spec_id: i64, target_host: &str) -> bool {
    let Some(cur) = agent_browser_url(spec_id) else {
        return false;
    };
    let h = host_of(&cur);
    if h.is_empty() {
        return false;
    }
    let on_target = h == target_host
        || h.ends_with(&format!(".{target_host}"))
        || target_host.ends_with(&format!(".{h}"));
    on_target && !looks_like_auth_url(&cur)
}

/// Navigate the agent browser back to `url` — e.g. after a manual sign-in landed
/// fresh session cookies in the shared store — so it reloads authenticated.
fn reload_agent_browser(app: &tauri::AppHandle, spec_id: i64, url: &str) {
    let safe = serde_json::to_string(url).unwrap_or_else(|_| "\"about:blank\"".to_string());
    browser_eval(app, spec_id, &format!("window.location.href={safe};"));
}

/// Create (once) the agent's own browser window. It is VISIBLE and on-screen —
/// macOS does not reliably render a fully off-screen window for `screencapture`,
/// so the box was coming up blank. On-screen it captures reliably AND the user
/// can watch the agent work directly. It never takes focus, so the user keeps
/// working in their own app; the box (a non-activating panel) floats above it.
fn ensure_agent_browser(app: &tauri::AppHandle, spec_id: i64, start_url: &str) -> Result<(), String> {
    let app2 = app.clone();
    let label = browser_label(spec_id);
    let parsed = parse_external_url(start_url)?;
    let _ = app.run_on_main_thread(move || {
        if app2.get_webview_window(&label).is_none() {
            let _ = WebviewWindowBuilder::new(&app2, &label, WebviewUrl::External(parsed))
                .title("Cascade Agent — working")
                .inner_size(BROWSER_W, BROWSER_H)
                .position(48.0, 96.0) // on-screen so it renders + captures reliably
                // decorations(false): NO title bar. A title bar shifts the captured
                // image down ~28px, so the agent's click coords (computed from the
                // screenshot) would miss every element. Without it the capture is the
                // raw 1280x820 viewport, 1:1 with document.elementFromPoint(x,y).
                .decorations(false)
                .skip_taskbar(true)
                .focused(false)
                .visible(true)
                // Record where the page actually lands (reliable main-document URL
                // on macOS) so the login flow can tell whether a hydrated session
                // authenticated us or hit a login wall.
                .on_page_load(move |webview, payload| {
                    if matches!(payload.event(), tauri::webview::PageLoadEvent::Finished) {
                        if let Ok(u) = webview.url() {
                            note_agent_browser_url(spec_id, u.as_str());
                        }
                    }
                })
                .build();
        }
    });
    Ok(())
}

fn close_agent_browser(app: &tauri::AppHandle, spec_id: i64) {
    if let Some(w) = app.get_webview_window(&browser_label(spec_id)) {
        let _ = w.close();
    }
}

/// CGWindowID of the agent browser, for window-only capture.
fn browser_cg_window_id(app: &tauri::AppHandle, spec_id: i64) -> Option<i64> {
    let win = app.get_webview_window(&browser_label(spec_id))?;
    let raw = win.ns_window().ok()?;
    use objc::{msg_send, sel, sel_impl};
    let ns = raw as *mut objc::runtime::Object;
    let num: i64 = unsafe { msg_send![ns, windowNumber] };
    if num > 0 {
        Some(num)
    } else {
        None
    }
}

/// Capture ONLY the agent browser window (not the user's screen).
async fn capture_browser(app: &tauri::AppHandle, spec_id: i64) -> Result<(String, f64, f64), String> {
    let id = browser_cg_window_id(app, spec_id).ok_or("agent browser not ready")?;
    let path = std::env::temp_dir().join(format!("cascade-agent-browser-{spec_id}.png"));
    let out = std::process::Command::new("screencapture")
        .args(["-l", &id.to_string(), "-o", "-x", "-t", "png", path.to_string_lossy().as_ref()])
        .output()
        .map_err(|e| format!("capture browser: {e}"))?;
    if !out.status.success() {
        return Err("window capture failed".to_string());
    }
    let bytes = std::fs::read(&path).map_err(|e| format!("read browser shot: {e}"))?;
    if bytes.len() < 200 {
        return Err("empty browser capture".to_string());
    }
    let img = image::load_from_memory(&bytes).map_err(|e| format!("decode browser shot: {e}"))?;
    let resized = img.resize_exact(BROWSER_W as u32, BROWSER_H as u32, image::imageops::FilterType::Triangle);
    let mut buf = Vec::new();
    resized
        .write_to(&mut Cursor::new(&mut buf), image::ImageFormat::Png)
        .map_err(|e| format!("encode browser shot: {e}"))?;
    Ok((STANDARD.encode(&buf), BROWSER_W, BROWSER_H))
}

fn browser_eval(app: &tauri::AppHandle, spec_id: i64, js: &str) {
    if let Some(win) = app.get_webview_window(&browser_label(spec_id)) {
        let _ = win.eval(js);
    }
}

/// Execute an action inside the agent browser via JS injection — this is the
/// whole point: it changes the agent's browser, NOT the user's screen.
fn browser_execute(app: &tauri::AppHandle, spec_id: i64, action: &ComputerAction) {
    match action.action.as_str() {
        "navigate" | "open_app" => {
            // Never "guess" a destination from free text here. If the model asks
            // to navigate, it must provide a real URL, and we only allow it on
            // the CURRENT site. API/raw-data routes are blocked. Otherwise we
            // no-op so the agent stays in D2L.
            let raw = if action.text.starts_with("http") {
                action.text.clone()
            } else if action.app.starts_with("http") {
                action.app.clone()
            } else {
                String::new()
            };
            if raw.is_empty() {
                return;
            }
            let lower = raw.to_lowercase();
            if lower.contains("/api/")
                || lower.ends_with(".json")
                || lower.contains("format=json")
                || lower.contains("contenttype=json")
                || lower.contains("/feed")
                || lower.contains("/export")
            {
                return;
            }
            let safe = serde_json::to_string(&raw).unwrap_or_else(|_| "\"\"".into());
            browser_eval(
                app,
                spec_id,
                &format!(
                    "(function(){{\
var raw={safe}; if(!raw) return;\
try{{\
  var cur=new URL(window.location.href);\
  var next=new URL(raw, window.location.href);\
  if(next.host && cur.host && next.host!==cur.host) return;\
  window.location.href=next.toString();\
}}catch(e){{}}\
}})();"
                ),
            );
        }
        "click" | "double_click" => {
            // Dispatch pointer + mouse events on the best interactive target at
            // the point, searching the full paint stack and same-origin iframes.
            // D2L-style nav menus often ignore a bare `el.click()` or the first
            // topmost span; they want the actual buttonish node plus pointerdown.
            let dbl = if action.action == "double_click" { ",'dblclick'" } else { "" };
            browser_eval(app, spec_id, &format!(
                "(function(){{\
var CLICKABLE='a,button,[role=\\\"button\\\"],[onclick],input,select,textarea,label,[tabindex],summary,[aria-haspopup],li,td';\
function pick(root,x,y){{\
  var stack=[];\
  try{{ if(root.elementsFromPoint) stack=root.elementsFromPoint(x,y)||[]; }}catch(e){{}}\
  for(var i=0;i<stack.length;i++){{\
    var node=stack[i]; if(!node||!node.tagName) continue;\
    if(node.tagName==='IFRAME'){{\
      try{{\
        var rect=node.getBoundingClientRect();\
        var child=node.contentWindow&&node.contentWindow.document;\
        var nested=child&&pick(child,x-rect.left,y-rect.top);\
        if(nested) return nested;\
      }}catch(e){{}}\
    }}\
    var direct=null; try{{direct=node.closest(CLICKABLE);}}catch(e){{}}\
    if(direct) return direct;\
    if(node.shadowRoot){{\
      try{{\
        var shadowTarget=pick(node.shadowRoot,x,y);\
        if(shadowTarget) return shadowTarget;\
      }}catch(e){{}}\
    }}\
  }}\
  var top=null; try{{ top=root.elementFromPoint?root.elementFromPoint(x,y):null; }}catch(e){{}}\
  if(!top) return null;\
  try{{ return top.closest(CLICKABLE)||top; }}catch(e){{ return top; }}\
}}\
var t=pick(document,{x},{y}); if(!t) return;\
var rect=(t.getBoundingClientRect&&t.getBoundingClientRect())||{{left:{x},top:{y},width:0,height:0}};\
var cx=rect.width?rect.left+rect.width/2:{x};\
var cy=rect.height?rect.top+rect.height/2:{y};\
if(t.scrollIntoView) try{{t.scrollIntoView({{block:'nearest',inline:'nearest'}});}}catch(e){{}}\
if(t.focus) try{{t.focus({{preventScroll:true}});}}catch(e){{try{{t.focus();}}catch(_){{}}}}\
['pointerover','mouseover','pointerdown','mousedown','pointerup','mouseup','click'{dbl}].forEach(function(ty){{\
  try{{\
    var Ctor=ty.indexOf('pointer')===0&&window.PointerEvent?PointerEvent:MouseEvent;\
    t.dispatchEvent(new Ctor(ty,{{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0,buttons:1,pointerType:'mouse',isPrimary:true}}));\
  }}catch(e){{}}\
}});\
try{{ if(t.click) t.click(); }}catch(e){{}}\
}})();",
                x = action.x, y = action.y, dbl = dbl
            ));
        }
        "type" => {
            let t = serde_json::to_string(&action.text).unwrap_or_else(|_| "\"\"".into());
            browser_eval(app, spec_id, &format!(
                "(function(){{\
var t={t};\
var el=document.activeElement;\
if(!el)return;\
if(el.isContentEditable){{\
  try{{document.execCommand('insertText',false,t);}}catch(e){{\
    el.textContent=(el.textContent||'')+t;\
    el.dispatchEvent(new InputEvent('input',{{bubbles:true,inputType:'insertText',data:t}}));\
  }}\
  return;\
}}\
if(!('value' in el))return;\
var proto=Object.getPrototypeOf(el);\
var desc=proto&&Object.getOwnPropertyDescriptor(proto,'value');\
var next=(el.value||'')+t;\
if(desc&&desc.set){{desc.set.call(el,next);}}else{{el.value=next;}}\
el.dispatchEvent(new InputEvent('beforeinput',{{bubbles:true,cancelable:true,inputType:'insertText',data:t}}));\
el.dispatchEvent(new InputEvent('input',{{bubbles:true,inputType:'insertText',data:t}}));\
el.dispatchEvent(new Event('change',{{bubbles:true}}));\
}})();"
            ));
        }
        "key" => {
            let key = if action.key.is_empty() { "Enter".to_string() } else { action.key.clone() };
            let k = serde_json::to_string(&key).unwrap_or_else(|_| "\"Enter\"".into());
            browser_eval(app, spec_id, &format!(
                "(function(){{\
var key={k};\
var el=document.activeElement||document.body;\
['keydown','keypress','keyup'].forEach(function(ty){{\
  try{{el.dispatchEvent(new KeyboardEvent(ty,{{key:key,bubbles:true,cancelable:true}}));}}catch(e){{}}\
}});\
if((key==='Enter'||key==='Return')&&el.form&&el.form.requestSubmit){{\
  try{{el.form.requestSubmit();}}catch(e){{}}\
}}\
}})();"
            ));
        }
        "scroll" => {
            let dy = if action.y != 0.0 { action.y } else { 500.0 };
            browser_eval(app, spec_id, &format!("window.scrollBy(0,{dy});"));
        }
        _ => {}
    }
}

/// Capture what the agent sees, per target: the isolated sandbox browser window,
/// or the user's real screen. (The floating box excludes itself from capture, so
/// the screen shot never contains the box — no infinite mirror.)
async fn capture_for(
    app: &tauri::AppHandle,
    spec_id: i64,
    target: RunTarget,
) -> Result<(String, f64, f64), String> {
    match target {
        RunTarget::Sandbox => capture_browser(app, spec_id).await,
        RunTarget::Screen => capture_logical_screenshot(app),
    }
}

/// Perform an action, per target: inside the sandbox browser via JS injection, or
/// on the user's real screen via synthesized input. Real input is serialized
/// through INPUT_LOCK so concurrent agents don't collide on the keyboard/mouse.
async fn act_for(
    app: &tauri::AppHandle,
    spec_id: i64,
    action: &ComputerAction,
    target: RunTarget,
) {
    match target {
        RunTarget::Sandbox => browser_execute(app, spec_id, action),
        RunTarget::Screen => {
            let _guard = INPUT_LOCK.lock().await;
            execute_action(action);
        }
    }
}

/// One task cycle: screenshot → decide → act, up to MAX_STEPS. Records its own
/// run and returns the count of committing actions taken. The persistent
/// `run_loop` calls this once on start and again on the agent's cadence.
async fn run_task_cycle(
    app: &tauri::AppHandle,
    spec_id: i64,
    name: &str,
    goal: &str,
    supervised: bool,
    hue: i64,
    target: RunTarget,
) -> i64 {
    let recording = record_run_start(app, spec_id).await;
    let mut history = String::new();
    let mut produced = 0i64;
    let mut notes: Vec<String> = Vec::new();
    let mut transient_failures = 0u32;
    let mut stalled_commits = 0u32;

    match target {
        RunTarget::Sandbox => {
            // The agent's OWN browser. It only opens on a Rewind-grounded site that
            // was observed for this workflow; if we don't have one, fail closed.
            let Some(start_url) = get_start_url(spec_id) else {
                if let Some((pool, run_id)) = &recording {
                    use cascade_schema::sqlx;
                    let _ = sqlx::query("UPDATE cascade_agent_runs SET status=?2, summary=?3 WHERE id=?1")
                        .bind(*run_id)
                        .bind("failed")
                        .bind("computer-use run failed: no Rewind-grounded start URL")
                        .execute(pool)
                        .await;
                }
                emit_status(
                    app,
                    status_err(
                        spec_id,
                        name,
                        goal,
                        0,
                        supervised,
                        hue,
                        "No Rewind-grounded start URL was found for this agent".to_string(),
                    ),
                );
                return 0;
            };
            if let Err(e) = ensure_agent_browser(app, spec_id, &start_url) {
                if let Some((pool, run_id)) = &recording {
                    use cascade_schema::sqlx;
                    let _ = sqlx::query("UPDATE cascade_agent_runs SET status=?2, summary=?3 WHERE id=?1")
                        .bind(*run_id)
                        .bind("failed")
                        .bind(format!("computer-use run failed: {e}"))
                        .execute(pool)
                        .await;
                }
                emit_status(app, status_err(spec_id, name, goal, 0, supervised, hue, e));
                return 0;
            }
            tokio::time::sleep(Duration::from_millis(1600)).await; // let the page load
        }
        RunTarget::Screen => {
            // No sandbox window — the agent works on the user's real screen. If we
            // recovered the observed site, open it there first so the agent starts
            // in the right place; otherwise it works with whatever is on screen.
            if let Some(start_url) = get_start_url(spec_id) {
                let _ = std::process::Command::new("open").arg(&start_url).spawn();
                tokio::time::sleep(Duration::from_millis(2200)).await;
            }
        }
    }

    for step in 1..=MAX_STEPS {
        if stop_requested(spec_id) || is_paused(spec_id) {
            break;
        }
        let (b64, lw, lh) = match capture_for(app, spec_id, target).await {
            Ok(v) => {
                transient_failures = 0;
                v
            }
            Err(e) => {
                transient_failures += 1;
                if transient_failures <= MAX_TRANSIENT_RETRIES {
                    emit_status(
                        app,
                        status_retry(
                            spec_id,
                            name,
                            goal,
                            step,
                            supervised,
                            hue,
                            transient_failures,
                            &e,
                        ),
                    );
                    history.push_str(&format!(
                        "- step {step}: temporary capture issue: {e}; retrying in {RETRY_DELAY_SECS}s ({}/{})\n",
                        transient_failures, MAX_TRANSIENT_RETRIES
                    ));
                    tokio::time::sleep(Duration::from_secs(RETRY_DELAY_SECS)).await;
                    continue;
                }
                emit_status(app, status_err(spec_id, name, goal, step, supervised, hue, e));
                break;
            }
        };
        // Sandbox streams its browser into the box; screen mode has no box (the
        // user watches their real screen directly), so don't ship frames there.
        if target == RunTarget::Sandbox {
            let _ = app.emit(EVT_FRAME, FrameEvent { image_base64: b64.clone(), img_w: lw, img_h: lh });
        }
        let user = format!(
            "GOAL: {goal}\n\nSteps so far:\n{}\n\nThe screenshot is the current screen ({lw:.0}x{lh:.0} points). Single next action as JSON.",
            if history.is_empty() { "(none yet)" } else { &history }
        );
        let res = match call_anthropic_vision(MODEL_SONNET, &computer_system_prompt(name, lw, lh, target), &user, &b64, 0.0, 700).await {
            Ok(r) => {
                transient_failures = 0;
                r
            }
            Err(e) => {
                transient_failures += 1;
                if transient_failures <= MAX_TRANSIENT_RETRIES {
                    emit_status(
                        app,
                        status_retry(
                            spec_id,
                            name,
                            goal,
                            step,
                            supervised,
                            hue,
                            transient_failures,
                            &e,
                        ),
                    );
                    history.push_str(&format!(
                        "- step {step}: vision call failed: {e}; retrying in {RETRY_DELAY_SECS}s ({}/{})\n",
                        transient_failures, MAX_TRANSIENT_RETRIES
                    ));
                    tokio::time::sleep(Duration::from_secs(RETRY_DELAY_SECS)).await;
                    continue;
                }
                emit_status(app, status_err(spec_id, name, goal, step, supervised, hue, e));
                break;
            }
        };
        let action: ComputerAction = match extract_json_str(&res.text).ok().and_then(|j| serde_json::from_str(&j).ok()) {
            Some(a) => {
                transient_failures = 0;
                a
            }
            None => {
                transient_failures += 1;
                let err = "couldn't read next action".to_string();
                if transient_failures <= MAX_TRANSIENT_RETRIES {
                    emit_status(
                        app,
                        status_retry(
                            spec_id,
                            name,
                            goal,
                            step,
                            supervised,
                            hue,
                            transient_failures,
                            &err,
                        ),
                    );
                    history.push_str(&format!(
                        "- step {step}: model returned unusable action JSON; retrying in {RETRY_DELAY_SECS}s ({}/{})\n",
                        transient_failures, MAX_TRANSIENT_RETRIES
                    ));
                    tokio::time::sleep(Duration::from_secs(RETRY_DELAY_SECS)).await;
                    continue;
                }
                emit_status(app, status_err(spec_id, name, goal, step, supervised, hue, err));
                break;
            }
        };

        emit_cursor(app, CursorEvent { spec_id, name: name.to_string(), x: action.x, y: action.y, clicking: false, visible: true, hue });
        emit_status(app, StatusEvent { spec_id, name: name.to_string(), goal: goal.to_string(), narration: narrate(&action), step, supervised, awaiting_approval: false, done: false, error: None, hue });

        if action.action == "record" {
            let note = recorded_text(if action.text.trim().is_empty() {
                &action.narration
            } else {
                &action.text
            });
            if !note.is_empty() {
                if !notes.iter().any(|existing| existing.eq_ignore_ascii_case(&note)) {
                    notes.push(note.clone());
                }
                if let Some((pool, run_id)) = &recording {
                    let _ = insert_agent_action(pool, &AgentActionInput {
                        run_id: *run_id,
                        spec_id,
                        step,
                        tool: "browser.record".to_string(),
                        summary: "Recorded a finding".to_string(),
                        content: Some(note.clone()),
                        artifact_path: None,
                        reversible: false,
                        mutating: false,
                        state: "committed".to_string(),
                    }).await;
                }
                history.push_str(&format!("- step {step}: recorded finding: {note}\n"));
            } else {
                history.push_str(&format!("- step {step}: tried to record, but captured nothing useful\n"));
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
            continue;
        }

        if action.action == "done" {
            let final_summary = recorded_text(&action.text);
            if let Some(document) = build_recorded_digest(name, goal, &notes, &final_summary) {
                match &recording {
                    Some((pool, run_id)) => {
                        match crate::cascade_agents::deliver_artifact_write(
                            app,
                            spec_id,
                            *run_id,
                            step,
                            name,
                            &document,
                        )
                        .await
                        {
                            Ok(delivered) => {
                                produced += 1;
                                let summary = format!(
                                    "Wrote the gathered result into {}",
                                    delivered.app_label
                                );
                                let _ = insert_agent_action(pool, &AgentActionInput {
                                    run_id: *run_id,
                                    spec_id,
                                    step,
                                    tool: "artifact.write".to_string(),
                                    summary: summary.clone(),
                                    content: Some(document.clone()),
                                    artifact_path: delivered.path.clone(),
                                    reversible: true,
                                    mutating: true,
                                    state: "committed".to_string(),
                                }).await;
                                box_step(app, spec_id, name, goal, &summary, step);
                                box_result(
                                    app,
                                    spec_id,
                                    name,
                                    &delivered.app_label,
                                    name,
                                    &document,
                                    delivered.open_ref.as_deref(),
                                );
                            }
                            Err(e) => {
                                let _ = insert_agent_action(pool, &AgentActionInput {
                                    run_id: *run_id,
                                    spec_id,
                                    step,
                                    tool: "artifact.write".to_string(),
                                    summary: format!("failed to write gathered result: {e}"),
                                    content: Some(document.clone()),
                                    artifact_path: None,
                                    reversible: false,
                                    mutating: true,
                                    state: "failed".to_string(),
                                }).await;
                                emit_status(app, StatusEvent {
                                    spec_id,
                                    name: name.to_string(),
                                    goal: goal.to_string(),
                                    narration: format!("Read the site, but couldn't save the result — {e}"),
                                    step,
                                    supervised,
                                    awaiting_approval: false,
                                    done: false,
                                    error: None,
                                    hue,
                                });
                            }
                        }
                    }
                    None => box_result(app, spec_id, name, "Result", name, &document, None),
                }
            }
            break;
        }
        if supervised && is_committing(&action.action) {
            emit_status(app, StatusEvent { spec_id, name: name.to_string(), goal: goal.to_string(), narration: format!("Waiting for your OK: {}", narrate(&action)), step, supervised, awaiting_approval: true, done: false, error: None, hue });
            let approved = await_approval(spec_id).await;
            if stop_requested(spec_id) {
                break;
            }
            if !approved {
                history.push_str(&format!("- step {step}: (skipped: {})\n", narrate(&action)));
                continue;
            }
        }
        if stop_requested(spec_id) {
            break;
        }
        if is_paused(spec_id) {
            history.push_str(&format!("- step {step}: paused before {}\n", narrate(&action)));
            break;
        }

        emit_cursor(app, CursorEvent { spec_id, name: name.to_string(), x: action.x, y: action.y, clicking: true, visible: true, hue });
        // Act per the chosen target: inside the sandbox browser, or on the real screen.
        act_for(app, spec_id, &action, target).await;
        if is_committing(&action.action) {
            produced += 1;
            if let Some((pool, run_id)) = &recording {
                let _ = insert_agent_action(pool, &AgentActionInput {
                    run_id: *run_id,
                    spec_id,
                    step,
                    tool: format!("browser.{}", action.action),
                    summary: narrate(&action),
                    content: None,
                    artifact_path: None,
                    reversible: false,
                    mutating: true,
                    state: "committed".to_string(),
                }).await;
            }
        }

        history.push_str(&format!("- step {step}: {}\n", narrate(&action)));
        let pause = if matches!(action.action.as_str(), "navigate" | "open_app") { 2400 } else { 900 };
        tokio::time::sleep(Duration::from_millis(pause)).await;
        if is_committing(&action.action) {
            if let Ok((after_b64, after_w, after_h)) = capture_for(app, spec_id, target).await {
                if target == RunTarget::Sandbox {
                    let _ = app.emit(EVT_FRAME, FrameEvent { image_base64: after_b64.clone(), img_w: after_w, img_h: after_h });
                }
                if frames_look_same(&b64, &after_b64) {
                    stalled_commits += 1;
                    history.push_str(&format!(
                        "- step {step}: {} had no visible effect; pick a different visible target, scroll, wait for loading, or record what you can see instead of repeating it\n",
                        action.action
                    ));
                    emit_status(
                        app,
                        StatusEvent {
                            spec_id,
                            name: name.to_string(),
                            goal: goal.to_string(),
                            narration: if stalled_commits >= STALL_WARN_AFTER {
                                "The screen is not changing. Trying a different route instead of repeating the same action…".to_string()
                            } else {
                                "That action did nothing visible. Trying another on-page action…".to_string()
                            },
                            step,
                            supervised,
                            awaiting_approval: false,
                            done: false,
                            error: None,
                            hue,
                        },
                    );
                    if stalled_commits >= STALL_FAIL_AFTER {
                        history.push_str(&format!(
                            "- step {step}: stopped after {stalled_commits} no-effect actions to avoid an automation loop\n"
                        ));
                        emit_status(
                            app,
                            StatusEvent {
                                spec_id,
                                name: name.to_string(),
                                goal: goal.to_string(),
                                narration: "I stopped because the screen was not responding to repeated actions.".to_string(),
                                step,
                                supervised,
                                awaiting_approval: false,
                                done: true,
                                error: Some("stopped after repeated no-effect actions".to_string()),
                                hue,
                            },
                        );
                        break;
                    }
                } else {
                    stalled_commits = 0;
                }
            }
        }
    }

    if let Some((pool, run_id)) = &recording {
        use cascade_schema::sqlx;
        let _ = sqlx::query("UPDATE cascade_agent_runs SET status=?2, summary=?3 WHERE id=?1")
            .bind(*run_id)
            .bind(if stop_requested(spec_id) { "flagged" } else { "success" })
            .bind(format!("computer-use run · {produced} action(s)"))
            .execute(pool)
            .await;
    }
    produced
}

async fn run_loop(app: tauri::AppHandle, spec_id: i64, name: String, goal: String, supervised: bool, target: RunTarget) {
    let hue = hue_for(spec_id);
    let mut goal = goal;
    // Sandbox → the floating box (streams the isolated browser with the agent
    // cursor drawn INSIDE it; the user keeps working uninterrupted). Screen →
    // NO box: a click-through cursor overlay so the agent's OWN pointer moves on
    // the user's REAL screen, right where it's about to act.
    match target {
        RunTarget::Sandbox => ensure_box_window(&app),
        RunTarget::Screen => ensure_cursor_overlay(&app),
    }
    // Let the freshly-created overlay webview register its event listeners.
    tokio::time::sleep(Duration::from_millis(850)).await;

    // Give the sandbox the user's existing browser session first. If the site
    // has portable cookies in Arc/Chrome/Brave/Edge, the agent starts signed in
    // without a separate local-sandbox login. If not, fall back to the visible
    // login window, serialized + keyed PER HOST so "Watch all" can't cross-
    // release another agent's login. Real-screen runs use the user's already-
    // signed-in apps, so there's no sandbox sign-in to manage there.
    if target == RunTarget::Sandbox {
        if let Some(url) = get_start_url(spec_id) {
            let host = host_of(&url);
            if !host.is_empty() && !is_signed_in(&host) {
                emit_status(
                    &app,
                    StatusEvent {
                        spec_id,
                        name: name.clone(),
                        goal: goal.clone(),
                        narration: format!("Using your existing browser session for {host}…"),
                        step: 0,
                        supervised,
                        awaiting_approval: false,
                        done: false,
                        error: None,
                        hue,
                    },
                );
                // 1. Inject the user's existing browser cookies into the shared
                //    WKWebView store (best-effort; misses if expired/non-cookie).
                let _ = hydrate_sandbox_session(&app, &url).await;
                // 2. Open the agent browser NOW so it loads the start URL WITH those
                //    cookies, then check where it actually LANDED. A cookie count
                //    can't tell us if we're really in — the injected cookies may be
                //    absent, expired, or insufficient (auth in localStorage/passkeys).
                //    The page can: if it bounced to a login/SSO page, we're not in.
                clear_agent_browser_url(spec_id);
                if let Err(e) = ensure_agent_browser(&app, spec_id, &url) {
                    eprintln!("[cascade-login] {host}: couldn't open agent browser to verify session — {e}");
                }
                tokio::time::sleep(Duration::from_millis(3000)).await; // load + any auth redirect
                if sandbox_landed_authenticated(spec_id, &host) {
                    mark_signed_in(&host);
                    eprintln!("[cascade-login] {host}: reused your existing browser session — signed in");
                } else {
                    // Cookies didn't get us in. Fall back to the visible login, then
                    // reload the agent browser so it picks up the fresh session.
                    eprintln!("[cascade-login] {host}: existing session insufficient — falling back to manual login");
                    emit_status(
                        &app,
                        StatusEvent {
                            spec_id,
                            name: name.clone(),
                            goal: goal.clone(),
                            narration: format!("Couldn't reuse your saved session — please sign in to {host}…"),
                            step: 0,
                            supervised,
                            awaiting_approval: false,
                            done: false,
                            error: None,
                            hue,
                        },
                    );
                    ensure_host_login(&app, spec_id, &name, &goal, supervised, hue, &host, &url).await;
                    reload_agent_browser(&app, spec_id, &url);
                }
                if stop_requested(spec_id) {
                    end_agent(spec_id);
                    return;
                }
            }
        }
    }

    // Ground the agent in the EMPLOYEE'S ACTUAL RECORDED STEPS for this kind of
    // work (clicks, typing, app switches from `ui_events`) so it FOLLOWS the real
    // path instead of re-deriving every move from vision — the reason agents
    // otherwise fumble. General: whatever was recorded, no per-site logic.
    match crate::cascade_agents::fetch_rewind_steps(&app, 48, 400, true).await {
        Ok(steps) if !steps.trim().is_empty() => {
            goal.push_str(&format!(
                "\n\nSTEPS THE EMPLOYEE ACTUALLY TOOK FOR THIS WORK — their real recorded path. Reproduce this same sequence of clicks/navigation on the current site as closely as what's on screen allows; do NOT wander or re-invent the path:\n{steps}"
            ));
        }
        Ok(_) => {}
        Err(e) => eprintln!("[cascade-steps] none for spec {spec_id}: {e}"),
    }

    emit_status(
        &app,
        StatusEvent {
            spec_id,
            name: name.clone(),
            goal: goal.clone(),
            narration: "Looking at the screen…".to_string(),
            step: 0,
            supervised,
            awaiting_approval: false,
            done: false,
            error: None,
            hue,
        },
    );

    let mut produced = run_task_cycle(&app, spec_id, &name, &goal, supervised, hue, target).await;
    // PERSIST: the agent does not die after finishing a task. It stays alive —
    // the box stays open, the screen keeps streaming, the cursor stays put — and
    // it re-runs its task periodically. It only shuts down when the user stops it.
    // Pause holds it idle without shutting it down.
    let mut idle_secs = 0u64;
    loop {
        if stop_requested(spec_id) {
            break;
        }
        let paused = is_paused(spec_id);
        // Sandbox only: keep the box alive by streaming the agent's browser so the
        // user can watch progress. Screen mode has no box (and no agent cursor
        // moves while idle), so skip the wasteful full-screen captures.
        if target == RunTarget::Sandbox {
            if let Ok((b64, lw, lh)) = capture_for(&app, spec_id, target).await {
                let _ = app.emit(EVT_FRAME, FrameEvent { image_base64: b64, img_w: lw, img_h: lh });
            }
        }
        emit_status(
            &app,
            StatusEvent {
                spec_id,
                name: name.clone(),
                goal: goal.clone(),
                narration: if paused {
                    "Paused. Press resume to continue, or stop to shut it down.".to_string()
                } else {
                    format!("Idle — watching. {produced} action(s) last run; will run again on schedule.")
                },
                step: -2,
                supervised,
                awaiting_approval: false,
                done: false,
                error: None,
                hue,
            },
        );

        tokio::time::sleep(Duration::from_secs(4)).await;
        if paused {
            idle_secs = 0;
            continue;
        }
        idle_secs += 4;

        // Re-run the task on the agent's cadence (clamped to a watchable minimum
        // so a "deployed" agent visibly keeps working without spamming).
        let cadence_secs = (spec_cadence_minutes(&app, spec_id).await.max(2) as u64) * 60;
        if idle_secs >= cadence_secs {
            idle_secs = 0;
            if stop_requested(spec_id) {
                break;
            }
            produced += run_task_cycle(&app, spec_id, &name, &goal, supervised, hue, target).await;
        }
    }

    // Stopped → tear down (close the agent's browser too).
    eprintln!("[cascade-agent] run_loop tearing down spec_id={spec_id} (stop={})", stop_requested(spec_id));
    close_agent_browser(&app, spec_id);
    emit_cursor(&app, CursorEvent { spec_id, name: name.clone(), x: 0.0, y: 0.0, clicking: false, visible: false, hue });
    emit_status(
        &app,
        StatusEvent {
            spec_id,
            name: name.clone(),
            goal: goal.clone(),
            narration: "Stopped.".to_string(),
            step: -1,
            supervised,
            awaiting_approval: false,
            done: true,
            error: None,
            hue,
        },
    );

    let remaining = end_agent(spec_id);
    if remaining == 0 {
        tokio::time::sleep(Duration::from_millis(800)).await;
        let still = AGENTS.lock().map(|m| m.values().filter(|c| c.running).count()).unwrap_or(0);
        if still == 0 {
            hide_overlays(&app);
        }
    }
}

/// How often the persistent agent re-runs its task, in minutes (from its spec).
async fn spec_cadence_minutes(app: &tauri::AppHandle, spec_id: i64) -> i64 {
    if spec_id <= 0 {
        return 5;
    }
    let Ok(pool) = crate::cascade_agents::cascade_pool(app).await else { return 5 };
    let Ok(Some(spec)) = get_agent_spec(&pool, spec_id).await else { return 5 };
    serde_json::from_str::<serde_json::Value>(&spec.spec_json)
        .ok()
        .and_then(|v| v.get("scheduleMinutes").and_then(|s| s.as_i64()))
        .unwrap_or(5)
}

fn status_err(spec_id: i64, name: &str, goal: &str, step: i64, supervised: bool, hue: i64, e: String) -> StatusEvent {
    StatusEvent {
        spec_id,
        name: name.to_string(),
        goal: goal.to_string(),
        narration: format!("Couldn't continue — {e}"),
        step,
        supervised,
        awaiting_approval: false,
        done: true,
        error: Some(e),
        hue,
    }
}

fn status_retry(
    spec_id: i64,
    name: &str,
    goal: &str,
    step: i64,
    supervised: bool,
    hue: i64,
    attempt: u32,
    e: &str,
) -> StatusEvent {
    StatusEvent {
        spec_id,
        name: name.to_string(),
        goal: goal.to_string(),
        narration: format!(
            "Hit a temporary issue — {e}. Retrying in {RETRY_DELAY_SECS}s ({attempt}/{MAX_TRANSIENT_RETRIES})"
        ),
        step,
        supervised,
        awaiting_approval: false,
        done: false,
        error: None,
        hue,
    }
}

// ─── spec loading ───────────────────────────────────────────────────

fn parse_spec_doc(spec_json: &str) -> Option<crate::cascade_agents::AgentSpecDoc> {
    serde_json::from_str::<crate::cascade_agents::AgentSpecDoc>(spec_json).ok()
}

fn spec_uses_browser(spec_json: &str) -> bool {
    parse_spec_doc(spec_json)
        .map(|doc| {
            doc.execution_mode.eq_ignore_ascii_case("browser")
                || doc
                    .workflow
                    .iter()
                    .any(|step| step.tool.as_deref() == Some("browser.use"))
        })
        .unwrap_or(false)
}

fn spec_target_url(spec_json: &str) -> Option<String> {
    parse_spec_doc(spec_json).and_then(|doc| {
        let url = doc.target_url.trim();
        if url.is_empty() {
            None
        } else {
            Some(url.to_string())
        }
    })
}

fn derive_goal(spec_json: &str) -> String {
    let Some(doc) = parse_spec_doc(spec_json) else {
        return "Do the task this agent was created for".to_string();
    };
    let mut goal = if doc.task_description.trim().is_empty() {
        "Do the task this agent was created for".to_string()
    } else {
        doc.task_description.clone()
    };
    if spec_uses_browser(spec_json) {
        if !doc.target_url.trim().is_empty() {
            goal.push_str(&format!(
                "\n\nWORK IN THIS OBSERVED TOOL URL: {}",
                doc.target_url.trim()
            ));
        }
        if !doc.target_hosts.is_empty() {
            goal.push_str(&format!(
                "\nObserved web tools used for this workflow: {}",
                doc.target_hosts.join(", ")
            ));
        }
        if !doc.observed_apps.is_empty() {
            goal.push_str(&format!(
                "\nObserved apps used for this workflow: {}",
                doc.observed_apps.join(", ")
            ));
        }
        if !doc.observed_workflow.is_empty() {
            goal.push_str("\nObserved workflow to follow:\n");
            for step in doc.observed_workflow.iter().take(6) {
                goal.push_str("- ");
                goal.push_str(step);
                goal.push('\n');
            }
        }
        if !doc.completion_pattern.trim().is_empty() {
            goal.push_str(&format!(
                "\nHow the employee finished it: {}",
                doc.completion_pattern.trim()
            ));
        }
    }
    goal
}

async fn db_pool(app: &tauri::AppHandle) -> Result<cascade_schema::sqlx::sqlite::SqlitePool, String> {
    let db_path = {
        let store = crate::store::SettingsStore::get(app)
            .map_err(|e| format!("settings: {e}"))?
            .unwrap_or_default();
        let (dir, _) = crate::config::resolve_data_dir(&store.data_dir);
        dir.join("db.sqlite")
    };
    open(&db_path).await.map_err(|e| format!("open db: {e}"))
}

async fn resolve_browser_start_url(
    app: &tauri::AppHandle,
    spec_id: i64,
    task: &str,
    spec_json: &str,
) -> Result<String, String> {
    if let Some(existing) = get_start_url(spec_id) {
        return Ok(existing);
    }
    // An explicit destination pinned in the spec wins — some agents WRITE into a
    // specific tool (e.g. "take notes in Notion"), so their site is the task's
    // destination, not the most-used site from the Rewind. Generated agents store
    // their Rewind-derived site here too, so this stays dynamic for them.
    if let Some(url) = spec_target_url(spec_json) {
        return Ok(url);
    }
    if let Ok(grounding) = crate::cascade_agents::fetch_rewind_grounding(app, 24, task, 300).await {
        if !grounding.primary_url.trim().is_empty() {
            return Ok(grounding.primary_url);
        }
    }
    Err("No observed start URL was recovered from the spec or the Rewind".to_string())
}

fn spawn_agent(app: tauri::AppHandle, spec_id: i64, name: String, goal: String, supervised: bool, target: RunTarget) {
    if !try_begin(spec_id) {
        return; // already running
    }
    tauri::async_runtime::spawn(async move {
        run_loop(app, spec_id, name, goal, supervised, target).await;
    });
}

// ─── commands ───────────────────────────────────────────────────────

/// Start ONE deployed agent working on-screen.
#[tauri::command]
#[specta::specta]
pub async fn cascade_start_computer_task(
    app: tauri::AppHandle,
    spec_id: i64,
    goal: Option<String>,
    target: Option<String>,
) -> Result<(), String> {
    let target = RunTarget::from_opt(target.as_deref());
    let pool = db_pool(&app).await?;
    let spec = get_agent_spec(&pool, spec_id)
        .await
        .map_err(|e| format!("load spec: {e}"))?
        .ok_or_else(|| format!("spec {spec_id} not found"))?;
    if spec.status != "deployed" {
        return Err("agent must be installed/deployed before it can act".to_string());
    }
    // The sandbox is web-only, so it requires a browser-grounded workflow. The
    // real-screen target can drive ANY app, so it accepts any deployed agent.
    if target == RunTarget::Sandbox && !spec_uses_browser(&spec.spec_json) {
        return Err("This agent isn't a browser workflow, so it can't run in the Local Sandbox. Switch to \"On your screen\" in Settings to run it.".to_string());
    }
    // Browser computer-use is NOT per-click supervised: every click/type/navigate
    // counts as "committing", so per-step approval would block the agent on its
    // very first action and it would appear to never start. The reviewable output
    // is the final gathered deliverable (shown in the box + written via the
    // delivery path); destructive actions are already forbidden by the prompt.
    let supervised = false;
    let task = goal.unwrap_or_else(|| derive_goal(&spec.spec_json));
    let mut g = task.clone();
    // Ground the agent in the Rewind: what the employee ACTUALLY did on screen, so
    // the work it types (a recap, etc.) reflects real activity, not a guess.
    if let Ok((digest, _, _)) = crate::cascade_agents::fetch_rewind_digest(&app, 24, 300).await {
        if !digest.trim().is_empty() {
            g.push_str(&format!(
                "\n\nWHAT THE EMPLOYEE ACTUALLY DID ON SCREEN (from the Rewind — ground your work in this, do not invent):\n{}",
                digest.chars().take(4000).collect::<String>()
            ));
        }
    }
    // Where should the agent work? Resolve the site DYNAMICALLY from the Rewind —
    // wherever the employee actually does this kind of work — never a hardcoded
    // app. The sandbox REQUIRES this site (it opens the agent's browser there and
    // pops its sign-in). On the real screen it's just a helpful starting point, so
    // it's optional — the agent can also work with whatever's already on screen.
    match target {
        RunTarget::Sandbox => {
            let start_url = resolve_browser_start_url(&app, spec_id, &task, &spec.spec_json).await?;
            set_start_url(spec_id, start_url.clone());
            eprintln!("[cascade-agent] start spec_id={spec_id} name={:?} url={start_url} target=sandbox", spec.name);
        }
        RunTarget::Screen => {
            if let Ok(start_url) = resolve_browser_start_url(&app, spec_id, &task, &spec.spec_json).await {
                set_start_url(spec_id, start_url.clone());
                eprintln!("[cascade-agent] start spec_id={spec_id} name={:?} url={start_url} target=screen", spec.name);
            } else {
                eprintln!("[cascade-agent] start spec_id={spec_id} name={:?} (no start URL) target=screen", spec.name);
            }
        }
    }
    // Sign-in (if needed) now happens inside the agent's run_loop — serialized
    // and per-host — so it can't release a different agent's login.
    spawn_agent(app, spec_id, spec.name, g, supervised, target);
    Ok(())
}

/// Start EVERY installed (deployed) agent at once — one cursor per agent.
#[tauri::command]
#[specta::specta]
pub async fn cascade_start_all_computer_tasks(app: tauri::AppHandle, target: Option<String>) -> Result<u32, String> {
    let target = RunTarget::from_opt(target.as_deref());
    let pool = db_pool(&app).await?;
    let specs = list_deployed_specs(&pool).await.map_err(|e| format!("list deployed: {e}"))?;
    let mut started = 0u32;
    for spec in specs {
        // The sandbox is web-only; the real screen can drive any app.
        if target == RunTarget::Sandbox && !spec_uses_browser(&spec.spec_json) {
            continue;
        }
        let task = derive_goal(&spec.spec_json);
        match resolve_browser_start_url(&app, spec.id, &task, &spec.spec_json).await {
            Ok(url) => set_start_url(spec.id, url),
            // Sandbox needs a site; the real screen can proceed without one.
            Err(_) if target == RunTarget::Sandbox => continue,
            Err(_) => {}
        }
        // Login happens inside each agent's run_loop, serialized + per-host — so
        // starting many agents here can't cross-release their sign-ins.
        // Browser computer-use is not per-click supervised (see cascade_start_computer_task).
        spawn_agent(app.clone(), spec.id, spec.name.clone(), task, false, target);
        started += 1;
    }
    Ok(started)
}

#[tauri::command]
#[specta::specta]
pub async fn cascade_stop_computer_task(app: tauri::AppHandle, spec_id: i64) -> Result<(), String> {
    // 1. Flag the loop(s) to stop, and collect which agents we're stopping.
    eprintln!("[cascade-agent] STOP invoked spec_id={spec_id} (<=0 means all)");
    let ids: Vec<i64> = if let Ok(mut m) = AGENTS.lock() {
        if spec_id <= 0 {
            for c in m.values_mut() {
                c.stop = true;
            }
            m.keys().copied().collect()
        } else {
            if let Some(c) = m.get_mut(&spec_id) {
                c.stop = true;
            }
            vec![spec_id]
        }
    } else {
        vec![]
    };
    // 2. IMMEDIATELY close the visible agent browser(s) + any open login window so
    //    STOP is felt at once. The async loop also unwinds on the stop flag (its
    //    next capture fails and it breaks), but don't make the user wait for it —
    //    a slow in-flight vision call could otherwise leave the browser on screen.
    eprintln!("[cascade-agent] STOP flagged ids={ids:?} — closing their browsers + any login window");
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        for id in &ids {
            if let Some(w) = app2.get_webview_window(&browser_label(*id)) {
                let _ = w.close();
            }
        }
        if let Some(w) = app2.get_webview_window(LOGIN_WINDOW) {
            let _ = w.close();
        }
    });
    Ok(())
}

/// Pause/resume an agent without shutting it down (spec_id <= 0 = all).
#[tauri::command]
#[specta::specta]
pub async fn cascade_pause_computer_task(spec_id: i64, paused: bool) -> Result<(), String> {
    if spec_id <= 0 {
        if let Ok(mut m) = AGENTS.lock() {
            for c in m.values_mut() {
                c.paused = paused;
            }
        }
    } else {
        set_paused(spec_id, paused);
    }
    Ok(())
}

/// Pause one agent and focus its visible browser so the employee can take over
/// manually inside the exact screen the agent was using.
#[tauri::command]
#[specta::specta]
pub async fn cascade_take_control_computer_task(
    app: tauri::AppHandle,
    spec_id: i64,
) -> Result<(), String> {
    if spec_id <= 0 {
        return Err("spec_id must be a running agent".to_string());
    }
    set_paused(spec_id, true);
    let label = browser_label(spec_id);
    let app2 = app.clone();
    app.run_on_main_thread(move || {
        if let Some(win) = app2.get_webview_window(&label) {
            let _ = win.show();
            let _ = win.unminimize();
            let _ = win.set_focus();
        }
    })
    .map_err(|e| format!("focus browser: {e}"))?;
    Ok(())
}

#[tauri::command]
#[specta::specta]
pub async fn cascade_approve_computer_step(spec_id: i64) -> Result<(), String> {
    set_approval(spec_id, true);
    Ok(())
}

#[tauri::command]
#[specta::specta]
pub async fn cascade_reject_computer_step(spec_id: i64) -> Result<(), String> {
    set_approval(spec_id, false);
    Ok(())
}

const LOGIN_WINDOW: &str = "cascade-agent-login";

/// Hosts whose sign-in has actually COMPLETED this session — so the login only
/// pops the FIRST time per host. Inserted in `ensure_host_login` AFTER sign-in is
/// detected (or the user closes the window), never just because a window opened —
/// so an abandoned or failed login correctly re-prompts on the next run.
static LOGGED_IN: LazyLock<Mutex<std::collections::HashSet<String>>> =
    LazyLock::new(|| Mutex::new(std::collections::HashSet::new()));

fn is_signed_in(host: &str) -> bool {
    LOGGED_IN.lock().map(|s| s.contains(host)).unwrap_or(false)
}
fn mark_signed_in(host: &str) {
    if let Ok(mut s) = LOGGED_IN.lock() {
        s.insert(host.to_string());
    }
}

/// Serializes the whole login flow across agents. The sign-in window and the
/// current-login flags below are SHARED + single, so only one login may be in
/// flight at a time — otherwise "Watch all" could retarget the window from
/// agent A's host to agent B's, and B's completed sign-in would release A's loop
/// even though A's site was never authenticated.
static LOGIN_GATE: LazyLock<tokio::sync::Mutex<()>> = LazyLock::new(|| tokio::sync::Mutex::new(()));

// ─── auto sign-in detection ─────────────────────────────────────────
//
// The old flow blocked the agent until the employee MANUALLY CLOSED the login
// window — but after signing in, an SSO portal navigates that same window to the
// authenticated home and leaves it open, so the agent waited forever ("I already
// signed in and the agent is still waiting"). We can't read cross-origin cookies,
// so instead we watch the login window's MAIN-DOCUMENT navigations: a real
// sign-in either bounces off the target host to an identity provider and back,
// or moves from an auth/login URL to a normal page on the same host. Either
// round-trip means the user is in — so we auto-close and let the agent work.

/// Host the login window was opened for (the site the agent will drive).
static LOGIN_TARGET_HOST: LazyLock<Mutex<String>> = LazyLock::new(|| Mutex::new(String::new()));
/// We navigated to a host OTHER than the target (e.g. an SSO identity provider).
static LOGIN_SAW_EXTERNAL: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// We were on an auth/login/MFA URL at some point (same-host login forms too).
static LOGIN_SAW_AUTH: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// Sign-in looks complete — the run loop closes the window and proceeds.
static LOGIN_DONE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// URL fragments that mean "still on a sign-in / identity-provider / MFA page",
/// so we DON'T mistake the login form itself for a completed login.
fn looks_like_auth_url(url: &str) -> bool {
    let u = url.to_lowercase();
    [
        "login", "signin", "sign-in", "sign_in", "logon", "/sso", "oauth", "/auth",
        "saml", "/idp", "adfs", "/cas", "shibboleth", "microsoftonline", "okta",
        "auth0", "/sts", "wayf", "openid", "duosecurity", "/mfa", "/2fa", "passport",
    ]
    .iter()
    .any(|m| u.contains(m))
}

/// Record one MAIN-DOCUMENT navigation of the login window (called from
/// `on_page_load` with `webview.url()`, which is reliable on macOS — unlike
/// `on_navigation`, whose URL can be a subframe/iframe target, wry#1593).
fn note_login_navigation(url: &str) {
    use std::sync::atomic::Ordering;
    let host = host_of(url);
    if host.is_empty() {
        return;
    }
    let target = LOGIN_TARGET_HOST.lock().map(|t| t.clone()).unwrap_or_default();
    let on_target = !target.is_empty()
        && (host == target
            || host.ends_with(&format!(".{target}"))
            || target.ends_with(&format!(".{host}")));
    let auth = looks_like_auth_url(url);
    if !on_target {
        LOGIN_SAW_EXTERNAL.store(true, Ordering::SeqCst);
    }
    if auth {
        LOGIN_SAW_AUTH.store(true, Ordering::SeqCst);
    }
    // Signed in once we're back on the target host on a NON-auth page, having
    // previously bounced through an IdP (external) or a login/MFA page.
    if on_target
        && !auth
        && (LOGIN_SAW_EXTERNAL.load(Ordering::SeqCst) || LOGIN_SAW_AUTH.load(Ordering::SeqCst))
    {
        LOGIN_DONE.store(true, Ordering::SeqCst);
    }
    eprintln!(
        "[cascade-login] page host={host} target={target} on_target={on_target} auth={auth} ext={} sawauth={} done={}",
        LOGIN_SAW_EXTERNAL.load(Ordering::SeqCst),
        LOGIN_SAW_AUTH.load(Ordering::SeqCst),
        LOGIN_DONE.load(Ordering::SeqCst),
    );
}

/// host of a URL ("https://d2l.x.ca/foo" → "d2l.x.ca"), for the login key.
fn host_of(url: &str) -> String {
    let after = url.split("://").nth(1).unwrap_or(url);
    after.split(['/', '?', '#']).next().unwrap_or("").to_lowercase()
}

/// Open the visible sign-in window at `url`. WKWebView's default cookie store is
/// shared app-wide + persistent, so once signed in here the agent's own browser
/// is authenticated for that tool. The employee closes the window when done.
fn open_login_window(app: &tauri::AppHandle, url: &str) -> Result<(), String> {
    use std::sync::atomic::Ordering;
    let app2 = app.clone();
    let parsed = parse_external_url(url)?;
    // Reset the auto sign-in detector for this fresh login round + remember the
    // host the agent will work on, so on_page_load can tell when we've returned
    // to it authenticated.
    LOGIN_SAW_EXTERNAL.store(false, Ordering::SeqCst);
    LOGIN_SAW_AUTH.store(false, Ordering::SeqCst);
    LOGIN_DONE.store(false, Ordering::SeqCst);
    if let Ok(mut t) = LOGIN_TARGET_HOST.lock() {
        *t = host_of(url);
    }
    let url = parsed.to_string();
    let _ = app.run_on_main_thread(move || {
        if let Some(win) = app2.get_webview_window(LOGIN_WINDOW) {
            let safe = serde_json::to_string(&url).unwrap_or_else(|_| "\"about:blank\"".into());
            let _ = win.eval(&format!("window.location.href={safe};"));
            let _ = win.show();
            let _ = win.set_focus();
        } else if let Ok(win) = WebviewWindowBuilder::new(&app2, LOGIN_WINDOW, WebviewUrl::External(parsed))
            .title("Sign in — Cascade's agent continues automatically once you're in")
            .inner_size(1100.0, 760.0)
            .center()
            .resizable(true)
            .focused(true)
            .visible(true)
            // Reliable main-document URL on macOS (unlike on_navigation), read on
            // each finished load to detect a completed sign-in.
            .on_page_load(|webview, payload| {
                if matches!(payload.event(), tauri::webview::PageLoadEvent::Finished) {
                    if let Ok(u) = webview.url() {
                        note_login_navigation(u.as_str());
                    }
                }
            })
            .build()
        {
            let _ = win.set_focus();
        }
    });
    Ok(())
}

/// Ensure the agent's site (`host`) is signed in before it works. Serialized
/// across agents via `LOGIN_GATE` (one login window at a time) and keyed PER
/// HOST: a host is only marked signed-in once THIS host's sign-in is actually
/// detected (or the user closes the window), so one agent's login can never
/// release another agent waiting on a different site, and an abandoned/failed
/// login re-prompts on the next run. The URL is Rewind-derived — nothing
/// hardcoded per app.
#[allow(clippy::too_many_arguments)]
async fn ensure_host_login(
    app: &tauri::AppHandle,
    spec_id: i64,
    name: &str,
    goal: &str,
    supervised: bool,
    hue: i64,
    host: &str,
    url: &str,
) {
    // Exclusive: only one login flow (window + current-login flags) at a time.
    let _gate = LOGIN_GATE.lock().await;
    // Another agent on the SAME host may have signed in while we queued.
    if is_signed_in(host) {
        return;
    }
    if open_login_window(app, url).is_err() {
        return;
    }
    tokio::time::sleep(Duration::from_millis(900)).await; // let the window appear
    let mut waited = 0u64;
    loop {
        if stop_requested(spec_id) {
            return; // STOP closes the login window in cascade_stop_computer_task
        }
        // Signed in: SSO/login round-trip landed back on THIS host (flags are
        // ours alone because we hold the gate).
        if LOGIN_DONE.load(std::sync::atomic::Ordering::SeqCst) {
            mark_signed_in(host);
            if let Some(w) = app.get_webview_window(LOGIN_WINDOW) {
                let _ = w.close();
            }
            eprintln!("[cascade-login] {host}: sign-in detected — agent proceeding");
            return;
        }
        // User closed the window themselves — treat THIS host as signed in.
        if app.get_webview_window(LOGIN_WINDOW).is_none() {
            mark_signed_in(host);
            eprintln!("[cascade-login] {host}: login window closed by user — agent proceeding");
            return;
        }
        emit_status(
            app,
            StatusEvent {
                spec_id,
                name: name.to_string(),
                goal: goal.to_string(),
                narration: format!(
                    "Waiting for you to sign in to {host}… I'll continue automatically once you're in (or just close that window)."
                ),
                step: 0,
                supervised,
                awaiting_approval: false,
                done: false,
                error: None,
                hue,
            },
        );
        tokio::time::sleep(Duration::from_millis(700)).await;
        waited += 700;
        if waited > 6 * 60 * 1000 {
            // Safety timeout — don't nag forever; proceed (and don't re-prompt).
            mark_signed_in(host);
            if let Some(w) = app.get_webview_window(LOGIN_WINDOW) {
                let _ = w.close();
            }
            return;
        }
    }
}

/// Still exposed as a command (e.g. for re-login), but the normal flow pops the
/// login automatically when an agent that needs a tool is started.
#[tauri::command]
#[specta::specta]
pub async fn cascade_open_agent_login(app: tauri::AppHandle, url: Option<String>) -> Result<(), String> {
    let url = url.ok_or_else(|| "A real login URL is required".to_string())?;
    open_login_window(&app, &url)
}

#[tauri::command]
#[specta::specta]
pub async fn cascade_computer_status() -> Result<Vec<ComputerAgentStatus>, String> {
    let m = AGENTS.lock().map_err(|_| "state lock")?;
    Ok(m.iter()
        .filter(|(_, c)| c.running)
        .map(|(id, c)| ComputerAgentStatus {
            spec_id: *id,
            awaiting_approval: c.awaiting,
        })
        .collect())
}
