import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

@Suite struct AssertionParseTests {
    static func a(_ type: String, level: Int? = 255, onBehalf: Int? = nil) -> [String: Any] {
        var d: [String: Any] = ["AssertType": type, "AssertName": "x"]
        if let level { d["AssertLevel"] = NSNumber(value: level) }
        if let onBehalf { d["AssertionOnBehalfOfPID"] = NSNumber(value: onBehalf) }
        return d
    }

    @Test func legacyAliasesAreNormalizedDedupedAndSorted() {
        let raw: [AnyHashable: Any] = [
            NSNumber(value: 10): [Self.a("NoIdleSleepAssertion"), Self.a("PreventUserIdleSystemSleep"),
                                  Self.a("NoDisplaySleepAssertion")],
            NSNumber(value: 11): [Self.a("DenySystemSleep")],
        ]
        let r = SleepAssertionParser.reading(raw)
        #expect(r.byPID == [10: ["PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep"], 11: ["PreventSystemSleep"]])
    }

    @Test func onBehalfAssertionsGoToTheBeneficiary() {
        let raw: [AnyHashable: Any] = [
            NSNumber(value: 440): [Self.a("PreventUserIdleSystemSleep", onBehalf: 9059),
                                   Self.a("PreventUserIdleSystemSleep", onBehalf: 0)],   // 0 = none → owner
        ]
        #expect(SleepAssertionParser.reading(raw).byPID == [9059: ["PreventUserIdleSystemSleep"],
                                                            440: ["PreventUserIdleSystemSleep"]])
    }

    @Test func releasedAndNonPreventingAssertionsAreSkipped() {
        let raw: [AnyHashable: Any] = [
            NSNumber(value: 418): [Self.a("UserIsActive")],
            NSNumber(value: 5): [Self.a("BackgroundTask"), Self.a("PreventSystemSleep", level: 0)],
            NSNumber(value: 6): [Self.a("PreventSystemSleep", level: nil)],   // no level key → active
        ]
        #expect(SleepAssertionParser.reading(raw).byPID == [6: ["PreventSystemSleep"]])
    }

    @Test func malformedEntriesAreIgnored() {
        let raw: [AnyHashable: Any] = [
            "12": [Self.a("PreventSystemSleep")],            // string key accepted
            "abc": [Self.a("PreventSystemSleep")],
            NSNumber(value: 13): "not a list",
            NSNumber(value: 14): [["AssertName": "no type"]],
        ]
        #expect(SleepAssertionParser.reading(raw).byPID == [12: ["PreventSystemSleep"]])
    }

    @Test func emptyInputIsEmpty() {
        #expect(SleepAssertionParser.reading([:]).byPID.isEmpty)
    }

    /// `IOPMCopyAssertionsByProcess` captured on this Mac next to `pmset -g assertions` (device id redacted).
    @Test func capturedDictionaryMatchesPmset() throws {
        let plist = try PropertyListSerialization.propertyList(from: W6aFixture.data("assertions.plist"), format: nil)
        let raw = try #require(plist as? [String: Any])
        let r = SleepAssertionParser.reading(raw)
        #expect(Set(r.byPID.keys) == [359, 9059, 27133, 44436, 55507, 98386, 98458])
        #expect(r.byPID.values.allSatisfy { $0 == ["PreventUserIdleSystemSleep"] })
        #expect(r.byPID[418] == nil)      // WindowServer: UserIsActive only
        #expect(r.byPID[440] == nil)      // coreaudiod: all on behalf of apps
    }
}
