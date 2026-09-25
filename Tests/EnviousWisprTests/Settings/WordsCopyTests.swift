import SwiftUI
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPostProcessing

/// #3142: Your Words and contacts copy that used to splice "word"/"words", "name"/"names" or
/// "is"/"are" into a sentence now chooses whole sentences by count. Each oracle below rebuilds the
/// OLD spliced English independently, so the whole sentences must match it byte for byte at 0, 1
/// and 2. Unit tests run outside the app bundle, so they read English.
@Suite("Words and contacts copy", .tags(.productOutcome))
struct WordsCopyTests {

  /// 1_234 and 25_000 pin the digits: the numbers are passed as text, so English never gains a
  /// thousands separator the old spliced string did not have (#3142 G6).
  private static let counts = [0, 1, 2, 7, 1_234, 25_000]

  @Test("bulk delete says one word or many words, whole")
  func bulkDelete() {
    for n in Self.counts {
      let noun = n == 1 ? "word" : "words"
      #expect(BulkDeleteConfirmSheet.title(count: n) == "Delete \(n) \(noun)?")
      #expect(BulkDeleteConfirmSheet.deleteLabel(count: n) == "Delete \(n) \(noun)")
    }
  }

  @Test("the Contacts message matches the old frame for every count pair")
  func contactsMessage() {
    // The sheet shows these only when there is a new name (`hasNewNames`); 0 still reads as before.
    for new in [0, 1, 2, 5, 1_500] {
      let names = new == 1 ? "1 name" : "\(new) names"
      #expect(
        ContactsImportConfirm.addCountMessage(newCount: new, alreadyCount: 0)
          == "We'll add \(names) from your contacts.")
      #expect(ContactsImportConfirm.addButtonTitle(newCount: new) == "Add \(names)")
      for already in [1, 2, 9, 2_000] {
        let verb = already == 1 ? "is" : "are"
        #expect(
          ContactsImportConfirm.addCountMessage(newCount: new, alreadyCount: already)
            == "We'll add \(names) from your contacts. \(already) \(verb) already in your list.")
      }
    }
  }

  @Test("the import review summary matches the old frame")
  func importReviewSummary() {
    #expect(
      CustomWordsImportReviewCopy.summary(newCount: 0, existingCount: 0) == "Nothing to review.")
    for have in [1, 2, 20_000] {
      #expect(
        CustomWordsImportReviewCopy.summary(newCount: 0, existingCount: have)
          == "You already have all \(have) of these.")
    }
    for new in [1, 2, 1_500] {
      let noun = new == 1 ? "word" : "words"
      #expect(
        CustomWordsImportReviewCopy.summary(newCount: new, existingCount: 0)
          == "\(new) new \(noun) found.")
      for have in [1, 3, 20_000] {
        #expect(
          CustomWordsImportReviewCopy.summary(newCount: new, existingCount: have)
            == "\(new) new \(noun) found. \(have) you already have.")
      }
    }
  }

  @Test("list and sheet counts say one or many, whole")
  func smallCounts() {
    for n in Self.counts {
      #expect(
        CustomTermsSection<EmptyView>.wordCountLabel(n) == "\(n) \(n == 1 ? "word" : "words")")
      #expect(
        CustomWordEditSheet.mishearingCount(n) == "\(n) \(n == 1 ? "mishearing" : "mishearings")")
    }
  }

  @Test("a vocabulary pack's detail line matches the old frame")
  func packDetail() {
    for n in [0, 1, 2, 1_234] {
      let count = "\(n) \(n == 1 ? "fix" : "fixes")"
      #expect(VocabPacksSection.rowDetail(termCount: n, examples: []) == count)
      #expect(
        VocabPacksSection.rowDetail(termCount: n, examples: ["Kubernetes", "Postgres"])
          == "\(count) · e.g. Kubernetes, Postgres")
    }
  }

  @Test("the import result and skipped-spelling lines match the old frame")
  func importResult() {
    for added in [0, 1, 2, 1_234] {
      let phrase = "Added \(added) \(added == 1 ? "word" : "words")."
      #expect(
        CustomWordsImportResultCopy.message(for: .completed(added: added, replaced: 0))
          == "\(phrase) Your words are ready to use.")
      #expect(
        CustomWordsImportResultCopy.message(for: .completed(added: added, replaced: 3))
          == "\(phrase) Replaced 3. Your words are ready to use.")
    }
    for found in [0, 1, 2, 1_234] {
      #expect(
        CustomWordsImportResultCopy.message(for: .nothingCompatible(found: found))
          == "Found \(found) \(found == 1 ? "entry" : "entries"), but none were compatible. Nothing was changed."
      )
    }
    for n in [0, 1, 2, 1_234] {
      #expect(
        CustomWordsImportResultCopy.droppedCollisionMessage(count: n)
          == "\(n) alternate \(n == 1 ? "spelling was" : "spellings were") skipped, because other words already use them."
      )
    }
  }

  @Test("button, feedback and usage lines match the old frame")
  func buttonsAndUsage() {
    #expect(CustomWordsImportReviewCopy.confirmTitle(approvedCount: 0) == "Add nothing")
    for n in [1, 2, 7, 1_234] {
      #expect(
        CustomWordsImportReviewCopy.confirmTitle(approvedCount: n)
          == (n == 1 ? "Add 1 word" : "Add \(n) words"))
    }
    for n in Self.counts {
      #expect(LearningSection.addedFeedback(n) == (n == 1 ? "Added 1 name" : "Added \(n) names"))
    }
    // Usage 0 shows only the category; any use keeps the old "used N times", 1 included.
    #expect(
      CustomTermsSection<EmptyView>.usageSubtitle(category: .person, frequencyUsed: 0) == "Person")
    for n in [1, 2, 1_234] {
      #expect(
        CustomTermsSection<EmptyView>.usageSubtitle(category: .person, frequencyUsed: n)
          == "Person · used \(n) times")
    }
  }

  @Test("a review row's collision note matches the old frame")
  func collisionNote() {
    let owner = UUID()
    let other = UUID()
    let names = [owner: "Kubernetes"]
    #expect(CustomWordsImportReviewRow.collisionNote(for: [], namesByID: names) == nil)
    #expect(
      CustomWordsImportReviewRow.collisionNote(
        for: [CustomWordsImportAliasCollision(alias: "kube", heldBy: owner)], namesByID: names)
        == "The spelling \"kube\" may not be added, because Kubernetes already uses it.")
    #expect(
      CustomWordsImportReviewRow.collisionNote(
        for: [CustomWordsImportAliasCollision(alias: "kube", heldBy: other)], namesByID: names)
        == "1 alternate spelling may not be added, because other words already use them.")
    let two = [
      CustomWordsImportAliasCollision(alias: "kube", heldBy: owner),
      CustomWordsImportAliasCollision(alias: "k8s", heldBy: other),
    ]
    #expect(
      CustomWordsImportReviewRow.collisionNote(for: two, namesByID: names)
        == "2 alternate spellings may not be added, because other words already use them.")
  }

  @Test("a saved-words error logs fixed English and shows the same English on screen")
  func persistenceErrorDiagnostics() {
    let old: [(CustomWordsPersistenceError, String)] = [
      (
        .unreadableExistingFile,
        "Your saved words could not be read. Nothing was changed. Try again."
      ),
      (
        .corruptedExistingFile,
        "Your saved words file was damaged and moved aside for recovery. No edit or import was applied."
      ),
      (
        .unusableValue,
        "That word or spelling can't be saved. It may be too long, or contain characters that aren't part of a word."
      ),
      (
        .libraryBusy,
        "Your word list is being updated by another EnviousWispr window. Nothing was changed. Try again."
      ),
      (
        .coordinationUnavailable,
        "Your saved words could not be updated safely. Nothing was changed. Try again."
      ),
      (.noRestorableBuiltin, "That word is no longer where it was. Nothing was changed."),
    ]
    for (error, english) in old {
      #expect(error.diagnosticDescription == english)
      #expect(error.errorDescription == english)
    }
  }

  @Test("a category's shown name is its old capitalized raw value")
  func categoryNames() {
    for category in WordCategory.allCases {
      #expect(category.displayName == category.rawValue.capitalized)
    }
  }

  @Test("the supported-apps list reads as before for any number of apps")
  func appList() {
    #expect(SmartImportSupportedAppsCopy.sentence(joining: []) == "no apps yet")
    #expect(SmartImportSupportedAppsCopy.sentence(joining: ["A"]) == "A")
    #expect(SmartImportSupportedAppsCopy.sentence(joining: ["A", "B"]) == "A and B")
    #expect(SmartImportSupportedAppsCopy.sentence(joining: ["A", "B", "C"]) == "A, B, and C")
    #expect(
      SmartImportSupportedAppsCopy.sentence(joining: ["A", "B", "C", "D"]) == "A, B, C, and D")
  }
}
