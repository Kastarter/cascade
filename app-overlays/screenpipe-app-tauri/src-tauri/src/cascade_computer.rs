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

fn ensure_overlays(app: &tauri::AppHandle) {
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
        if app2.get_webview_window(HANDS_WINDOW).is_none() {
            if let Ok(win) = WebviewWindowBuilder::new(
                &app2,
                HANDS_WINDOW,
                WebviewUrl::App("hands-box".into()),
            )
            .title("")
            .inner_size(500.0, 470.0)
            .position((w - 520.0).max(20.0), 44.0)
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
                promote_overlay(&win, false);
            }
        } else if let Some(win) = app2.get_webview_window(HANDS_WINDOW) {
            let _ = win.show();
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

fn computer_system_prompt(name: &str, w: f64, h: f64) -> String {
    format!(
        "You are \"{name}\", a careful Cascade agent operating YOUR OWN web browser (a {w:.0}x{h:.0} \
viewport, top-left origin). This is an isolated browser — NOT the user's screen — so the user keeps \
working while you do the task here. You're given a screenshot of your browser and a GOAL.\n\n\
Use web apps to accomplish the goal: to use a tool, NAVIGATE to its website (Notion → https://www.notion.so, \
Gmail → https://mail.google.com, Google Docs → https://docs.google.com, etc.). Decide the SINGLE next \
action, then wait for the next screenshot. Be conservative; never take destructive or irreversible \
actions (deleting, sending money, changing account/security settings, posting publicly).\n\n\
Actions:\n\
- navigate: go to a URL (put the full https URL in `text`)\n\
- click / double_click: click at (x,y) in the viewport\n\
- type: type `text` into the focused field\n\
- key: press a key (`key`, e.g. \"Enter\")\n\
- scroll: scroll the page (put pixels in `y`, negative = up)\n\
- wait: let the page load\n\
- done: the goal is complete\n\n\
Return ONLY JSON: {{\"narration\":\"short present-tense\",\"action\":\"navigate|click|double_click|type|key|scroll|wait|done\",\
\"x\":0,\"y\":0,\"text\":\"\",\"app\":\"\",\"key\":\"\"}}"
    )
}

fn is_committing(action: &str) -> bool {
    matches!(action, "click" | "double_click" | "type" | "key" | "navigate" | "open_app")
}

fn execute_action(action: &ComputerAction) {
    match action.action.as_str() {
        "click" => cascade_input::click(action.x, action.y),
        "double_click" => cascade_input::double_click(action.x, action.y),
        "type" => cascade_input::type_text(&action.text),
        "key" => cascade_input::press_key(&action.key),
        "open_app" => cascade_input::open_app(&action.app),
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

/// Map a known app/goal to a starting URL so the agent lands somewhere useful.
fn start_url_for_goal(goal: &str) -> String {
    let g = goal.to_lowercase();
    let pick = [
        ("notion", "https://www.notion.so"),
        ("gmail", "https://mail.google.com"),
        ("google docs", "https://docs.google.com"),
        ("docs.google", "https://docs.google.com"),
        ("spreadsheet", "https://docs.google.com/spreadsheets"),
        ("sheet", "https://docs.google.com/spreadsheets"),
        ("linkedin", "https://www.linkedin.com/feed/"),
        ("slack", "https://app.slack.com"),
        ("calendar", "https://calendar.google.com"),
        ("github", "https://github.com"),
        ("trello", "https://trello.com"),
    ];
    for (kw, url) in pick {
        if g.contains(kw) {
            return url.to_string();
        }
    }
    "https://www.google.com".to_string()
}

/// Create (once) the agent's own browser window, OFFSCREEN so the user never
/// sees or interacts with it; the agent drives it and the box streams it.
fn ensure_agent_browser(app: &tauri::AppHandle, spec_id: i64, start_url: &str) {
    let app2 = app.clone();
    let label = browser_label(spec_id);
    let url = start_url.to_string();
    let _ = app.run_on_main_thread(move || {
        if app2.get_webview_window(&label).is_none() {
            let parsed = tauri::Url::parse(&url)
                .unwrap_or_else(|_| tauri::Url::parse("https://www.google.com").unwrap());
            let _ = WebviewWindowBuilder::new(&app2, &label, WebviewUrl::External(parsed))
                .title("Cascade Agent")
                .inner_size(BROWSER_W, BROWSER_H)
                .position(-6000.0, 0.0) // offscreen — invisible to the user
                .decorations(false)
                .skip_taskbar(true)
                .focused(false)
                .visible(true)
                .build();
        }
    });
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
            let url = if action.text.starts_with("http") {
                action.text.clone()
            } else if action.app.starts_with("http") {
                action.app.clone()
            } else if !action.app.is_empty() {
                start_url_for_goal(&action.app)
            } else {
                start_url_for_goal(&action.text)
            };
            let safe = serde_json::to_string(&url).unwrap_or_else(|_| "\"https://www.google.com\"".into());
            browser_eval(app, spec_id, &format!("window.location.href={safe};"));
        }
        "click" | "double_click" => {
            browser_eval(app, spec_id, &format!(
                "(function(){{var el=document.elementFromPoint({x},{y});if(el){{if(el.focus)el.focus();if(el.click)el.click();}}}})();",
                x = action.x, y = action.y
            ));
        }
        "type" => {
            let t = serde_json::to_string(&action.text).unwrap_or_else(|_| "\"\"".into());
            browser_eval(app, spec_id, &format!(
                "(function(){{var t={t};var el=document.activeElement;if(!el)return;if(el.isContentEditable){{document.execCommand('insertText',false,t);}}else if('value' in el){{el.value=(el.value||'')+t;el.dispatchEvent(new Event('input',{{bubbles:true}}));}}}})();"
            ));
        }
        "key" => {
            let key = if action.key.is_empty() { "Enter".to_string() } else { action.key.clone() };
            let k = serde_json::to_string(&key).unwrap_or_else(|_| "\"Enter\"".into());
            browser_eval(app, spec_id, &format!(
                "(function(){{var el=document.activeElement||document.body;['keydown','keypress','keyup'].forEach(function(ty){{el.dispatchEvent(new KeyboardEvent(ty,{{key:{k},bubbles:true}}));}});if(el.form&&el.form.requestSubmit){{el.form.requestSubmit();}}}})();"
            ));
        }
        "scroll" => {
            let dy = if action.y != 0.0 { action.y } else { 500.0 };
            browser_eval(app, spec_id, &format!("window.scrollBy(0,{dy});"));
        }
        _ => {}
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
) -> i64 {
    let recording = record_run_start(app, spec_id).await;
    let mut history = String::new();
    let mut produced = 0i64;

    // The agent's OWN browser (offscreen). Created once; reused across cycles.
    ensure_agent_browser(app, spec_id, &start_url_for_goal(goal));
    tokio::time::sleep(Duration::from_millis(1600)).await; // let the page load

    for step in 1..=MAX_STEPS {
        if stop_requested(spec_id) || is_paused(spec_id) {
            break;
        }
        let (b64, lw, lh) = match capture_browser(app, spec_id).await {
            Ok(v) => v,
            Err(e) => {
                emit_status(app, status_err(spec_id, name, goal, step, supervised, hue, e));
                tokio::time::sleep(Duration::from_millis(1000)).await;
                continue;
            }
        };
        let _ = app.emit(EVT_FRAME, FrameEvent { image_base64: b64.clone(), img_w: lw, img_h: lh });
        let user = format!(
            "GOAL: {goal}\n\nSteps so far:\n{}\n\nThe screenshot is the current screen ({lw:.0}x{lh:.0} points). Single next action as JSON.",
            if history.is_empty() { "(none yet)" } else { &history }
        );
        let res = match call_anthropic_vision(MODEL_SONNET, &computer_system_prompt(name, lw, lh), &user, &b64, 0.0, 700).await {
            Ok(r) => r,
            Err(e) => {
                emit_status(app, status_err(spec_id, name, goal, step, supervised, hue, e));
                break;
            }
        };
        let action: ComputerAction = match extract_json_str(&res.text).ok().and_then(|j| serde_json::from_str(&j).ok()) {
            Some(a) => a,
            None => {
                emit_status(app, status_err(spec_id, name, goal, step, supervised, hue, "couldn't read next action".into()));
                break;
            }
        };

        emit_cursor(app, CursorEvent { spec_id, name: name.to_string(), x: action.x, y: action.y, clicking: false, visible: true, hue });
        emit_status(app, StatusEvent { spec_id, name: name.to_string(), goal: goal.to_string(), narration: narrate(&action), step, supervised, awaiting_approval: false, done: false, error: None, hue });

        if action.action == "done" {
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

        emit_cursor(app, CursorEvent { spec_id, name: name.to_string(), x: action.x, y: action.y, clicking: true, visible: true, hue });
        // Act INSIDE the agent's own browser (never the user's screen).
        browser_execute(app, spec_id, &action);
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

async fn run_loop(app: tauri::AppHandle, spec_id: i64, name: String, goal: String, supervised: bool) {
    let hue = hue_for(spec_id);
    // The box shows the screen + the agent cursor inside it, so we no longer
    // need the separate fullscreen cursor overlay (it'd also show duplicate
    // cursors in the captured screenshot).
    ensure_box_window(&app);
    // Let the freshly-created overlay webview register its event listeners.
    tokio::time::sleep(Duration::from_millis(850)).await;
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

    let mut produced = run_task_cycle(&app, spec_id, &name, &goal, supervised, hue).await;
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
        // Keep the box alive: stream the agent's browser (not the user's screen).
        if let Ok((b64, lw, lh)) = capture_browser(&app, spec_id).await {
            let _ = app.emit(EVT_FRAME, FrameEvent { image_base64: b64, img_w: lw, img_h: lh });
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
            produced += run_task_cycle(&app, spec_id, &name, &goal, supervised, hue).await;
        }
    }

    // Stopped → tear down (close the agent's browser too).
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

// ─── spec loading ───────────────────────────────────────────────────

fn derive_goal(spec_json: &str) -> String {
    serde_json::from_str::<serde_json::Value>(spec_json)
        .ok()
        .and_then(|v| v.get("taskDescription").and_then(|t| t.as_str()).map(|s| s.to_string()))
        .unwrap_or_else(|| "Do the task this agent was created for".to_string())
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

fn spawn_agent(app: tauri::AppHandle, spec_id: i64, name: String, goal: String, supervised: bool) {
    if !try_begin(spec_id) {
        return; // already running
    }
    tauri::async_runtime::spawn(async move {
        run_loop(app, spec_id, name, goal, supervised).await;
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
) -> Result<(), String> {
    let pool = db_pool(&app).await?;
    let spec = get_agent_spec(&pool, spec_id)
        .await
        .map_err(|e| format!("load spec: {e}"))?
        .ok_or_else(|| format!("spec {spec_id} not found"))?;
    if spec.status != "deployed" {
        return Err("agent must be installed/deployed before it can act".to_string());
    }
    // No approval prompts — the agent just does the work.
    let supervised = false;
    let base = goal.unwrap_or_else(|| derive_goal(&spec.spec_json));
    // Smart: prefer the app the employee actually uses for notes/docs (e.g. Notion).
    let g = match crate::cascade_agents::preferred_notes_app(&app).await {
        Some(a) => format!(
            "{base}\n\nThe employee normally uses \"{a}\" for notes/docs — use {a}, not a different app."
        ),
        None => base,
    };
    spawn_agent(app, spec_id, spec.name, g, supervised);
    Ok(())
}

/// Start EVERY installed (deployed) agent at once — one cursor per agent.
#[tauri::command]
#[specta::specta]
pub async fn cascade_start_all_computer_tasks(app: tauri::AppHandle) -> Result<u32, String> {
    let pool = db_pool(&app).await?;
    let specs = list_deployed_specs(&pool).await.map_err(|e| format!("list deployed: {e}"))?;
    let mut started = 0u32;
    let notes_app = crate::cascade_agents::preferred_notes_app(&app).await;
    for spec in specs {
        let base = derive_goal(&spec.spec_json);
        let goal = match &notes_app {
            Some(a) => format!("{base}\n\nThe employee normally uses \"{a}\" for notes/docs — use {a}."),
            None => base,
        };
        spawn_agent(app.clone(), spec.id, spec.name.clone(), goal, false);
        started += 1;
    }
    Ok(started)
}

#[tauri::command]
#[specta::specta]
pub async fn cascade_stop_computer_task(spec_id: i64) -> Result<(), String> {
    if spec_id <= 0 {
        // stop all
        if let Ok(mut m) = AGENTS.lock() {
            for c in m.values_mut() {
                c.stop = true;
            }
        }
    } else {
        set_stop(spec_id);
    }
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

/// Open a VISIBLE browser window so the employee can log the agent into a
/// service (Notion, Gmail, …). WKWebView's default cookie store is shared
/// app-wide and persistent, so once logged in here, the agent's own offscreen
/// browser is authenticated for that service on every future run — and only the
/// services the employee chose to log in. The employee closes this window when
/// done.
#[tauri::command]
#[specta::specta]
pub async fn cascade_open_agent_login(app: tauri::AppHandle, url: Option<String>) -> Result<(), String> {
    let url = url.unwrap_or_else(|| "https://www.google.com".to_string());
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        let label = "cascade-agent-login";
        if let Some(win) = app2.get_webview_window(label) {
            let safe = serde_json::to_string(&url).unwrap_or_else(|_| "\"https://www.google.com\"".into());
            let _ = win.eval(&format!("window.location.href={safe};"));
            let _ = win.show();
            let _ = win.set_focus();
        } else if let Ok(parsed) = tauri::Url::parse(&url) {
            if let Ok(win) = WebviewWindowBuilder::new(&app2, label, WebviewUrl::External(parsed))
                .title("Log Cascade's agent in — sign in, then close this window")
                .inner_size(1100.0, 760.0)
                .center()
                .resizable(true)
                .focused(true)
                .visible(true)
                .build()
            {
                let _ = win.set_focus();
            }
        }
    });
    Ok(())
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
