import Foundation

/// Theme determines the naming pool and notification sound for all sessions.
public enum BuddyTheme: String, Codable, CaseIterable, Sendable {
    case rock
    case f1
    case silicon

    public var displayName: String {
        switch self {
        case .rock:    return "Rock Legends"
        case .f1:      return "F1 2026"
        case .silicon: return "AI 大佬"
        }
    }

    /// Available notification sounds for this theme. Each tuple is
    /// (display name, filename without extension). The first entry is
    /// the default when no explicit selection has been made.
    /// "none" is a reserved filename meaning silence (no sound).
    public var availableSounds: [(name: String, file: String)] {
        switch self {
        case .rock: return [
            ("Ba-dum 🥁",            "ba-dum"),
            ("Power Riff ⚡",        "guitar-riff"),
            ("Skull Crunch 💀",      "skull-guitar"),
            ("Stage Call 🎸",        "guitar-notif"),
            ("Pick Slide 🎶",        "guitar-quick"),
            ("None 🔇",              "none"),
        ]
        case .f1: return [
            ("Box Box 📻",           "box-box"),
            ("Get In There! 🏆",     "get-in-there"),
            ("FOR WHAT?! 😤",        "for-what"),
            ("Simply Lovely 😌",     "simply-lovely"),
            ("Super Max 🎵",         "super-max"),
            ("Team Radio 📡",        "team-radio"),
            ("F1 Radio 🏎️",          "f1-radio"),
            ("None 🔇",              "none"),
        ]
        case .silicon: return [
            ("AGI 🚀",            "agi-altman"),
            ("More Compute 💰",   "more-compute-jensen"),
            ("So Back 🔥",        "so-back"),
            ("Just Tokens 🎯",    "tokens-karpathy"),
            ("Race to the Top 🏁", "race-to-the-top-dario"),
            ("Move Fast ⚡",      "move-fast-zuck"),
            ("None 🔇",           "none"),
        ]
        }
    }

    /// Default sound filename for this theme (first in availableSounds).
    public var defaultSoundFile: String? {
        availableSounds.first?.file
    }

    var names: [String] {
        switch self {
        case .rock:    return Self.rockNames
        case .f1:      return Self.f1Names
        case .silicon: return Self.siliconNames
        }
    }

    var taglines: [String] {
        switch self {
        case .rock:    return Self.rockTaglines
        case .f1:      return Self.f1Taglines
        case .silicon: return Self.siliconTaglines
        }
    }

    // MARK: - Rock theme

    private static let rockNames: [String] = [
        // Classic rock
        "Freddie from Queen",
        "Mick from Stones",
        "Keith from Stones",
        "Robert from Zeppelin",
        "Jimmy from Zeppelin",
        "John from Zeppelin",
        "Roger from Floyd",
        "David from Floyd",
        "Pete from The Who",
        "Roger from The Who",
        "Eric from Cream",
        "Geddy from Rush",
        "Neil from Rush",
        "Peter from Genesis",
        "Jon from Yes",
        "Bowie from Mars",
        // Metal
        "Ozzy from Sabbath",
        "Tony from Sabbath",
        "Dio from Rainbow",
        "Lemmy from Motörhead",
        "James from Metallica",
        "Kirk from Metallica",
        "Cliff from Metallica",
        "Dave from Megadeth",
        "Bruce from Maiden",
        "Steve from Maiden",
        "Rob from Priest",
        "Max from Sepultura",
        "Chuck from Death",
        "Mikael from Opeth",
        "Randy from Lamb of God",
        "Devin from SYL",
        "Phil from Pantera",
        "Dimebag from Pantera",
        "Kerry from Slayer",
        "Tom from Slayer",
        "Corey from Slipknot",
        "Maynard from Tool",
        // Punk
        "Joey from Ramones",
        "Johnny from Ramones",
        "Dee Dee from Ramones",
        "Sid from Pistols",
        "Johnny from Pistols",
        "Joe from Clash",
        "Mick from Clash",
        "Henry from Black Flag",
        "Jello from DK",
        "Iggy from Stooges",
        "Patti from Smith Group",
        "Tim from Rancid",
        // Grunge / alt / post-punk
        "Kurt from Nirvana",
        "Dave from Foo Fighters",
        "Krist from Nirvana",
        "Eddie from Pearl Jam",
        "Chris from Soundgarden",
        "Layne from AIC",
        "Billy from Pumpkins",
        "Thom from Radiohead",
        "Ian from Joy Division",
        "Robert from The Cure",
        "Morrissey from Smiths",
        // Guns N' Roses, RHCP
        "Axl from GnR",
        "Slash from GnR",
        "Duff from GnR",
        "Anthony from RHCP",
        "Flea from RHCP",
        "John from RHCP",
        // Britpop
        "Liam from Oasis",
        "Noel from Oasis",
        // Rap / rock crossover
        "Zack from RATM",
        "Tom from RATM",
        "Tim from RATM",
        "Brad from RATM",
    ]

