import Foundation

/// How Claude Code turns the description a call gave ("Run the tests") into its row while the call
/// runs and once it ran ("Running the tests", "Ran the tests"): its first word conjugated when it is
/// one of the verbs Claude Code knows, and a verb after "and" or "then" with it ("Build and run
/// tests" reads "Built and ran tests"). The same rules and word lists as the Claude desktop app's
/// Code screen (2026-10, `ion-dist`); a description that starts with anything else reads as written.
enum ClaudeDescriptionVerbs {
    struct Forms: Equatable, Sendable {
        let running: String
        let done: String
        /// The description after "Failed to" ("run the tests").
        let infinitive: String
    }

    /// The forms of `description`, kept once worked out: a running turn's rows ask again for every
    /// description each time the turn redraws, and the rules run several regular expressions.
    static func forms(of description: String) -> Forms? {
        if let kept = kept.forms(of: description) { return kept.forms }
        let forms = conjugated(description)
        kept.keep(forms, for: description)
        return forms
    }

    /// Descriptions already conjugated, at most `limit` of them; past that it starts over.
    private final class Kept: @unchecked Sendable {
        struct Entry { let forms: Forms? }
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        private let limit = 4_096

        func forms(of description: String) -> Entry? {
            lock.withLock { entries[description] }
        }

        func keep(_ forms: Forms?, for description: String) {
            lock.withLock {
                if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
                entries[description] = Entry(forms: forms)
            }
        }
    }

    private static let kept = Kept()

    static func conjugated(_ description: String) -> Forms? {
        let trimmed = String(description.drop(while: \.isWhitespace))
        let indent = String(description.prefix(description.count - trimmed.count))
        let wordEnd = trimmed.firstIndex(where: \.isWhitespace) ?? trimmed.endIndex
        guard wordEnd > trimmed.startIndex else { return nil }
        let word = String(trimmed[..<wordEnd])
        let rest = String(trimmed[wordEnd...])

        // A prefixed verb with a hyphen ("re-run") conjugates its stem.
        if let match = word.wholeMatch(of: /(?i)(re|un|de|pre|co|sub|over|out|mis|auto|post)-(.+)/),
           isVerbCandidate(String(match.2)) {
            let prefix = String(match.1), stem = String(match.2)
            let joined = (prefix + stem).lowercased(), lowerStem = stem.lowercased()
            if participles.contains(joined) || participles.contains(lowerStem)
                || (!verbs.contains(joined) && !verbs.contains(lowerStem)) {
                return nil
            }
            func form(_ irregular: [String: String], _ regular: (String) -> String) -> String {
                let tail = irregular[joined].map { String($0.dropFirst(prefix.count)) } ?? regular(stem)
                return prefix + "-" + matchingCase(stem, tail)
            }
            return Forms(running: indent + form(irregularRunning, presentParticiple) + conjugateFollowing(rest, presentParticiple),
                         done: indent + form(irregularPast, pastTense) + conjugateFollowing(rest, pastTense),
                         infinitive: indent + word.lowercased() + rest)
        }
        guard isVerbCandidate(word), verbs.contains(word.lowercased()) else { return nil }
        return Forms(
            running: indent + matchingCase(word, presentParticiple(word)) + conjugateFollowing(rest, presentParticiple),
            done: indent + matchingCase(word, pastTense(word)) + conjugateFollowing(rest, pastTense),
            infinitive: indent + word.prefix(1).lowercased() + String(word.dropFirst()) + rest
        )
    }

    // MARK: Rules

    /// "-ing": "run" → "running", "write" → "writing", "die" → "dying", "sync" → "syncing".
    static func presentParticiple(_ word: String) -> String {
        let lower = word.lowercased()
        if let irregular = irregularRunning[lower] { return irregular }
        if lower.hasSuffix("ie") { return String(word.dropLast(2)) + "ying" }
        if lower.wholeMatch(of: /.*[^eoy]e/) != nil { return String(word.dropLast()) + "ing" }
        if endsInShortSyllable(lower) && vowelCount(lower) == 1 { return word + String(word.suffix(1)) + "ing" }
        if lower.hasSuffix("c") { return word + "king" }
        return word + "ing"
    }

