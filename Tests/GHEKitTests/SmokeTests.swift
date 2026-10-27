import Testing
@testable import GHEKit

@Suite struct GHEKitTestsSmoke {
    @Test func moduleLoads() { #expect(Bool(true)) }
}
