import CascadeMemory
import Testing

@testable import MacContextKit

@Test
func contextCaptureAuditDetailHashesAppNameAndKeepsOnlyCounts() {
    let appName = "P8_01 Payroll Private Window"
    let detail = ContextRecorder.captureAuditDetail(appName: appName, axChars: 17, ocrChars: 29)

    #expect(detail.contains("appHash=\(AuditIdentity.hash(appName))"))
    #expect(detail.contains("appChars=\(appName.count)"))
    #expect(detail.contains("axChars=17"))
    #expect(detail.contains("ocrChars=29"))
    #expect(!detail.contains(appName))
}