    /// Past tense: "run" → "ran", "update" → "updated", "copy" → "copied", "stop" → "stopped".
    static func pastTense(_ word: String) -> String {
        let lower = word.lowercased()
        if let irregular = irregularPast[lower] { return irregular }
        if lower.hasSuffix("e") { return word + "d" }
        if lower.wholeMatch(of: /.*[^aeiou]y/) != nil { return String(word.dropLast()) + "ied" }
        if endsInShortSyllable(lower) && vowelCount(lower) == 1 { return word + String(word.suffix(1)) + "ed" }
        if lower.hasSuffix("c") { return word + "ked" }
        if let running = irregularRunning[lower] { return String(running.dropLast(3)) + "ed" }
        return word + "ed"
    }

    /// A word that could be a verb's plain form: letters only, 2–16 long, not shouting, not already
    /// a past tense, "-ing" form or third person.
    private static func isVerbCandidate(_ word: String) -> Bool {
        guard (2...16).contains(word.count), word.allSatisfy({ $0.isASCII && $0.isLetter }),
              word != word.uppercased() else { return false }
        let lower = word.lowercased()
        if participles.contains(lower) { return false }
        if irregularPast[lower] != nil { return true }
        if lower.hasSuffix("ing") && word.count > 4 { return false }
        if lower.hasSuffix("ed") && !lower.hasSuffix("eed") && word.count > 3 { return false }
        if lower.hasSuffix("s") && !lower.hasSuffix("ss") && !lower.hasSuffix("us") && word.count > 3 { return false }
        return lower.contains(where: { "aeiouy".contains($0) })
    }

