import Foundation
import Testing
@testable import MonitorModel

@Suite struct SampleMemoryValueTests {
    @Test func appSampleMemoryValueIsExactDoubleNotBitPattern() {
        let sample = AppSample(memory: 1000)
        #expect(sample.value(for: .memory) == 1000.0)
    }

    @Test func processSampleMemoryValueIsExactDoubleNotBitPattern() {
        let sample = ProcessSample(memory: 1000)
        #expect(sample.value(for: .memory) == 1000.0)
    }
}
