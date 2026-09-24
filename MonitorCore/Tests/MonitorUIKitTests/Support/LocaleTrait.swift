import Foundation
import Testing
@testable import MonitorUIKit

/// Binds `TTFormat.locale` to en_US for the scope of a test or suite (no global mutation).
struct EnUSLocaleTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await TTFormat.$locale.withValue(Locale(identifier: "en_US")) {
            try await function()
        }
    }
}

extension Trait where Self == EnUSLocaleTrait {
    static var enUS: Self { EnUSLocaleTrait() }
}
