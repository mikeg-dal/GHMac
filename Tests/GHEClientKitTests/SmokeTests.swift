import Testing
@testable import GHEClientKit

@Suite struct GHEClientKitTestsSmoke {
    @Test func moduleLoads() { #expect(Bool(true)) }
}