    private static let rockTaglines: [String] = [
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

    // MARK: - F1 2026 theme

    /// 2026 F1 grid — "🇳🇱 Driver from Team" format with nationality flags.
    private static let f1Names: [String] = [
        // Red Bull Racing
        "🇳🇱 Max from Red Bull",
        "🇫🇷 Isack from Red Bull",
        // McLaren
        "🇬🇧 Lando from McLaren",
        "🇦🇺 Oscar from McLaren",
        // Ferrari
        "🇲🇨 Charles from Ferrari",
        "🇬🇧 Lewis from Ferrari",
        // Mercedes
        "🇬🇧 George from Mercedes",
        "🇮🇹 Kimi from Mercedes",
        // Aston Martin
        "🇪🇸 Fernando from Aston Martin",
        "🇨🇦 Lance from Aston Martin",
        // Alpine
        "🇫🇷 Pierre from Alpine",
        "🇦🇷 Franco from Alpine",
        // Williams
        "🇪🇸 Carlos from Williams",
        "🇹🇭 Alex from Williams",
        // Racing Bulls
        "🇳🇿 Liam from Racing Bulls",
        "🇸🇪 Arvid from Racing Bulls",
        // Haas
        "🇫🇷 Esteban from Haas",
        "🇬🇧 Oliver from Haas",
        // Audi (formerly Sauber)
        "🇩🇪 Nico from Audi",
        "🇧🇷 Gabriel from Audi",
        // Cadillac (11th team, new for 2026)
        "🇲🇽 Sergio from Cadillac",
        "🇫🇮 Valtteri from Cadillac",
    ]

    /// Actual F1 team radio phrases.
    private static let f1Taglines: [String] = [
        "Box box, box box",
        "Copy, we are checking",
        "Get in there!",
        "Tires are gone, mate",
        "Slow button on, slow button on",
        "Push push push",
        "Keep your head down",
        "You are P1, P1",
        "Mega lap, mega lap",
        "Copy, understood",
        "OK so we'll talk after",
        "Blue flags! Blue flags!",
        "I am stupid, I am stupid",
        "All the time you have to leave a space",
        "Smooth operator",
        "It's lights out and away we go",
        "And it's go go go!",
        "Grazie ragazzi, grande lavoro",
        "Bono, my tires are dead",
        "No Michael no, that was so not right",
        "FOR WHAT?!",
        "Is that Glock?",
        "Honestly, what are we doing here",
    ]

    // MARK: - Silicon Valley AI moguls theme

    /// Silicon Valley + China AI moguls (34 total). Format: "{flag} {first-name} from {Org}".
    private static let siliconNames: [String] = [
        // Silicon Valley / Global (22)
        "🇺🇸 Sam from OpenAI",
        "🇺🇸 Greg from OpenAI",
        "🇮🇱 Ilya from SSI",
        "🇦🇱 Mira from Thinking Machines",
        "🇮🇹 Dario from Anthropic",
        "🇮🇹 Daniela from Anthropic",
        "🇬🇧 Demis from DeepMind",
        "🇹🇼 Jensen from Nvidia",
        "🇿🇦 Elon from xAI",
        "🇺🇸 Zuck from Meta",
        "🇮🇳 Sundar from Google",
        "🇮🇳 Satya from Microsoft",
        "🇨🇦 Geoff from Toronto",
        "🇫🇷 Yann from Meta",
        "🇨🇦 Yoshua from Mila",
        "🇸🇰 Andrej from Eureka",
        "🇨🇳 Fei-Fei from Stanford",
        "🇬🇧 Andrew from DeepLearning.AI",
        "🇮🇳 Aravind from Perplexity",
        "🇫🇷 Arthur from Mistral",
        "🇬🇧 Mustafa from MS AI",
        "🇮🇱 Noam from Character",
        // China (12)
        "🇨🇳 文锋 from DeepSeek",
        "🇨🇳 植麟 from Moonshot",
        "🇨🇳 Kai-Fu from 01.AI",
        "🇨🇳 小川 from Baichuan",
        "🇨🇳 一鸣 from ByteDance",
        "🇨🇳 兴兴 from Unitree",
        "🇨🇳 Robin from Baidu",
        "🇨🇳 Pony from Tencent",
        "🇨🇳 Ren from Huawei",
        "🇨🇳 鸿祎 from 360",
        "🇨🇳 慧文 from Light Year",
        "🇨🇳 扬清 from Lepton",
    ]

    /// Real AI-industry quotes, memes, and shibboleths (29 total).
    private static let siliconTaglines: [String] = [
        "AGI is coming",
        "We need more compute",
        "Just scale it",
        "Stochastic parrot",
        "The bitter lesson",
        "Attention is all you need",
        "The more you buy, the more you save",
        "Software is eating the world",
        "It's just matmul",
        "Move fast and break things",
        "e/acc — accelerate or die",
        "What's your p(doom)?",
        "Vibes-based eval",
        "The model is the product",
        "We are so back",
        "It's so over",
        "Scaling laws don't lie",
        "Just one more epoch bro",
        "Backprop through everything",
        "Race to the top",
        "Powerful AI",
        "Genius in a datacenter",
        "源神，启动！",
        "把成本打下来",
        "All in 大模型",
        "拥抱变化",
        "卷死他们",
        "幻觉是特性不是 bug",
        "百模大战",
    ]
}

/// A personality-driven character assigned to each session.
public struct Buddy {
    public let name: String
    public let tagline: String

    /// Deterministic buddy derived from session ID hash + current theme.
    public static func from(sessionId: String, theme: BuddyTheme? = nil) -> Buddy {
        let t = theme ?? ConfigStore().loadTheme()
        let nameIdx = hash(sessionId + ".name") % t.names.count
        let taglineIdx = hash(sessionId + ".tagline") % t.taglines.count
        return Buddy(name: t.names[nameIdx], tagline: t.taglines[taglineIdx])
    }

    private static func hash(_ s: String) -> Int {
        var h = 5381
        for b in s.utf8 { h = ((h << 5) &+ h) &+ Int(b) }
        return abs(h)
    }
}
