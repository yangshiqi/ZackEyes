import SwiftUI

/// Deterministic pixel art avatar derived from a session ID.
/// Template and color selection adapt to the active BuddyTheme.
struct PixelAvatar: View {
    let seed: String
    var theme: BuddyTheme = .rock
    var teamColor: Color?     // F1: overrides palette with team livery color
    var size: CGFloat = 24

    var body: some View {
        Canvas { context, canvasSize in
            let templates = theme == .f1 ? Self.f1Templates : Self.rockTemplates
            let template = templates[Self.hash(seed) % templates.count]
            let color = teamColor ?? Self.paletteColor(for: seed, theme: theme)
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

    // MARK: - Hash + color helpers

    private static func hash(_ str: String) -> Int {
        var h = 5381
        for byte in str.utf8 {
            h = ((h << 5) &+ h) &+ Int(byte)
        }
        return abs(h)
    }

    private static func paletteColor(for seed: String, theme: BuddyTheme) -> Color {
        let palette = theme == .f1 ? f1Palette : rockPalette
        return palette[hash(seed + "color") % palette.count]
    }

    // MARK: - Rock templates (8x8) — guitar, skull, lightning, mic, etc.

    private static let rockTemplates: [[[Int]]] = [
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

    // Rock palette: deep reds, electric tones, neon accents
    private static let rockPalette: [Color] = [
        Color(red: 0.90, green: 0.15, blue: 0.20), // blood red
        Color(red: 0.96, green: 0.65, blue: 0.14), // amber
        Color(red: 0.30, green: 0.85, blue: 0.45), // neon green
        Color(red: 0.92, green: 0.35, blue: 0.50), // hot pink
        Color(red: 0.40, green: 0.55, blue: 0.95), // electric blue
        Color(red: 0.85, green: 0.75, blue: 0.20), // gold
        Color(red: 0.65, green: 0.30, blue: 0.95), // purple haze
        Color(red: 0.85, green: 0.85, blue: 0.85), // silver
    ]

    // MARK: - F1 templates (8x8) — racing iconography

    private static let f1Templates: [[[Int]]] = [
        // F1 car (top view)
        [
            [0, 0, 0, 1, 1, 0, 0, 0],
            [0, 1, 0, 1, 1, 0, 1, 0],
            [0, 1, 1, 1, 1, 1, 1, 0],
            [0, 0, 1, 1, 1, 1, 0, 0],
            [0, 0, 1, 1, 1, 1, 0, 0],
            [0, 1, 1, 1, 1, 1, 1, 0],
            [0, 1, 0, 1, 1, 0, 1, 0],
            [0, 0, 0, 1, 1, 0, 0, 0],
        ],
        // Racing helmet
        [
            [0, 0, 1, 1, 1, 1, 0, 0],
            [0, 1, 1, 1, 1, 1, 1, 0],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [1, 1, 0, 0, 0, 1, 1, 1],
            [1, 1, 0, 0, 0, 1, 1, 1],
            [1, 1, 1, 1, 1, 1, 1, 0],
            [0, 1, 1, 1, 1, 1, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
        ],
        // Checkered flag
        [
            [1, 0, 1, 0, 1, 0, 0, 0],
            [0, 1, 0, 1, 0, 1, 0, 0],
            [1, 0, 1, 0, 1, 0, 0, 0],
            [0, 1, 0, 1, 0, 1, 0, 0],
            [0, 0, 0, 0, 0, 1, 0, 0],
            [0, 0, 0, 0, 0, 1, 0, 0],
            [0, 0, 0, 0, 0, 1, 0, 0],
            [0, 0, 0, 0, 0, 1, 0, 0],
        ],
        // Steering wheel
        [
            [0, 0, 1, 1, 1, 1, 0, 0],
            [0, 1, 0, 0, 0, 0, 1, 0],
            [1, 0, 0, 0, 0, 0, 0, 1],
            [1, 1, 0, 1, 1, 0, 1, 1],
            [1, 1, 0, 1, 1, 0, 1, 1],
            [1, 0, 0, 0, 0, 0, 0, 1],
            [0, 1, 0, 0, 0, 0, 1, 0],
            [0, 0, 1, 1, 1, 1, 0, 0],
        ],
        // Trophy
        [
            [0, 0, 0, 1, 1, 0, 0, 0],
            [0, 0, 1, 1, 1, 1, 0, 0],
            [1, 0, 1, 1, 1, 1, 0, 1],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [0, 1, 1, 1, 1, 1, 1, 0],
            [0, 0, 0, 1, 1, 0, 0, 0],
            [0, 0, 1, 1, 1, 1, 0, 0],
            [0, 1, 1, 1, 1, 1, 1, 0],
        ],
        // Tire
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
        // Starting lights (2x3 grid)
        [
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 1, 1, 0, 0, 1, 1, 0],
            [0, 1, 1, 0, 0, 1, 1, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 1, 1, 0, 0, 1, 1, 0],
            [0, 1, 1, 0, 0, 1, 1, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [1, 1, 1, 1, 1, 1, 1, 1],
        ],
        // Wrench (pit crew)
        [
            [1, 0, 0, 0, 0, 0, 0, 1],
            [1, 1, 0, 0, 0, 0, 1, 1],
            [0, 1, 1, 0, 0, 1, 1, 0],
            [0, 0, 1, 1, 1, 1, 0, 0],
            [0, 0, 1, 1, 1, 1, 0, 0],
            [0, 1, 1, 0, 0, 1, 1, 0],
            [1, 1, 0, 0, 0, 0, 1, 1],
            [1, 0, 0, 0, 0, 0, 0, 1],
        ],
    ]

    // F1 fallback palette (used when no team color is provided)
    private static let f1Palette: [Color] = [
        Color(red: 0.91, green: 0.00, blue: 0.17), // Ferrari red
        Color(red: 1.00, green: 0.50, blue: 0.00), // McLaren papaya
        Color(red: 0.21, green: 0.44, blue: 0.78), // Red Bull blue
        Color(red: 0.15, green: 0.96, blue: 0.82), // Mercedes teal
        Color(red: 0.13, green: 0.60, blue: 0.44), // Aston Martin green
        Color(red: 1.00, green: 0.53, blue: 0.74), // Alpine pink
        Color(red: 0.39, green: 0.77, blue: 1.00), // Williams blue
        Color(red: 0.73, green: 0.73, blue: 0.74), // Haas silver
    ]

    // MARK: - F1 team colors (official 2026 livery primaries)

    /// Map team name → livery color. Keys must match the "from X" suffix
    /// in `BuddyTheme.f1Names`.
    static let f1TeamColors: [String: Color] = [
        "Red Bull":       Color(red: 0.21, green: 0.44, blue: 0.78), // #3671C6
        "McLaren":        Color(red: 1.00, green: 0.50, blue: 0.00), // #FF8000
        "Ferrari":        Color(red: 0.91, green: 0.00, blue: 0.17), // #E8002D
        "Mercedes":       Color(red: 0.15, green: 0.96, blue: 0.82), // #27F4D2
        "Aston Martin":   Color(red: 0.13, green: 0.60, blue: 0.44), // #229971
        "Alpine":         Color(red: 1.00, green: 0.53, blue: 0.74), // #FF87BC
        "Williams":       Color(red: 0.39, green: 0.77, blue: 1.00), // #64C4FF
        "Racing Bulls":   Color(red: 0.40, green: 0.57, blue: 1.00), // #6692FF
        "Haas":           Color(red: 0.71, green: 0.73, blue: 0.74), // #B6BABD
        "Audi":           Color(red: 0.32, green: 0.89, blue: 0.32), // #52E252
        "Cadillac":       Color(red: 0.85, green: 0.75, blue: 0.20), // #D9BF33 gold
    ]

    /// Extract team color from a buddy name like "Max from Red Bull".
    static func teamColor(forBuddyName name: String) -> Color? {
        guard let range = name.range(of: " from ") else { return nil }
        let team = String(name[range.upperBound...])
        return f1TeamColors[team]
    }
}
