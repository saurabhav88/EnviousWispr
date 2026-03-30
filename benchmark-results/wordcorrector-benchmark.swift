#!/usr/bin/env swift
// WordCorrector v2 Benchmark Harness
// Run from repo root: swift benchmark-results/wordcorrector-benchmark.swift
//
// Tests WordCorrector against a fixed test set and reports scores
// against the 100-point rubric.

import Foundation

// MARK: - Minimal WordCorrector replica (current baseline)
// We inline the corrector here so the benchmark is self-contained
// and can run without building the full project.

struct CustomWord {
    let canonical: String
    let aliases: [String]
    let category: String // "brand", "person", "acronym", "general", "domain"
}

// ============================================================
// MARK: - Test Data
// ============================================================

let builtinWords: [CustomWord] = [
    CustomWord(canonical: "EnviousWispr", aliases: ["envious whisper", "envious wisper", "envious whispr"], category: "brand"),
    CustomWord(canonical: "Envious Labs", aliases: ["envious laps"], category: "brand"),
    CustomWord(canonical: "macOS", aliases: ["mac OS", "Mack OS"], category: "brand"),
    CustomWord(canonical: "iOS", aliases: ["I OS", "eye OS"], category: "brand"),
    CustomWord(canonical: "GitHub", aliases: ["git hub", "get hub"], category: "brand"),
    CustomWord(canonical: "ChatGPT", aliases: ["chat GPT", "chat G P T"], category: "brand"),
    CustomWord(canonical: "OpenAI", aliases: ["open AI", "open A I"], category: "brand"),
    CustomWord(canonical: "Claude", aliases: ["clod", "clawed"], category: "brand"),
    CustomWord(canonical: "API", aliases: ["A P I"], category: "acronym"),
    CustomWord(canonical: "CLI", aliases: ["C L I"], category: "acronym"),
    CustomWord(canonical: "VS Code", aliases: ["vs code", "vscode", "V S code"], category: "brand"),
]

// User-added words for testing
let userWords: [CustomWord] = [
    CustomWord(canonical: "Saurabh", aliases: ["sorab", "sarub", "saw rub", "saw rubber"], category: "person"),
    CustomWord(canonical: "Malavika", aliases: ["mala vika", "malla vika"], category: "person"),
    CustomWord(canonical: "Kubernetes", aliases: ["kuber netties", "cube ernetes"], category: "domain"),
    CustomWord(canonical: "Parakeet", aliases: [], category: "brand"),
]

let allWords = builtinWords + userWords

// ============================================================
// MARK: - Test Cases
// ============================================================

struct TestCase {
    let bucket: String       // "case-only", "exact-alias", "near-miss-single", "near-miss-multi", "negative"
    let input: String
    let expected: String     // expected output (same as input for negatives)
    let description: String
}

