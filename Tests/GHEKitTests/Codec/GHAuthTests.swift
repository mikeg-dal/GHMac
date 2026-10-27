import Foundation
import Testing
@testable import GHEKit

@Suite struct GHAuthTests {
    @Test func specTestVector() {
        let p = GHAuth.passwordHash(user: "alice", password: "secret1")
        #expect(Hex.string(p) == "5f454adf90338c2d88239a96773cb7feedb36e551a0c5387212a221ccea8601c")
        let r = GHAuth.response(user: "alice", challenge: "0.7316931046151538-81283467123456789011665432101234", passwordHash: p)
        #expect(Hex.string(r) == "1912ccc6bb389e47bf97c8877c7b6eeba9110f5c1f0ac6cdd345f7d7135a37c7")
    }

    @Test func passwordUsesLowByteOfEachUTF16Unit() {
        // '€' is U+20AC → low byte 0xAC (not the Cp1252 byte 0x80); user name is Cp1252.
        #expect(GHAuth.lowBytes("a€é") == [0x61, 0xAC, 0xE9])
        #expect(GHAuth.passwordHash(user: "é", password: "€") == GHAuth.sha256([0xE9, 0xAC]))
        #expect(GHAuth.passwordHash(user: "€", password: "x") == GHAuth.sha256([0x80, 0x78]))
    }

    @Test func masterHashIsPasswordTwice() {
        #expect(GHAuth.masterHash("secret") == GHAuth.sha256(Array("secretsecret".utf8)))
        #expect(GHAuth.masterHash("secret").count == 32)
    }

    @Test func challengeLooksLikeJava() {
        let a = GHAuth.makeChallenge(), b = GHAuth.makeChallenge()
        #expect(a != b)
        #expect(a.hasPrefix("0."))
        #expect(a.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-") })
        #expect(!a.contains("\r") && !a.contains("\n"))
        #expect(a.count >= 2 + 16 + 1 + 13)
        // The client takes everything after the first ':'.
        #expect(GHWire.decodeServerLine("PASS:" + a) == .pass(challenge: a))
    }
}
