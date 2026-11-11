import Foundation

/// The learned-word check as the helper serves it (#4473 P3): what a `POST /v1/wordcheck`
/// body must be, the prompt each question becomes, and the answer's form.
///
/// A request: `{"model":"eg-1","questions":[{"id":17,"word":"Tuist","context":"Use Twist.",
/// "rewritten":"Use Tuist."}]}`, with 1 to 8 questions. The answer:
/// `{"scores":[{"id":17,"pA":0.1,"pB":0.9}]}`, one score for each question, in the order asked.
/// The helper gives the two probabilities only: the app owns the ratio and the threshold.
///
/// The prompt is the one each size's adapter was trained and scored on, byte for byte (the same
/// text the llama engine's checker sends for EG-1). It is written here because the helper is a
/// separate process that imports no app module; the helper's integration test compares the
/// scores of this route with scores of the app's own prompt text.
enum HelperWordCheck {
  static let path = "/v1/wordcheck"
  static let maximumQuestions = 8

  static let systemPrompt =
    "[Task: check] A word from the user's dictionary may have been misheard in a dictated sentence. A is the sentence as transcribed. B writes the dictionary word at one spot. Answer B only if the speaker meant the dictionary word there; otherwise answer A. Answer with one letter."

  /// The two answer letters. Each must be one token of the loaded tokenizer.
  static let answers = (a: "A", b: "B")

  struct Question: Equatable {
    let id: Int
    let word: String
    let context: String
    let rewritten: String
  }

  /// Why a body is not a word-check request. The text goes back to the app and never holds
  /// a question's own text.
  struct Refusal: Error, Equatable {
    let message: String
  }

  static func prompt(for question: Question) -> String {
    "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"
      + "<|im_start|>user\nDictionary word: \(question.word)\n"
      + "A: \(question.context)\nB: \(question.rewritten)<|im_end|>\n"
      + "<|im_start|>assistant\n"
  }

  /// Reads a request body strictly: exactly the two top-level fields, the selected model, 1 to
  /// 8 questions, each with exactly its four fields, a whole-number id used once, and three
  /// non-empty texts. Anything else is refused; nothing is ignored or repaired.
  static func parse(body: Data, modelName: String) throws -> [Question] {
    guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
      throw Refusal(message: "the body is not a JSON object")
    }
    guard Set(object.keys) == ["model", "questions"] else {
      throw Refusal(message: "the body must hold exactly model and questions")
    }
    guard let model = object["model"] as? String, model == modelName else {
      throw Refusal(message: "model is not the selected model")
    }
    guard let entries = object["questions"] as? [Any],
      (1...maximumQuestions).contains(entries.count)
    else { throw Refusal(message: "questions must be a list of 1 to \(maximumQuestions)") }
    var questions: [Question] = []
    var seen: Set<Int> = []
    for (index, entry) in entries.enumerated() {
      guard let fields = entry as? [String: Any],
        Set(fields.keys) == ["id", "word", "context", "rewritten"]
      else {
        throw Refusal(
          message: "question \(index) must hold exactly id, word, context and rewritten")
      }
      guard let id = wholeNumber(fields["id"]) else {
        throw Refusal(message: "question \(index): id must be a whole number")
      }
      guard seen.insert(id).inserted else {
        throw Refusal(message: "question \(index): id \(id) is used twice")
      }
      guard let word = fields["word"] as? String, let context = fields["context"] as? String,
        let rewritten = fields["rewritten"] as? String,
        !word.isEmpty, !context.isEmpty, !rewritten.isEmpty
      else { throw Refusal(message: "question \(index): the three texts must not be empty") }
      questions.append(Question(id: id, word: word, context: context, rewritten: rewritten))
    }
    return questions
  }

  /// A JSON number that is a whole number. `true`, `1.5` and `"1"` are not.
  private static func wholeNumber(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    let double = number.doubleValue
    guard double.isFinite, double == double.rounded(), abs(double) < 9_007_199_254_740_992 else {
      return nil
    }
    return Int(double)
  }

  /// The answer body, or nil when a probability is not a finite number from 0 to 1 (the
  /// helper then answers with a server error; it never sends such a score).
  static func responseBody(ids: [Int], scores: [(pA: Double, pB: Double)]) -> Data? {
    guard ids.count == scores.count,
      scores.allSatisfy({ score in
        [score.pA, score.pB].allSatisfy { $0.isFinite && (0...1).contains($0) }
      })
    else { return nil }
    let entries = zip(ids, scores).map { id, score in
      ["id": id, "pA": score.pA, "pB": score.pB] as [String: Any]
    }
    return try? JSONSerialization.data(withJSONObject: ["scores": entries], options: [.sortedKeys])
  }
}