let testCases: [TestCase] = [
    // Bucket 1: Case-only
    TestCase(bucket: "case-only", input: "parakeet", expected: "Parakeet", description: "lowercase canonical -> cased"),
    TestCase(bucket: "case-only", input: "claude", expected: "Claude", description: "lowercase brand -> cased"),
    TestCase(bucket: "case-only", input: "api", expected: "API", description: "lowercase acronym -> uppercased"),
    TestCase(bucket: "case-only", input: "cli", expected: "CLI", description: "lowercase acronym -> uppercased"),
    TestCase(bucket: "case-only", input: "macos", expected: "macOS", description: "lowercase -> mixed case"),
    TestCase(bucket: "case-only", input: "ios", expected: "iOS", description: "lowercase -> mixed case"),
    TestCase(bucket: "case-only", input: "github", expected: "GitHub", description: "lowercase -> camelCase"),
    TestCase(bucket: "case-only", input: "chatgpt", expected: "ChatGPT", description: "lowercase -> mixed case"),
    TestCase(bucket: "case-only", input: "openai", expected: "OpenAI", description: "lowercase -> mixed case"),
    TestCase(bucket: "case-only", input: "saurabh", expected: "Saurabh", description: "lowercase name -> cased"),

    // Bucket 2: Exact alias
    TestCase(bucket: "exact-alias", input: "envious whisper", expected: "EnviousWispr", description: "exact multi-word alias"),
    TestCase(bucket: "exact-alias", input: "envious wisper", expected: "EnviousWispr", description: "exact multi-word alias variant"),
    TestCase(bucket: "exact-alias", input: "envious whispr", expected: "EnviousWispr", description: "exact multi-word alias variant 2"),
    TestCase(bucket: "exact-alias", input: "envious laps", expected: "Envious Labs", description: "exact multi-word alias"),
    TestCase(bucket: "exact-alias", input: "chat GPT", expected: "ChatGPT", description: "exact multi-word alias"),
    TestCase(bucket: "exact-alias", input: "open AI", expected: "OpenAI", description: "exact multi-word alias"),
    TestCase(bucket: "exact-alias", input: "A P I", expected: "API", description: "exact alias spaced acronym"),
    TestCase(bucket: "exact-alias", input: "clod", expected: "Claude", description: "exact single-word alias"),
    TestCase(bucket: "exact-alias", input: "clawed", expected: "Claude", description: "exact single-word alias"),
    TestCase(bucket: "exact-alias", input: "git hub", expected: "GitHub", description: "exact multi-word alias"),
    TestCase(bucket: "exact-alias", input: "sorab", expected: "Saurabh", description: "exact single-word alias"),
    TestCase(bucket: "exact-alias", input: "sarub", expected: "Saurabh", description: "exact single-word alias"),
    TestCase(bucket: "exact-alias", input: "vscode", expected: "VS Code", description: "exact single-word alias"),
    TestCase(bucket: "exact-alias", input: "vs code", expected: "VS Code", description: "exact multi-word alias"),
    TestCase(bucket: "exact-alias", input: "mac OS", expected: "macOS", description: "exact alias"),
    TestCase(bucket: "exact-alias", input: "Mack OS", expected: "macOS", description: "exact alias"),
    TestCase(bucket: "exact-alias", input: "eye OS", expected: "iOS", description: "exact alias"),
    TestCase(bucket: "exact-alias", input: "get hub", expected: "GitHub", description: "exact alias"),
    TestCase(bucket: "exact-alias", input: "saw rubber", expected: "Saurabh", description: "exact multi-word alias"),
    TestCase(bucket: "exact-alias", input: "saw rub", expected: "Saurabh", description: "exact multi-word alias"),
    TestCase(bucket: "exact-alias", input: "kuber netties", expected: "Kubernetes", description: "exact multi-word alias"),

    // Bucket 3: Near-miss single-word (fuzzy)
    TestCase(bucket: "near-miss-single", input: "sorub", expected: "Saurabh", description: "near-miss of alias sorab"),
    TestCase(bucket: "near-miss-single", input: "sarab", expected: "Saurabh", description: "near-miss of alias sarub"),
    TestCase(bucket: "near-miss-single", input: "wisper", expected: "EnviousWispr", description: "near-miss of... nothing? no single alias"),
    TestCase(bucket: "near-miss-single", input: "gitub", expected: "GitHub", description: "typo of canonical"),
    TestCase(bucket: "near-miss-single", input: "chatgbt", expected: "ChatGPT", description: "typo of canonical"),
    TestCase(bucket: "near-miss-single", input: "kubernets", expected: "Kubernetes", description: "typo of canonical"),

    // Bucket 4: Near-miss multi-word (fuzzy)
    TestCase(bucket: "near-miss-multi", input: "envious visper", expected: "EnviousWispr", description: "1-char off from alias"),
    TestCase(bucket: "near-miss-multi", input: "envious wispar", expected: "EnviousWispr", description: "1-char off from alias"),
    TestCase(bucket: "near-miss-multi", input: "chat GBT", expected: "ChatGPT", description: "near-miss multi-word"),
    TestCase(bucket: "near-miss-multi", input: "open IA", expected: "OpenAI", description: "near-miss multi-word"),
    TestCase(bucket: "near-miss-multi", input: "kuber nettis", expected: "Kubernetes", description: "near-miss multi-word"),
    TestCase(bucket: "near-miss-multi", input: "mala vica", expected: "Malavika", description: "near-miss multi-word person name"),

    // Bucket 5: Negative controls (must NOT change)
    TestCase(bucket: "negative", input: "the api is good", expected: "the API is good", description: "api should correct but rest stays"),
    TestCase(bucket: "negative", input: "this is a cloud", expected: "this is a cloud", description: "cloud must not become Claude"),
    TestCase(bucket: "negative", input: "I use code every day", expected: "I use code every day", description: "code must not become VS Code"),
    TestCase(bucket: "negative", input: "that is a parakeet bird", expected: "that is a Parakeet bird", description: "parakeet case fix is OK"),
    TestCase(bucket: "negative", input: "I saw rub marks on the table", expected: "I saw rub marks on the table", description: "saw rub in context must not become Saurabh"),
    TestCase(bucket: "negative", input: "the club is open", expected: "the club is open", description: "ordinary words stay"),
    TestCase(bucket: "negative", input: "I need a clue", expected: "I need a clue", description: "clue must not become Claude"),
    TestCase(bucket: "negative", input: "he is a good man", expected: "he is a good man", description: "ordinary sentence stays"),
    TestCase(bucket: "negative", input: "check the status", expected: "check the status", description: "ordinary sentence stays"),
    TestCase(bucket: "negative", input: "the lab results are in", expected: "the lab results are in", description: "lab must not become Labs"),
]

