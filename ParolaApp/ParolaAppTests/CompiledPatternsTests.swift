import Testing
@testable import Parola

@Suite("Compiled patterns")
struct CompiledPatternsTests {
    @Test("a pattern is compiled once however often it is asked about")
    func compilesOnce() {
        let patterns = CompiledPatterns()
        for _ in 0..<3 {
            #expect(patterns.compiles(#"\bum+\b"#))
            #expect(!patterns.compiles("(unclosed"))
        }
        #expect(patterns.compilations == 2)
    }
}
