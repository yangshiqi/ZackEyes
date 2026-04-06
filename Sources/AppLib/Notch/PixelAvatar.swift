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

    // MARK: - Avatar templates (8x8 pixel grids, 1 = filled)

    private static let templates: [[[Int]]] = [
        // Classic invader 1
        [
            [0, 0, 1, 1, 1, 1, 0, 0],
            [0, 1, 1, 1, 1, 1, 1, 0],
            [1, 1, 0, 1, 1, 0, 1, 1],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [0, 1, 1, 1, 1, 1, 1, 0],
            [1, 0, 1, 0, 0, 1, 0, 1],
            [0, 1, 0, 0, 0, 0, 1, 0],
            [1, 0, 0, 0, 0, 0, 0, 1],
        ],
        // Classic invader 2 (crab)
        [
            [0, 0, 1, 0, 0, 1, 0, 0],
            [1, 0, 1, 0, 0, 1, 0, 1],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [1, 1, 0, 1, 1, 0, 1, 1],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [0, 1, 0, 1, 1, 0, 1, 0],
            [1, 0, 0, 0, 0, 0, 0, 1],
            [0, 1, 0, 0, 0, 0, 1, 0],
        ],
        // Classic invader 3 (octopus)
        [
            [0, 1, 1, 1, 1, 1, 1, 0],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [1, 1, 0, 1, 1, 0, 1, 1],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [0, 0, 1, 0, 0, 1, 0, 0],
            [0, 1, 1, 1, 1, 1, 1, 0],
            [1, 0, 1, 0, 0, 1, 0, 1],
            [1, 0, 0, 0, 0, 0, 0, 1],
        ],
        // Robot
        [
            [0, 1, 1, 1, 1, 1, 1, 0],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [1, 0, 1, 1, 1, 1, 0, 1],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [1, 1, 0, 0, 0, 0, 1, 1],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [0, 1, 0, 1, 1, 0, 1, 0],
            [1, 0, 0, 0, 0, 0, 0, 1],
        ],
        // Ghost
        [
            [0, 1, 1, 1, 1, 1, 1, 0],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [1, 0, 0, 1, 1, 0, 0, 1],
            [1, 0, 0, 1, 1, 0, 0, 1],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [1, 0, 1, 0, 1, 0, 1, 0],
        ],
        // Blob
        [
            [0, 0, 1, 1, 1, 1, 0, 0],
            [0, 1, 1, 1, 1, 1, 1, 0],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [1, 1, 0, 1, 1, 0, 1, 1],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [0, 1, 1, 1, 1, 1, 1, 0],
            [1, 0, 0, 1, 1, 0, 0, 1],
        ],
    ]

    private static let palette: [Color] = [
        Color(red: 0.31, green: 0.80, blue: 0.77), // teal
        Color(red: 0.96, green: 0.65, blue: 0.14), // orange
        Color(red: 0.55, green: 0.75, blue: 0.32), // green
        Color(red: 0.92, green: 0.35, blue: 0.50), // pink
        Color(red: 0.40, green: 0.55, blue: 0.95), // blue
        Color(red: 0.85, green: 0.75, blue: 0.30), // yellow
        Color(red: 0.65, green: 0.45, blue: 0.95), // purple
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
