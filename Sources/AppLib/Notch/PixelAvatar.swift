import SwiftUI

/// Deterministic pixel art avatar derived from a session ID.
/// Generates one of several "space invader" style characters with a color.
struct PixelAvatar: View {
    let seed: String
    var size: CGFloat = 24

    var body: some View {
        Canvas { context, canvasSize in
            let template = Self.templates[Self.templateIndex(for: seed)]
            let color = Self.color(for: seed)
            let cellSize = canvasSize.width / CGFloat(template[0].count)

            for (row, line) in template.enumerated() {
                for (col, cell) in line.enumerated() {
                    guard cell == 1 else { continue }
                    let rect = CGRect(
                        x: CGFloat(col) * cellSize,
                        y: CGFloat(row) * cellSize,
                        width: cellSize,
                        height: cellSize
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - Avatar templates — generic rock/metal iconography
    // (8x8 pixel grids, 1 = filled). These are original designs evoking
    // rock/metal/punk themes without reproducing any specific band's logo.

    private static let templates: [[[Int]]] = [
        // Electric guitar (angled)
        [
            [0, 0, 0, 0, 0, 1, 1, 0],
            [0, 0, 0, 0, 1, 1, 0, 0],
            [0, 0, 0, 1, 1, 0, 0, 0],
            [0, 1, 1, 1, 0, 0, 0, 0],
            [1, 1, 1, 1, 0, 0, 0, 0],
            [1, 1, 1, 1, 0, 0, 0, 0],
            [0, 1, 1, 1, 0, 0, 0, 0],
            [0, 0, 1, 0, 0, 0, 0, 0],
        ],
        // Skull
        [
            [0, 0, 1, 1, 1, 1, 0, 0],
            [0, 1, 1, 1, 1, 1, 1, 0],
            [1, 1, 0, 1, 1, 0, 1, 1],
            [1, 1, 0, 1, 1, 0, 1, 1],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [0, 1, 1, 0, 0, 1, 1, 0],
            [0, 1, 0, 1, 1, 0, 1, 0],
            [0, 1, 0, 1, 1, 0, 1, 0],
        ],
        // Lightning bolt
        [
            [0, 0, 0, 1, 1, 1, 0, 0],
            [0, 0, 1, 1, 1, 0, 0, 0],
            [0, 1, 1, 1, 0, 0, 0, 0],
            [1, 1, 1, 1, 1, 0, 0, 0],
            [0, 0, 0, 1, 1, 0, 0, 0],
            [0, 0, 1, 1, 0, 0, 0, 0],
            [0, 1, 1, 0, 0, 0, 0, 0],
            [1, 1, 0, 0, 0, 0, 0, 0],
        ],
        // Microphone
        [
            [0, 0, 1, 1, 1, 0, 0, 0],
            [0, 1, 1, 1, 1, 1, 0, 0],
            [0, 1, 1, 0, 1, 1, 0, 0],
            [0, 1, 1, 1, 1, 1, 0, 0],
            [0, 1, 1, 0, 1, 1, 0, 0],
            [0, 0, 1, 1, 1, 0, 0, 0],
            [0, 0, 0, 1, 0, 0, 0, 0],
            [0, 0, 1, 1, 1, 0, 0, 0],
        ],
        // Drum kit
        [
            [0, 1, 1, 1, 1, 1, 1, 0],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [1, 0, 1, 0, 1, 0, 1, 0],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [1, 0, 1, 0, 1, 0, 1, 0],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [0, 1, 1, 1, 1, 1, 1, 0],
            [0, 0, 1, 0, 0, 1, 0, 0],
        ],
        // Vinyl record
        [
            [0, 0, 1, 1, 1, 1, 0, 0],
            [0, 1, 1, 1, 1, 1, 1, 0],
            [1, 1, 0, 0, 0, 0, 1, 1],
            [1, 1, 0, 1, 1, 0, 1, 1],
            [1, 1, 0, 1, 1, 0, 1, 1],
            [1, 1, 0, 0, 0, 0, 1, 1],
            [0, 1, 1, 1, 1, 1, 1, 0],
            [0, 0, 1, 1, 1, 1, 0, 0],
        ],
        // Five-point star
        [
            [0, 0, 0, 1, 0, 0, 0, 0],
            [0, 0, 0, 1, 1, 0, 0, 0],
            [0, 0, 1, 1, 1, 0, 0, 0],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [0, 1, 1, 1, 1, 1, 1, 0],
            [0, 0, 1, 1, 1, 1, 0, 0],
            [0, 1, 1, 0, 0, 1, 1, 0],
            [1, 1, 0, 0, 0, 0, 1, 1],
        ],
        // Crossbones
        [
            [1, 1, 0, 0, 0, 0, 1, 1],
            [1, 1, 1, 0, 0, 1, 1, 1],
            [0, 1, 1, 1, 1, 1, 1, 0],
            [0, 0, 1, 1, 1, 1, 0, 0],
            [0, 0, 1, 1, 1, 1, 0, 0],
            [0, 1, 1, 1, 1, 1, 1, 0],
            [1, 1, 1, 0, 0, 1, 1, 1],
            [1, 1, 0, 0, 0, 0, 1, 1],
        ],
        // Cassette tape
        [
            [1, 1, 1, 1, 1, 1, 1, 1],
            [1, 0, 0, 0, 0, 0, 0, 1],
            [1, 0, 1, 1, 1, 1, 0, 1],
            [1, 0, 1, 0, 0, 1, 0, 1],
            [1, 0, 1, 1, 1, 1, 0, 1],
            [1, 0, 0, 0, 0, 0, 0, 1],
            [1, 1, 0, 1, 1, 0, 1, 1],
            [1, 0, 0, 1, 1, 0, 0, 1],
        ],
    ]

    // Rock-appropriate palette: deep reds, electric tones, neon accents
    private static let palette: [Color] = [
        Color(red: 0.90, green: 0.15, blue: 0.20), // blood red
        Color(red: 0.96, green: 0.65, blue: 0.14), // amber
        Color(red: 0.30, green: 0.85, blue: 0.45), // neon green
        Color(red: 0.92, green: 0.35, blue: 0.50), // hot pink
        Color(red: 0.40, green: 0.55, blue: 0.95), // electric blue
        Color(red: 0.85, green: 0.75, blue: 0.20), // gold
        Color(red: 0.65, green: 0.30, blue: 0.95), // purple haze
        Color(red: 0.85, green: 0.85, blue: 0.85), // silver
    ]

    private static func hash(_ str: String) -> Int {
        var h = 5381
        for byte in str.utf8 {
            h = ((h << 5) &+ h) &+ Int(byte)
        }
        return abs(h)
    }

    private static func templateIndex(for seed: String) -> Int {
        hash(seed) % templates.count
    }

    private static func color(for seed: String) -> Color {
        // Use a different hash offset for color so similar seeds get different colors
        let h = hash(seed + "color") % palette.count
        return palette[h]
    }
}
