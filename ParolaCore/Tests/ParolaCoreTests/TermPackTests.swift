import Foundation
import Testing
@testable import ParolaCore

@Suite("TermPack")
struct TermPackTests {
    @Test("round-trips through JSON without loss")
    func roundTrip() throws {
        let pack = TermPack(
            name: "Tech",
            locale: "en",
            version: 2,
            rules: [
                TermPackRule(find: "kubernetes", replace: "Kubernetes"),
                TermPackRule(find: "g r p c", replace: "gRPC", regex: false),
            ]
        )
        let data = try TermPackIO.encode(pack)
        let decoded = try TermPackIO.decode(data)
        #expect(decoded == pack)
    }

    @Test("merge skips rules whose find/case/regex tuple is already present")
    func mergeDedupes() {
        let existing = [
            FindReplaceRule(find: "k8s", replace: "Kubernetes"),
        ]
        let pack = TermPack(name: "Tech", locale: "en", rules: [
            TermPackRule(find: "k8s", replace: "different"),
            TermPackRule(find: "grpc", replace: "gRPC"),
        ])
        let merged = TermPackIO.merge(pack: pack, into: existing)
        #expect(merged.count == 2)
        #expect(merged.first(where: { $0.find == "k8s" })?.replace == "Kubernetes")
        #expect(merged.contains { $0.find == "grpc" && $0.replace == "gRPC" })
    }

    @Test("pack(from:) converts rules to TermPackRule")
    func packFromRules() {
        let rules = [
            FindReplaceRule(find: "kube", replace: "Kubernetes", caseSensitive: true)
        ]
        let pack = TermPackIO.pack(from: rules, name: "X", locale: "en")
        #expect(pack.rules.count == 1)
        #expect(pack.rules[0].find == "kube")
        #expect(pack.rules[0].caseSensitive == true)
    }

    @Test("a disabled rule stays disabled through a pack round trip")
    func disabledSurvivesRoundTrip() throws {
        let rules = [FindReplaceRule(find: "kube", replace: "Kubernetes", enabled: false)]
        let pack = TermPackIO.pack(from: rules, name: "X", locale: "en")
        let decoded = try TermPackIO.decode(TermPackIO.encode(pack))
        let merged = TermPackIO.merge(pack: decoded, into: [])
        #expect(merged.first?.enabled == false)
    }

    @Test("a pack without enabled fields imports rules as enabled")
    func legacyPackDefaultsEnabled() throws {
        let json = #"{"name":"X","locale":"en","version":1,"rules":[{"find":"kube","replace":"Kubernetes","caseSensitive":false,"regex":false}]}"#
        let decoded = try TermPackIO.decode(Data(json.utf8))
        #expect(decoded.rules.first?.enabled == true)
    }

    @Test("merge dedupes rules duplicated within the incoming pack")
    func mergeDedupesWithinPack() {
        let pack = TermPack(name: "Tech", locale: "en", rules: [
            TermPackRule(find: "grpc", replace: "gRPC"),
            TermPackRule(find: "grpc", replace: "GRPC"),
        ])
        let merged = TermPackIO.merge(pack: pack, into: [])
        #expect(merged.count == 1)
        #expect(merged.first(where: { $0.find == "grpc" })?.replace == "gRPC")
    }

    @Test("merge drops rules with empty find")
    func mergeDropsEmpty() {
        let pack = TermPack(name: "X", locale: "en", rules: [
            TermPackRule(find: "", replace: "nope"),
            TermPackRule(find: "grpc", replace: "gRPC"),
        ])
        let merged = TermPackIO.merge(pack: pack, into: [])
        #expect(merged.count == 1)
        #expect(merged[0].find == "grpc")
    }

    @Test("merge imports an invalid-regex rule disabled so it can't silently no-op")
    func mergeDisablesInvalidRegex() {
        let pack = TermPack(name: "X", locale: "en", rules: [
            TermPackRule(find: "h(ello", replace: "Hi", regex: true),
            TermPackRule(find: "grpc", replace: "gRPC"),
        ])
        let merged = TermPackIO.merge(pack: pack, into: [])
        #expect(merged.count == 2)
        #expect(merged.first { $0.find == "h(ello" }?.enabled == false)
        #expect(merged.first { $0.find == "grpc" }?.enabled == true)
    }

    @Test("merge keeps a valid regex rule enabled")
    func mergeKeepsValidRegexEnabled() {
        let pack = TermPack(name: "X", locale: "en", rules: [
            TermPackRule(find: #"\bk8s\b"#, replace: "Kubernetes", regex: true),
        ])
        let merged = TermPackIO.merge(pack: pack, into: [])
        #expect(merged.count == 1)
        #expect(merged[0].enabled == true)
    }
}