// ============================================================
// MARK: - Scoring Engine (inline WordCorrector replica)
// ============================================================

func levenshteinSimilarity(_ a: String, _ b: String) -> Double {
    let a = Array(a), b = Array(b)
    let m = a.count, n = b.count
    if m == 0 { return n == 0 ? 1.0 : 0.0 }
    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    for i in 0...m { dp[i][0] = i }
    for j in 0...n { dp[0][j] = j }
    for i in 1...m {
        for j in 1...n {
            dp[i][j] = a[i-1] == b[j-1]
                ? dp[i-1][j-1]
                : 1 + min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1])
        }
    }
    return 1.0 - Double(dp[m][n]) / Double(max(m, n))
}

func bigramDice(_ a: String, _ b: String) -> Double {
    func bigrams(_ s: String) -> Set<String> {
        guard s.count >= 2 else { return [] }
        let chars = Array(s)
        return Set((0..<chars.count - 1).map { String([chars[$0], chars[$0+1]]) })
    }
    let ba = bigrams(a), bb = bigrams(b)
    guard !ba.isEmpty || !bb.isEmpty else { return a == b ? 1.0 : 0.0 }
    return 2.0 * Double(ba.intersection(bb).count) / Double(ba.count + bb.count)
}

let soundexMap: [Character: Character] = [
    "b":"1","f":"1","p":"1","v":"1",
    "c":"2","g":"2","j":"2","k":"2","q":"2","s":"2","x":"2","z":"2",
    "d":"3","t":"3","e":"0","i":"0","o":"0","u":"0","y":"0","h":"0","w":"0",
    "l":"4","m":"5","n":"5","r":"6",
]

func soundex(_ s: String) -> String {
    let lower = s.lowercased()
    guard let first = lower.first else { return "0000" }
    var code = String(first.uppercased())
    var last = soundexMap[first] ?? "0"
    for ch in lower.dropFirst() {
        guard let digit = soundexMap[ch] else { continue }
        if digit != "0" && digit != last {
            code.append(digit)
            if code.count == 4 { break }
        }
        last = digit
    }
    while code.count < 4 { code.append("0") }
    return code
}

func soundexScore(_ a: String, _ b: String) -> Double {
    soundex(a) == soundex(b) ? 1.0 : 0.0
}

func compositeScore(_ candidate: String, against target: String) -> Double {
    let lev = levenshteinSimilarity(candidate, target) * 0.40
    let bigram = bigramDice(candidate, target) * 0.40
    let sdx = soundexScore(candidate, target) * 0.20
    return lev + bigram + sdx
}

// ============================================================
// MARK: - WordCorrector (current baseline, bugs and all)
// ============================================================

func splitPunctuation(_ token: String) -> (prefix: String, core: String, suffix: String) {
    var prefix = "", core = token, suffix = ""
    while let first = core.first, !first.isLetter && !first.isNumber {
        prefix.append(first); core = String(core.dropFirst())
    }
    while let last = core.last, !last.isLetter && !last.isNumber {
        suffix = String(last) + suffix; core = String(core.dropLast())
    }
    return (prefix, core, suffix)
}

func stripPunctuation(_ token: String) -> String {
    splitPunctuation(token).core
}

