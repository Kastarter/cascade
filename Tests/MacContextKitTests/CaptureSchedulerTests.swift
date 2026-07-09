import Foundation
import MacContextKit
import Testing

@Test
func recorderCadenceNormalPolicyAllowsFullWork() {
    var controller = RecorderCadenceController()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    controller.record(activity: .click, at: now)
    let budget = controller.budget(now: now.addingTimeInterval(2))

    #expect(budget.admitsCapture)
    #expect(budget.heartbeatInterval == CaptureScheduler.idleHeartbeatInterval)
    #expect(budget.ocrPolicy == .adaptive)
    #expect(budget.allowsNativeResolutionOCR)
    #expect(budget.allowsSemanticIndexing)
}

@Test
func recorderCadenceIdleSlowsHeartbeatWithoutDroppingWork() {
    var controller = RecorderCadenceController()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    controller.record(activity: .click, at: now.addingTimeInterval(-120))
    let budget = controller.budget(now: now)

    #expect(budget.admitsCapture)
    #expect(budget.heartbeatInterval == 30)
    #expect(budget.ocrPolicy == .adaptive)
}

@Test
func recorderCadenceLowPowerDegradesExpensiveWork() {
    var controller = RecorderCadenceController()
    controller.updatePower(lowPowerMode: true, thermalCondition: .nominal)

    let budget = controller.budget()

    #expect(budget.admitsCapture)
    #expect(budget.ocrPolicy == .fastOnly)
    #expect(!budget.allowsNativeResolutionOCR)
    #expect(!budget.allowsSemanticIndexing)
}

@Test
func recorderCadenceSeriousThermalSuppressesIndexingAndNativeOCR() {
    var controller = RecorderCadenceController()
    controller.updatePower(lowPowerMode: false, thermalCondition: .serious)

    let budget = controller.budget()

    #expect(budget.admitsCapture)
    #expect(budget.heartbeatInterval == 45)
    #expect(budget.ocrPolicy == .fastOnly)
    #expect(!budget.allowsNativeResolutionOCR)
    #expect(!budget.allowsSemanticIndexing)
}

@Test
func recorderCadenceCriticalThermalStopsCaptureAdmission() {
    var controller = RecorderCadenceController()
    controller.updatePower(lowPowerMode: false, thermalCondition: .critical)

    let budget = controller.budget()

    #expect(!budget.admitsCapture)
    #expect(budget.heartbeatInterval == 90)
    #expect(!budget.allowsNativeResolutionOCR)
    #expect(!budget.allowsSemanticIndexing)
}

@Test
func recorderCadenceTypingPauseUsesFastInsuranceOCR() {
    var controller = RecorderCadenceController()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    controller.record(activity: .typingRun, at: now)
    let budget = controller.budget(now: now.addingTimeInterval(0.5))

    #expect(budget.admitsCapture)
    #expect(budget.ocrPolicy == .fastOnly)
    #expect(!budget.allowsNativeResolutionOCR)
}

@Test
func recorderCadenceScrollBurstStillCapturesWithFastOCR() {
    // Mid-scroll frames are evidence — content scrolled past must land in the
    // record (and its OCR), just on the cheap fast pass. Only thermal/low-power
    // pressure sheds them.
    var controller = RecorderCadenceController()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    controller.record(activity: .scroll, at: now)
    let budget = controller.budget(now: now.addingTimeInterval(0.2))

    #expect(budget.admitsCapture)
    #expect(budget.ocrPolicy == .fastOnly)
    #expect(!budget.allowsNativeResolutionOCR)
}

@Test
func streamHeartbeatAdmitsEveryChangedFrameAtOneSecondCadence() {
    // The SCStream delivers ~1fps; a 1s persistence gap means every changed
    // frame becomes a moment (smooth playback), while a same-second burst is
    // still coalesced.
    var scheduler = CaptureScheduler()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let first = scheduler.admits(reason: .streamHeartbeat, now: now)
    let sameSecondBurst = scheduler.admits(reason: .streamHeartbeat, now: now.addingTimeInterval(0.4))
    let nextSecond = scheduler.admits(reason: .streamHeartbeat, now: now.addingTimeInterval(1.05))

    #expect(first)
    #expect(!sameSecondBurst)
    #expect(nextSecond)
}

@Test
func streamHeartbeatGapIsTunableForTheDemoBurst() {
    // Teach-once tightens the persistence gap to 0.5s so every changed state of a
    // demonstration becomes a moment.
    var scheduler = CaptureScheduler()
    scheduler.streamHeartbeatGap = 0.5
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let first = scheduler.admits(reason: .streamHeartbeat, now: now)
    let insideGap = scheduler.admits(reason: .streamHeartbeat, now: now.addingTimeInterval(0.4))
    let pastGap = scheduler.admits(reason: .streamHeartbeat, now: now.addingTimeInterval(0.55))

    #expect(first)
    #expect(!insideGap)
    #expect(pastGap)
}