    /// The rest of the description with each verb after "and"/"then" conjugated too, unless what
    /// follows shows it is not an instruction ("check that the build works").
    private static func conjugateFollowing(_ text: String, _ form: (String) -> String) -> String {
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in following.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let verb = source.substring(with: match.range(at: 2))
            let after = source.substring(from: match.range.location + match.range.length)
            guard followingVerbs.contains(verb),
                  notInstruction.firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length)) == nil
            else { continue }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += source.substring(with: match.range(at: 1)) + form(verb)
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }

    private static func matchingCase(_ original: String, _ form: String) -> String {
        guard let first = original.first, first.isUppercase else { return form }
        return form.prefix(1).uppercased() + form.dropFirst()
    }

    private static func endsInShortSyllable(_ lower: String) -> Bool {
        lower.wholeMatch(of: /.*[^aeiou][aeiou][bcdfghjklmnpqrstvz]/) != nil
    }

    private static func vowelCount(_ lower: String) -> Int {
        lower.filter { "aeiou".contains($0) }.count
    }

    private static let following = try! NSRegularExpression(
        pattern: #"(?<![\w-])((?:(?:[Aa]nd|[Tt]hen)\s+)+)([a-z]{2,16})(?=$|[\s,;!?]|\.(?:\s|$))"#
    )
    private static let notInstruction = try! NSRegularExpression(
        pattern: #"^(?:\s+\w+){0,2}\s+(?:is|are|was|were|has|have|do|does|did|will|would|should|can|could|passes|passed|fails|failed|exists|works|worked|succeeds|succeeded|stays|remains|looks|runs|ran|not|if|when|unless|whether)(?:n['’]t)?\b"#
    )

    // MARK: Words

    static let irregularPast: [String: String] = [
        "begin": "began", "bind": "bound", "bring": "brought", "build": "built", "buy": "bought",
        "catch": "caught", "choose": "chose", "come": "came", "cut": "cut", "debug": "debugged", "dig": "dug",
        "do": "did", "draw": "drew", "feed": "fed", "feel": "felt", "fight": "fought", "find": "found",
        "fly": "flew", "forget": "forgot", "freeze": "froze", "get": "got", "give": "gave", "go": "went",
        "have": "had", "hide": "hid", "hit": "hit", "hold": "held", "input": "input", "keep": "kept",
        "know": "knew", "lead": "led", "leave": "left", "let": "let", "lose": "lost", "make": "made",
        "mean": "meant", "meet": "met", "override": "overrode", "overwrite": "overwrote", "pay": "paid",
        "put": "put", "quit": "quit", "read": "read", "rebuild": "rebuilt", "redo": "redid", "rerun": "reran",
        "reset": "reset", "rewrite": "rewrote", "run": "ran", "see": "saw", "seek": "sought", "send": "sent",
        "set": "set", "show": "showed", "shut": "shut", "sit": "sat", "sleep": "slept", "spend": "spent",
        "spin": "spun", "split": "split", "spread": "spread", "stand": "stood", "sweep": "swept",
        "sync": "synced", "take": "took", "teach": "taught", "tear": "tore", "tell": "told",
        "think": "thought", "throw": "threw", "understand": "understood", "undo": "undid", "unset": "unset",
        "win": "won", "unwrap": "unwrapped", "unzip": "unzipped", "write": "wrote"
    ]

    static let irregularRunning: [String: String] = [
        "begin": "beginning", "commit": "committing", "control": "controlling", "debug": "debugging",
        "emit": "emitting", "equip": "equipping", "forget": "forgetting", "format": "formatting",
        "input": "inputting", "occur": "occurring", "omit": "omitting", "output": "outputting",
        "permit": "permitting", "prefer": "preferring", "quit": "quitting", "refer": "referring",
        "rerun": "rerunning", "reset": "resetting", "screenshot": "screenshotting",
        "snapshot": "snapshotting", "submit": "submitting", "sync": "syncing", "transfer": "transferring",
        "unset": "unsetting", "unwrap": "unwrapping", "unzip": "unzipping"
    ]

    /// Past forms and participles, which are never a description's plain verb.
    private static let participles: Set<String> = Set(irregularPast.filter { $0.key != $0.value }.map(\.value))
        .union(["been", "broken", "chosen", "done", "drawn", "driven", "eaten", "fallen", "forgotten", "given",
                "gone", "grown", "hidden", "known", "ridden", "risen", "seen", "shown", "spoken", "taken",
                "thrown", "torn", "worn", "written"])

    private static let listedVerbs: Set<String> = Set("""
    add analyze append apply archive assert attempt audit autofix await benchmark bisect call capture check click \
    clone collect compare compile compute confirm connect convert copy count create curl decode delete deploy \
    detect disable discard dismiss display download dump edit emit enable encode ensure enumerate evaluate \
    execute expand expect export extract fetch fill filter fix flush focus follow generate grep identify ignore \
    import include inject insert inspect install invoke kill launch lint list load locate loop measure merge \
    monitor move navigate normalize parse patch pick ping pipe poll post prepare preview print probe profile \
    prune publish pull push queue rebase recheck record recover redirect reduce refresh regenerate reinstall \
    relaunch reload remove rename render reopen repeat replay reply report request resolve restart restore \
    retry revert save scan screenshot scroll search select serialize serve settle skip snapshot sort spawn \
    squash stage start stash stop strip summarize switch sync tail tally test toggle touch trace track trigger \
    trim truncate try typecheck unblock uninstall unlink unmount unpack update upgrade upload validate verify \
    visit wait walk warn wipe
    """.split(separator: " ").map(String.init))

    /// Every verb Claude Code conjugates.
    static let verbs: Set<String> = listedVerbs.union(irregularPast.keys).union(irregularRunning.keys)

    /// The verbs it conjugates after "and"/"then": not those that read as nouns or states there.
    private static let followingVerbs: Set<String> = verbs.subtracting("""
    output input lead feed spread set cut split hit let put quit shut read go make dig tear win fly spin control \
    permit have hold keep mean feel do see know think understand
    """.split(separator: " ").map(String.init))
}
