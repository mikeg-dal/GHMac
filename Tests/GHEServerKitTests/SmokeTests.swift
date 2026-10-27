import Testing
@testable import GHEServerKit

@Suite struct GHEServerKitTestsSmoke {
    @Test func moduleLoads() { #expect(Bool(true)) }
}
