// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade

//! Notification CRUD routes.
//!
//! Cascade does not surface Screenpipe's notification panel UI. Keep the
//! history endpoints intact, but treat `POST /notify` as a no-op so upstream
//! callers can't render the native/webview notification panel.

use super::store::{self, NotificationHistoryEntry};
use crate::server::ApiResponse;
use axum::extract::Path;
use axum::http::StatusCode;
use axum::Json;

/// `POST /notify` — acknowledged, but intentionally not shown in Cascade.
pub async fn send_notification(
    Json(_payload): Json<NotifyPayload>,
) -> Result<Json<ApiResponse>, (StatusCode, String)> {
    Ok(Json(ApiResponse {
        success: true,
        message: "Notification suppressed by Cascade".to_string(),
    }))
}

/// `GET /notifications` — list notification history from disk.
pub async fn list() -> Json<Vec<NotificationHistoryEntry>> {
    Json(store::read_all())
}

/// `POST /notifications` — mark all notifications as read.
pub async fn mark_read() -> Json<ApiResponse> {
    store::mark_all_read();
    Json(ApiResponse {
        success: true,
        message: "all notifications marked as read".to_string(),
    })
}

/// `DELETE /notifications` — clear notification history.
pub async fn clear() -> Json<ApiResponse> {
    store::clear();
    Json(ApiResponse {
        success: true,
        message: "notification history cleared".to_string(),
    })
}

/// `DELETE /notifications/:id` — dismiss a single notification.
pub async fn dismiss(Path(id): Path<String>) -> (StatusCode, Json<ApiResponse>) {
    if store::remove_by_id(&id) {
        (
            StatusCode::OK,
            Json(ApiResponse {
                success: true,
                message: "notification dismissed".to_string(),
            }),
        )
    } else {
        (
            StatusCode::NOT_FOUND,
            Json(ApiResponse {
                success: false,
                message: "notification not found".to_string(),
            }),
        )
    }
}

#[derive(serde::Serialize, serde::Deserialize, Debug)]
pub struct NotifyPayload {
    pub title: String,
    pub body: String,
    pub id: Option<String>,
    #[serde(rename = "type")]
    pub notification_type: Option<String>,
    #[serde(rename = "autoDismissMs")]
    pub auto_dismiss_ms: Option<u64>,
    pub timeout: Option<u64>,
    #[serde(default)]
    pub actions: Vec<serde_json::Value>,
}
