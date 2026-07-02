import CascadeMemory
import Foundation
import Testing

@testable import AppShell

@Test
func actionTrajectoryCacheFlagIsDefaultOff() {
    let suiteName = "ActionTrajectoryCache-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(!CascadeAppModel.experimentalActionTrajectoryCacheEnabled(defaults: defaults))
    defaults.set(true, forKey: CascadeAppModel.experimentalActionTrajectoryCacheKey)
    #expect(CascadeAppModel.experimentalActionTrajectoryCacheEnabled(defaults: defaults))
}

	@Test
	func actionTrajectoryCacheDecodesOnlyExecutableAllowlistActions() {
	    #expect(CascadeAppModel.actionTrajectoryCUAction(kind: "open_app", json: #"{"app":"Mail"}"#) != nil)
        #expect(CascadeAppModel.actionTrajectoryCUAction(kind: "open_url", json: #"{"url_scope":"https://example.com/inbox"}"#) == nil)
        #expect(CascadeAppModel.actionTrajectoryCUAction(kind: "open_url", json: #"{"url":"https://example.com/customers/:id"}"#) == nil)
	    #expect(CascadeAppModel.actionTrajectoryCUAction(kind: "scroll", json: #"{"x":10,"y":20,"direction":"down","amount":3}"#) != nil)
    #expect(CascadeAppModel.actionTrajectoryCUAction(kind: "click", json: #"{"x":10,"y":20,"target_descriptor":"AXButton Send"}"#) != nil)
    #expect(CascadeAppModel.actionTrajectoryCUAction(kind: "type", json: #"{"text":"private"}"#) == nil)
    #expect(CascadeAppModel.actionTrajectoryCUAction(kind: "key", json: #"{"key":"enter"}"#) == nil)
    #expect(CascadeAppModel.actionTrajectoryCUAction(kind: "drag", json: #"{"fromX":1,"fromY":2,"toX":3,"toY":4}"#) == nil)
    #expect(CascadeAppModel.actionTrajectoryCUAction(kind: "right_click", json: #"{"x":10,"y":20}"#) == nil)
}
