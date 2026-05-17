import Foundation
import Testing
@testable import ParolaCore

@Suite("Voice print matcher")
struct VoicePrintMatcherTests {
    @Test("identical embeddings score 1")
    func identical() {
        let a: [Float] = [0.1, 0.2, 0.3, 0.4]
        let score = VoicePrintMatcher.cosineSimilarity(a, a)
        let delta = abs(score - 1)
        #expect(delta < 1e-5)
    }

    @Test("orthogonal embeddings score 0")
    func orthogonal() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        let score = VoicePrintMatcher.cosineSimilarity(a, b)
        let mag = abs(score)
        #expect(mag < 1e-5)
    }

    @Test("opposite embeddings score -1")
    func opposite() {
        let a: [Float] = [1, 0]
        let b: [Float] = [-1, 0]
        let score = VoicePrintMatcher.cosineSimilarity(a, b)
        let delta = abs(score + 1)
        #expect(delta < 1e-5)
    }

    @Test("mismatched dimensions return 0")
    func mismatchedDimensions() {
        let score = VoicePrintMatcher.cosineSimilarity([1, 0], [1, 0, 0])
        #expect(score == 0)
    }

    @Test("zero vector returns 0")
    func zeroVector() {
        let score = VoicePrintMatcher.cosineSimilarity([0, 0, 0], [1, 1, 1])
        #expect(score == 0)
    }

    @Test("best match returns the prints with the highest score above threshold")
    func bestMatch() {
        let alice = VoicePrint(name: "Alice", embedding: [1, 0, 0])
        let bob = VoicePrint(name: "Bob", embedding: [0, 1, 0])
        let prints = [alice, bob]
        let target: [Float] = [0.95, 0.1, 0]
        let result = VoicePrintMatcher.bestMatch(for: target, in: prints, threshold: 0.85)
        let name = result?.print.name
        let score = result?.score ?? 0
        #expect(name == "Alice")
        #expect(score > 0.85)
    }

    @Test("best match returns nil when no print clears the threshold")
    func bestMatchBelowThreshold() {
        let alice = VoicePrint(name: "Alice", embedding: [1, 0, 0])
        let result = VoicePrintMatcher.bestMatch(for: [0, 0, 1], in: [alice], threshold: 0.5)
        #expect(result == nil)
    }

    @Test("centroid averages embeddings element-wise")
    func centroid() {
        let centroid = VoicePrintMatcher.centroid(of: [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
        let expected: [Float] = [Float(1) / 3, Float(1) / 3, Float(1) / 3]
        #expect(centroid == expected)
    }

    @Test("centroid of empty array is empty")
    func centroidEmpty() {
        #expect(VoicePrintMatcher.centroid(of: []).isEmpty)
    }
}