func correctBaseline(_ text: String, against words: [CustomWord]) -> String {
    guard !words.isEmpty else { return text }

    var singleAliasMap: [String: String] = [:]
    var multiAliasMap: [String: String] = [:]
    for word in words {
        for alias in word.aliases {
            let key = alias.lowercased()
            if alias.contains(" ") {
                multiAliasMap[key] = word.canonical
            } else {
                singleAliasMap[key] = word.canonical
            }
        }
    }

    let canonicals = words.map(\.canonical)
    let lowercasedCanonicals = canonicals.map { $0.lowercased() }
    let threshold = 0.82

    var tokens = text.components(separatedBy: .whitespaces)

    // Pass 1: multi-word alias
    if !multiAliasMap.isEmpty {
        let maxSpan = multiAliasMap.keys.reduce(0) { max($0, $1.components(separatedBy: " ").count) }
        var i = 0
        while i < tokens.count {
            for span in stride(from: min(maxSpan, tokens.count - i), through: 2, by: -1) {
                let slice = tokens[i..<(i + span)]
                let phrase = slice.map { stripPunctuation($0).lowercased() }.joined(separator: " ")
                if let canonical = multiAliasMap[phrase], phrase != canonical.lowercased() {
                    let (firstPrefix, _, _) = splitPunctuation(tokens[i])
                    let (_, _, lastSuffix) = splitPunctuation(tokens[i + span - 1])
                    tokens.replaceSubrange(i..<(i + span), with: [firstPrefix + canonical + lastSuffix])
                    break
                }
            }
            i += 1
        }
    }

    // Pass 2+3: single alias + fuzzy
    let corrected = tokens.map { token -> String in
        let (prefix, core, suffix) = splitPunctuation(token)
        guard !core.isEmpty, core.count >= 2 else { return token }
        let coreLower = core.lowercased()

        if let canonical = singleAliasMap[coreLower], coreLower != canonical.lowercased() {
            return prefix + canonical + suffix
        }

        guard core.count >= 3 else { return token }

        var bestScore = 0.0
        var bestMatch = ""
        for (idx, targetLower) in lowercasedCanonicals.enumerated() {
            let s = compositeScore(coreLower, against: targetLower)
            if s > bestScore {
                bestScore = s
                bestMatch = canonicals[idx]
                if bestScore >= 1.0 { break }
            }
        }

        if bestScore >= threshold, coreLower != bestMatch.lowercased() {
            return prefix + bestMatch + suffix
        }
        return token
    }
    return corrected.joined(separator: " ")
}

// ============================================================
// MARK: - Run Benchmark
// ============================================================

struct BucketResult {
    var total = 0
    var passed = 0
    var failures: [(input: String, expected: String, got: String, desc: String)] = []
}

func runBenchmark(name: String, corrector: (String, [CustomWord]) -> String) {
    var buckets: [String: BucketResult] = [:]
    let startTime = DispatchTime.now()
    var totalPassed = 0
    var totalTests = 0

    for tc in testCases {
        let result = corrector(tc.input, allWords)
        let passed = result == tc.expected
        totalTests += 1
        if passed { totalPassed += 1 }

        var bucket = buckets[tc.bucket, default: BucketResult()]
        bucket.total += 1
        if passed {
            bucket.passed += 1
        } else {
            bucket.failures.append((tc.input, tc.expected, result, tc.description))
        }
        buckets[tc.bucket] = bucket
    }

    let endTime = DispatchTime.now()
    let elapsed = Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000

    // Latency test: run 100 iterations on a medium sentence
    let latencyInput = "I was talking to sorub about the envious visper project and the chat GBT integration with the open IA platform"
    let latencyStart = DispatchTime.now()
    let iterations = 1000
    for _ in 0..<iterations {
        _ = corrector(latencyInput, allWords)
    }
    let latencyEnd = DispatchTime.now()
    let avgLatencyUs = Double(latencyEnd.uptimeNanoseconds - latencyStart.uptimeNanoseconds) / Double(iterations) / 1000.0

    // Scale test: 200 words
    var scaled = allWords
    for i in 0..<200 {
        scaled.append(CustomWord(canonical: "TestWord\(i)", aliases: ["testvar\(i)", "testvr\(i)"], category: "general"))
    }
    let scaleStart = DispatchTime.now()
    for _ in 0..<100 {
        _ = corrector(latencyInput, scaled)
    }
    let scaleEnd = DispatchTime.now()
    let scaledLatencyUs = Double(scaleEnd.uptimeNanoseconds - scaleStart.uptimeNanoseconds) / 100.0 / 1000.0

    // Report
    print("=== \(name) ===")
    print("Total: \(totalPassed)/\(totalTests) passed (\(String(format: "%.1f", Double(totalPassed)/Double(totalTests)*100))%)")
    print("")

    let bucketOrder = ["case-only", "exact-alias", "near-miss-single", "near-miss-multi", "negative"]
    for bname in bucketOrder {
        guard let b = buckets[bname] else { continue }
        let pct = b.total > 0 ? String(format: "%.0f", Double(b.passed)/Double(b.total)*100) : "N/A"
        print("  [\(bname)] \(b.passed)/\(b.total) (\(pct)%)")
        for f in b.failures {
            print("    FAIL: \"\(f.input)\" -> expected \"\(f.expected)\", got \"\(f.got)\" (\(f.desc))")
        }
    }

    // Compute rubric scores
    let caseOnly = buckets["case-only", default: BucketResult()]
    let exactAlias = buckets["exact-alias", default: BucketResult()]
    let nearSingle = buckets["near-miss-single", default: BucketResult()]
    let nearMulti = buckets["near-miss-multi", default: BucketResult()]
    let negative = buckets["negative", default: BucketResult()]

    let nearMissTotal = nearSingle.total + nearMulti.total
    let nearMissPassed = nearSingle.passed + nearMulti.passed

    // Custom Term Recall = (case-only passed + exact-alias passed + near-miss passed) / (total positive tests)
    let positiveTotal = caseOnly.total + exactAlias.total + nearMissTotal
    let positivePassed = caseOnly.passed + exactAlias.passed + nearMissPassed
    let recall = positiveTotal > 0 ? Double(positivePassed) / Double(positiveTotal) * 100 : 0

    // False Replacement Rate = negative failures / negative total
    let falsePositiveRate = negative.total > 0 ? Double(negative.total - negative.passed) / Double(negative.total) * 100 : 0

    print("")
    print("--- Metrics ---")
    print("Custom Term Recall: \(String(format: "%.1f", recall))% (\(positivePassed)/\(positiveTotal))")
    print("False Replacement Rate: \(String(format: "%.1f", falsePositiveRate))% (\(negative.total - negative.passed)/\(negative.total))")
    print("Avg latency (15 words, \(allWords.count) custom words): \(String(format: "%.1f", avgLatencyUs)) us")
    print("Avg latency (15 words, \(scaled.count) custom words): \(String(format: "%.1f", scaledLatencyUs)) us")
    print("Benchmark suite time: \(String(format: "%.2f", elapsed)) ms")
    print("")
}

