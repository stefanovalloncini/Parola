import Foundation

public enum VoicePrintMatcher {
    public struct Match: Equatable, Sendable {
        public let print: VoicePrint
        public let score: Float
    }

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var magA: Float = 0
        var magB: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            magA += a[index] * a[index]
            magB += b[index] * b[index]
        }
        guard magA > 0, magB > 0 else { return 0 }
        return dot / (sqrt(magA) * sqrt(magB))
    }

    public static func bestMatch(
        for embedding: [Float],
        in prints: [VoicePrint],
        threshold: Float
    ) -> Match? {
        var best: Match?
        for print in prints {
            let score = cosineSimilarity(embedding, print.embedding)
            guard score >= threshold else { continue }
            if score > (best?.score ?? -.infinity) {
                best = Match(print: print, score: score)
            }
        }
        return best
    }

    public static func centroid(of embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var out = [Float](repeating: 0, count: first.count)
        var counted = 0
        for embedding in embeddings where embedding.count == first.count {
            for index in embedding.indices { out[index] += embedding[index] }
            counted += 1
        }
        guard counted > 0 else { return [] }
        for index in out.indices { out[index] /= Float(counted) }
        return out
    }

    static func rollingAverage(existing: [Float], existingCount: Int, incoming: [Float]) -> [Float] {
        guard existing.count == incoming.count, existingCount > 0 else { return incoming }
        let n = Float(existingCount)
        var out = [Float](repeating: 0, count: existing.count)
        for index in existing.indices {
            out[index] = (existing[index] * n + incoming[index]) / (n + 1)
        }
        return out
    }
}
