import SwiftUI

struct ConfettiBurstView: View {
    private let pieces: [ConfettiPiece]

    init(count: Int = 14) {
        var pieces: [ConfettiPiece] = []
        for i in 0..<count {
            let angle = Double.random(in: 0...(.pi * 2))
            let distance = Double.random(in: 80...160)
            let delay = Double.random(in: 0...0.15)
            let hueShift = Double(i) / Double(count)
            pieces.append(ConfettiPiece(
                id: i,
                dx: CGFloat(cos(angle) * distance),
                dy: CGFloat(sin(angle) * distance),
                delay: delay,
                hueShift: hueShift,
                size: CGFloat.random(in: 6...10)
            ))
        }
        self.pieces = pieces
    }

    var body: some View {
        ZStack {
            ForEach(pieces) { piece in
                ConfettiDot(piece: piece)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ConfettiPiece: Identifiable {
    let id: Int
    let dx: CGFloat
    let dy: CGFloat
    let delay: Double
    let hueShift: Double
    let size: CGFloat
}

private struct ConfettiDot: View {
    let piece: ConfettiPiece
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: piece.size, height: piece.size)
            .scaleEffect(animate ? 1 : 0)
            .offset(x: animate ? piece.dx : 0, y: animate ? piece.dy : 0)
            .opacity(animate ? 0 : 1)
            .animation(
                .spring(response: 0.9, dampingFraction: 0.6).delay(piece.delay),
                value: animate
            )
            .onAppear {
                animate = true
            }
    }

    private var color: Color {
        let palette: [Color] = [
            .accentColor,
            .accentColor.opacity(0.6),
            .yellow,
            .pink,
            .green
        ]
        let index = Int(piece.hueShift * Double(palette.count)) % palette.count
        return palette[index]
    }
}
