import Foundation

/// Correlates client-side audio-buffer commits with the server item IDs that later
/// carry transcription callbacks. A commit is registered synchronously before it is
/// sent so a teaching drain can never observe a false zero while the final endpoint
/// commit is still in flight.
final class RealtimeVoiceTranscriptionTracker: @unchecked Sendable {
    private struct PendingCommit {
        let eventID: String
        let purpose: RealtimeVoice.CapturePurpose
    }

    private struct Waiter {
        let teachingSessionID: UUID
        let continuation: CheckedContinuation<RealtimeVoice.TranscriptionDrainResult, Never>
    }

    private let lock = NSLock()
    private var commitsWaitingForItemID: [PendingCommit] = []
    private var pendingByItemID: [String: RealtimeVoice.CapturePurpose] = [:]
    private var capturesClosing: Set<RealtimeVoice.CapturePurpose> = []
    private var waiters: [UUID: Waiter] = [:]
    private var disconnected = false

    func connected() {
        lock.lock()
        disconnected = false
        lock.unlock()
    }

    func captureWillClose(_ purpose: RealtimeVoice.CapturePurpose) {
        lock.lock()
        capturesClosing.insert(purpose)
        lock.unlock()
    }

    /// Registers a commit before it is sent and returns the client event ID that must
    /// travel on that exact request. Realtime errors echo this ID, which lets a rejected
    /// pre-item commit retire itself without shifting the FIFO onto the next capture.
    @discardableResult
    func noteCommit(from purpose: RealtimeVoice.CapturePurpose) -> String {
        let eventID = "voice-commit-\(UUID().uuidString)"
        lock.lock()
        commitsWaitingForItemID.append(PendingCommit(eventID: eventID, purpose: purpose))
        lock.unlock()
        return eventID
    }

    /// Retires a commit rejected before `input_audio_buffer.committed` assigned an item.
    /// Unknown IDs are intentionally ignored because an unrelated Realtime error must
    /// never consume the head of the transcription-purpose queue.
    @discardableResult
    func failCommit(eventID: String) -> RealtimeVoice.CapturePurpose? {
        guard !eventID.isEmpty else { return nil }
        var resumptions: [(CheckedContinuation<RealtimeVoice.TranscriptionDrainResult, Never>, RealtimeVoice.TranscriptionDrainResult)] = []
        let purpose: RealtimeVoice.CapturePurpose?
        lock.lock()
        if let index = commitsWaitingForItemID.firstIndex(where: { $0.eventID == eventID }) {
            purpose = commitsWaitingForItemID.remove(at: index).purpose
        } else {
            purpose = nil
        }
        collectSatisfiedWaitersLocked(into: &resumptions)
        lock.unlock()
        resume(resumptions)
        return purpose
    }

    func bindNextCommit(toItemID itemID: String) {
        guard !itemID.isEmpty else { return }
        var resumptions: [(CheckedContinuation<RealtimeVoice.TranscriptionDrainResult, Never>, RealtimeVoice.TranscriptionDrainResult)] = []
        lock.lock()
        if !commitsWaitingForItemID.isEmpty {
            pendingByItemID[itemID] = commitsWaitingForItemID.removeFirst().purpose
        }
        collectSatisfiedWaitersLocked(into: &resumptions)
        lock.unlock()
        resume(resumptions)
    }

    func purpose(forItemID itemID: String) -> RealtimeVoice.CapturePurpose? {
        lock.lock()
        defer { lock.unlock() }
        return pendingByItemID[itemID]
    }

    func settle(itemID: String) {
        var resumptions: [(CheckedContinuation<RealtimeVoice.TranscriptionDrainResult, Never>, RealtimeVoice.TranscriptionDrainResult)] = []
        lock.lock()
        pendingByItemID.removeValue(forKey: itemID)
        collectSatisfiedWaitersLocked(into: &resumptions)
        lock.unlock()
        resume(resumptions)
    }

    func captureDidClose(_ purpose: RealtimeVoice.CapturePurpose) {
        var resumptions: [(CheckedContinuation<RealtimeVoice.TranscriptionDrainResult, Never>, RealtimeVoice.TranscriptionDrainResult)] = []
        lock.lock()
        capturesClosing.remove(purpose)
        collectSatisfiedWaitersLocked(into: &resumptions)
        lock.unlock()
        resume(resumptions)
    }

    func disconnect() {
        var resumptions: [(CheckedContinuation<RealtimeVoice.TranscriptionDrainResult, Never>, RealtimeVoice.TranscriptionDrainResult)] = []
        lock.lock()
        disconnected = true
        commitsWaitingForItemID.removeAll()
        pendingByItemID.removeAll()
        capturesClosing.removeAll()
        for (_, waiter) in waiters {
            resumptions.append((waiter.continuation, .disconnected))
        }
        waiters.removeAll()
        lock.unlock()
        resume(resumptions)
    }

    func drain(
        teachingSessionID: UUID,
        timeout: Duration
    ) async -> RealtimeVoice.TranscriptionDrainResult {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var immediate: RealtimeVoice.TranscriptionDrainResult?
                lock.lock()
                if disconnected {
                    immediate = .disconnected
                } else if isDrainedLocked(teachingSessionID: teachingSessionID) {
                    immediate = .drained
                } else {
                    waiters[waiterID] = Waiter(
                        teachingSessionID: teachingSessionID,
                        continuation: continuation
                    )
                }
                lock.unlock()

                if let immediate {
                    continuation.resume(returning: immediate)
                } else {
                    Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        self?.timeOut(waiterID: waiterID)
                    }
                }
            }
        } onCancel: {
            timeOut(waiterID: waiterID)
        }
    }

    private func timeOut(waiterID: UUID) {
        let continuation: CheckedContinuation<RealtimeVoice.TranscriptionDrainResult, Never>?
        lock.lock()
        continuation = waiters.removeValue(forKey: waiterID)?.continuation
        lock.unlock()
        continuation?.resume(returning: .timedOut)
    }

    private func isDrainedLocked(teachingSessionID: UUID) -> Bool {
        let belongsToSession: (RealtimeVoice.CapturePurpose) -> Bool = { purpose in
            if case .teachAmbient(let sessionID, _) = purpose {
                return sessionID == teachingSessionID
            }
            return false
        }
        return !commitsWaitingForItemID.map(\.purpose).contains(where: belongsToSession)
            && !pendingByItemID.values.contains(where: belongsToSession)
            && !capturesClosing.contains(where: belongsToSession)
    }

    private func collectSatisfiedWaitersLocked(
        into resumptions: inout [(CheckedContinuation<RealtimeVoice.TranscriptionDrainResult, Never>, RealtimeVoice.TranscriptionDrainResult)]
    ) {
        let completedIDs = waiters.compactMap { id, waiter in
            isDrainedLocked(teachingSessionID: waiter.teachingSessionID) ? id : nil
        }
        for id in completedIDs {
            if let waiter = waiters.removeValue(forKey: id) {
                resumptions.append((waiter.continuation, .drained))
            }
        }
    }

    private func resume(
        _ resumptions: [(CheckedContinuation<RealtimeVoice.TranscriptionDrainResult, Never>, RealtimeVoice.TranscriptionDrainResult)]
    ) {
        for (continuation, result) in resumptions {
            continuation.resume(returning: result)
        }
    }
}
