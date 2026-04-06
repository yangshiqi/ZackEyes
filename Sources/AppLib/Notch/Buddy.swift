import Foundation

/// A personality-driven character assigned to each session.
public struct Buddy {
    public let name: String
    public let tagline: String

    /// Deterministic buddy derived from session ID hash.
    public static func from(sessionId: String) -> Buddy {
        let nameIdx = hash(sessionId + ".name") % names.count
        let taglineIdx = hash(sessionId + ".tagline") % taglines.count
        return Buddy(name: names[nameIdx], tagline: taglines[taglineIdx])
    }

    private static func hash(_ s: String) -> Int {
        var h = 5381
        for b in s.utf8 { h = ((h << 5) &+ h) &+ Int(b) }
        return abs(h)
    }

    // MARK: - Pools

    public static let names: [String] = [
        "Pixel", "Byte", "Nibble", "Turbo", "Glitch", "Blip", "Bitsy",
        "Scout", "Patch", "Hex", "Rune", "Zap", "Echo", "Fizz",
        "Mochi", "Boba", "Dango", "Nori", "Yuzu", "Sakura",
        "Gizmo", "Widget", "Sprocket", "Cog", "Bolt", "Circuit",
        "Cosmo", "Nova", "Vega", "Orion", "Comet", "Pulsar",
        "Ember", "Pyro", "Frost", "Mist", "Thorn", "Moss",
        "Taco", "Waffle", "Pickle", "Bagel", "Pretzel", "Cookie",
        "Ziggy", "Doodle", "Scoop", "Pogo", "Tater", "Waffles",
        "Quark", "Muon", "Boson", "Lepton", "Photon", "Graviton",
    ]

    public static let taglines: [String] = [
        "Always hungry for bytes",
        "Compiles with confidence",
        "Lives on the stack",
        "Refactors in its sleep",
        "Speaks fluent regex",
        "Caffeinated and dangerous",
        "Deletes code for fun",
        "Never trusts the cache",
        "Dreams in binary",
        "Merges without conflict",
        "Debugs through vibes",
        "Git blame? Not this time",
        "Writes tests first, really",
        "Explores the edge cases",
        "Prefers tabs over spaces",
        "Or is it spaces over tabs?",
        "Type-safe since day one",
        "No null pointer exceptions",
        "Reads the docs (sometimes)",
        "Rebase champion 2026",
        "Main branch respecter",
        "Thinks before it types",
        "Commits with meaning",
        "Lives for the green checkmark",
        "Always returns early",
        "Fears the global scope",
        "Loves pure functions",
        "Questions all mutations",
        "Small PRs only",
        "Ships on Fridays (don't)",
    ]
}
