import AppKit
import Foundation

// Does NSSpellChecker work OFF the main thread, and from several at once?
let sem = DispatchSemaphore(value: 0)
var results: [String] = []
let lock = NSLock()
for i in 0..<8 {
  DispatchQueue.global(qos: .userInitiated).async {
    let tag = NSSpellChecker.uniqueSpellDocumentTag()
    var ok = 0
    for w in ["go", "send", "check", "zzzqx", "yesterday", "qwertyuiop"] {
      let r = NSSpellChecker.shared.checkSpelling(
        of: w, startingAt: 0, language: "en", wrap: false,
        inSpellDocumentWithTag: tag, wordCount: nil)
      let valid = r.location == NSNotFound
      // zzzqx and qwertyuiop must be INVALID; the rest valid.
      let expected = !(w == "zzzqx" || w == "qwertyuiop")
      if valid == expected { ok += 1 }
    }
    lock.lock(); results.append("thread\(i): \(ok)/6 correct, main=\(Thread.isMainThread)"); lock.unlock()
    sem.signal()
  }
}
for _ in 0..<8 { sem.wait() }
results.sorted().forEach { print($0) }
print("NSApp initialised: \(NSApplication.shared.isRunning == false ? "no (never called run)" : "yes")")

// Non-English language handling: does asking for a language we do not ship break?
let tag = NSSpellChecker.uniqueSpellDocumentTag()
for lang in ["en", "en_GB", "de", "xx", ""] {
  let r = NSSpellChecker.shared.checkSpelling(of: "colour", startingAt: 0, language: lang,
    wrap: false, inSpellDocumentWithTag: tag, wordCount: nil)
  print("language=\(lang.isEmpty ? "(empty)" : lang) 'colour' valid=\(r.location == NSNotFound)")
}
print("availableLanguages contains en: \(NSSpellChecker.shared.availableLanguages.contains { $0.hasPrefix("en") })")

// User's own learned words: does the checker honour them? (privacy/consistency)
print("userReplacements/learned words are per-user state — ignoreWord/learnWord exist: \(NSSpellChecker.shared.responds(to: #selector(NSSpellChecker.learnWord(_:))))")
