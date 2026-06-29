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
func recorderCadenceScrollQuietDefersCapture() {
    var controller = RecorderCadenceController()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    controller.record(activity: .scroll, at: now)
    let budget = controller.budget(now: now.addingTimeInterval(0.2))

    #expect(!budget.admitsCapture)
    #expect(budget.ocrPolicy == .fastOnly)
}