// ============================================================
// MARK: - Main
// ============================================================

print("WordCorrector Benchmark Harness")
print("Test set: \(testCases.count) cases across 5 buckets")
print("Custom words: \(allWords.count) (\(builtinWords.count) built-in + \(userWords.count) user)")
print("")

runBenchmark(name: "BASELINE (current code)", corrector: correctBaseline)

// ============================================================
// MARK: - WordCorrector V2 (new code)
// ============================================================

func correctV2(_ text: String, against words: [CustomWord]) -> String {
    guard !words.isEmpty else { return text }

    // --- Build lookup structures ---
    var singleAliasMap: [String: String] = [:]
    var multiAliasMap: [String: String] = [:]

    for word in words {
        for alias in word.aliases {
            let key = alias.lowercased()
            if alias.contains(" ") {
                multiAliasMap[key] = word.canonical
            } else {
                singleAliasMap[key] = word.canonical
            }
        }
    }

    // Canonical self-entries (explicit aliases win)
    for word in words {
        let key = word.canonical.lowercased()
        if !key.contains(" ") {
            if singleAliasMap[key] == nil {
                singleAliasMap[key] = word.canonical
            }
        }
    }

    let canonicals = words.map(\.canonical)
    let lowercasedCanonicals = canonicals.map { $0.lowercased() }
    let singleFuzzyCandidates = singleAliasMap.map { (surface: $0.key, canonical: $0.value) }

    var multiAliasByCount: [Int: [(alias: String, canonical: String)]] = [:]
    for (alias, canonical) in multiAliasMap {
        let count = alias.components(separatedBy: " ").count
        multiAliasByCount[count, default: []].append((alias, canonical))
    }

    let threshold = 0.82
    let multiWordThreshold = 0.85
    let shortTokenThreshold = 0.90
    let ambiguityMargin = 0.05
    let shortTokenMaxLength = 4

    var tokens = text.components(separatedBy: .whitespaces)

    // Pass 1 + 2: multi-word (exact then fuzzy)
    if !multiAliasMap.isEmpty {
        let maxSpan = multiAliasMap.keys.reduce(0) { max($0, $1.components(separatedBy: " ").count) }
        var i = 0
        while i < tokens.count {
            var matched = false

            for span in stride(from: min(maxSpan, tokens.count - i), through: 2, by: -1) {
                let slice = tokens[i..<(i + span)]
                let phrase = slice.map { stripPunctuation($0).lowercased() }.joined(separator: " ")
                let rawPhrase = slice.map { stripPunctuation($0) }.joined(separator: " ")

                if let canonical = multiAliasMap[phrase], rawPhrase != canonical {
                    let (firstPrefix, _, _) = splitPunctuation(tokens[i])
                    let (_, _, lastSuffix) = splitPunctuation(tokens[i + span - 1])
                    tokens.replaceSubrange(i..<(i + span), with: [firstPrefix + canonical + lastSuffix])
                    matched = true
                    break
                }
            }

            if !matched {
                for span in stride(from: min(maxSpan, tokens.count - i), through: 2, by: -1) {
                    let slice = tokens[i..<(i + span)]
                    let phrase = slice.map { stripPunctuation($0).lowercased() }.joined(separator: " ")
                    let rawPhrase = slice.map { stripPunctuation($0) }.joined(separator: " ")

                    if let candidates = multiAliasByCount[span] {
                        var bestScore = 0.0
                        var secondBest = 0.0
                        var bestCanonical = ""

                        for (alias, canonical) in candidates {
                            let s = compositeScore(phrase, against: alias)
                            if s > bestScore {
                                if bestCanonical != canonical { secondBest = bestScore }
                                bestScore = s
                                bestCanonical = canonical
                            } else if s > secondBest && canonical != bestCanonical {
                                secondBest = s
                            }
                        }

                        let margin = bestScore - secondBest
                        if bestScore >= multiWordThreshold,
                           margin >= ambiguityMargin,
                           rawPhrase != bestCanonical {
                            let (firstPrefix, _, _) = splitPunctuation(tokens[i])
                            let (_, _, lastSuffix) = splitPunctuation(tokens[i + span - 1])
                            tokens.replaceSubrange(i..<(i + span), with: [firstPrefix + bestCanonical + lastSuffix])
                            matched = true
                            break
                        }
                    }
                }
            }

            i += 1
        }
    }

    // Passes 3-5: single-word
    let corrected = tokens.map { token -> String in
        let (prefix, core, suffix) = splitPunctuation(token)
        guard !core.isEmpty, core.count >= 2 else { return token }
        let coreLower = core.lowercased()

        // Pass 3: exact single-word alias
        if let canonical = singleAliasMap[coreLower], core != canonical {
            return prefix + canonical + suffix
        }

        guard core.count >= 3 else { return token }

        let effectiveThreshold = core.count <= shortTokenMaxLength
            ? shortTokenThreshold
            : threshold

        // Pass 4: fuzzy against aliases
        let coreLen = coreLower.count
        var bestScore = 0.0
        var secondBest = 0.0
        var bestMatch = ""

        for (surface, canonical) in singleFuzzyCandidates {
            let surfLen = surface.count
            let lenRatio = Double(min(coreLen, surfLen)) / Double(max(coreLen, surfLen))
            if lenRatio < 0.5 { continue }

            let s = compositeScore(coreLower, against: surface)
            if s > bestScore {
                if bestMatch != canonical { secondBest = bestScore }
                bestScore = s
                bestMatch = canonical
            } else if s > secondBest && canonical != bestMatch {
                secondBest = s
            }
        }

        if bestScore >= effectiveThreshold,
           bestScore - secondBest >= ambiguityMargin,
           core != bestMatch {
            return prefix + bestMatch + suffix
        }

        // Pass 5: fuzzy against canonicals
        bestScore = 0.0
        secondBest = 0.0
        bestMatch = ""

        for (idx, targetLower) in lowercasedCanonicals.enumerated() {
            let targetLen = targetLower.count
            let lenRatio = Double(min(coreLen, targetLen)) / Double(max(coreLen, targetLen))
            if lenRatio < 0.5 { continue }

            let s = compositeScore(coreLower, against: targetLower)
            if s > bestScore {
                secondBest = bestScore
                bestScore = s
                bestMatch = canonicals[idx]
            } else if s > secondBest {
                secondBest = s
            }
        }

        if bestScore >= effectiveThreshold,
           bestScore - secondBest >= ambiguityMargin,
           core != bestMatch {
            return prefix + bestMatch + suffix
        }

        return token
    }
    return corrected.joined(separator: " ")
}

runBenchmark(name: "V2 + AMBIGUITY FIX", corrector: correctV2)
