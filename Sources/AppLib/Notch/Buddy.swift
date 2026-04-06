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

    /// Rock / metal / punk legends. Format: "First from Band" as tribute.
    public static let names: [String] = [
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
