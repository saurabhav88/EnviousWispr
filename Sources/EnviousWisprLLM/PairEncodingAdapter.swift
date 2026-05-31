import Foundation

/// Tensors fed to the Core ML cross-encoder. Lengths are always `maxLength`.
public struct EncodedClassifierInput: Equatable, Sendable {
  public let inputIDs: [Int32]
  public let attentionMask: [Int32]
  public let tokenTypeIDs: [Int32]
}

/// Reusable, config-driven pair encoder. Mirrors the Python `PairDataset`
/// (`phase2_train_helpers.py`) byte-for-byte for MiniLM/BERT, and expresses
/// RoBERTa-family encoders through the same contract (`pairTemplate` +
/// `tokenTypePolicy`) with no model-specific branching in the caller.
///
/// Pipeline (matching PairDataset.__getitem__):
///   1. "Input: {A}" / "Output: {B}"  (prefixes from the contract)
///   2. tokenize each side with add_special_tokens=false
///   3. INPUT head+tail cap so OUTPUT keeps `minOutputTokens` of budget
///   4. OUTPUT budget = max(minOutputTokens, maxLength - inputCount - specialsBudget)
///   5. truncate OUTPUT (tail / head_tail) BEFORE special-token assembly
///   6. assemble specials by walking `pairTemplate.sequence`
///   7. segment ids by the same walk (`bert_segments` / `none`)
///   8. attention mask 1=real 0=pad; right-pad ids/mask/segments to maxLength
public struct PairEncodingAdapter: Sendable {
  public let contract: TokenizerContract
  /// Tokenize one side as a single text WITHOUT special tokens.
  private let encode: @Sendable (String) -> [Int]

  public init(contract: TokenizerContract, encode: @escaping @Sendable (String) -> [Int]) {
    self.contract = contract
    self.encode = encode
  }

  /// Validate that every special the template references resolves in the
  /// contract. Call once at load; a missing special is an unsupported family.
  public func validate() throws {
    for token in contract.pairTemplate.sequence where token != "input" && token != "output" {
      if specialID(for: token) == nil {
        throw OutputClassifierError.disabled(.unsupportedFamily)
      }
    }
  }

  public func encodePair(input: String, output: String) -> EncodedClassifierInput {
    var inIDs = encode(contract.inputPrefix + input)
    var outIDs = encode(contract.outputPrefix + output)

    inIDs = truncateInputHeadTail(inIDs)
    let budget = outputBudget(inputCount: inIDs.count)
    if outIDs.count > budget {
      outIDs = truncateOutput(outIDs, budget: budget)
    }

    var ids = assembleSpecials(inIDs: inIDs, outIDs: outIDs)
    var segments = segmentIDs(inputCount: inIDs.count, outputCount: outIDs.count)

    let maxLength = contract.maxLength
    // Defensive: budgeting should keep us under maxLength, but never exceed it.
    if ids.count > maxLength {
      ids = Array(ids.prefix(maxLength))
      segments = Array(segments.prefix(maxLength))
    }

    var mask = [Int](repeating: 1, count: ids.count)
    let padCount = maxLength - ids.count
    if padCount > 0 {
      let pad = contract.specialTokenIds["pad"] ?? OutputClassifierManifest.padTokenID
      ids.append(contentsOf: repeatElement(pad, count: padCount))
      mask.append(contentsOf: repeatElement(0, count: padCount))
      let padSeg = contract.tokenTypePolicy.padSegmentId ?? 0
      segments.append(contentsOf: repeatElement(padSeg, count: padCount))
    }

    return EncodedClassifierInput(
      inputIDs: ids.map(Int32.init),
      attentionMask: mask.map(Int32.init),
      tokenTypeIDs: segments.map(Int32.init)
    )
  }

  // MARK: - Truncation (PairDataset mirror)

  private var maxInputTokens: Int {
    max(1, contract.maxLength - contract.specialsBudget - contract.minOutputTokens)
  }

  private func truncateInputHeadTail(_ ids: [Int]) -> [Int] {
    let cap = maxInputTokens
    if ids.count <= cap { return ids }
    let head = min(
      contract.inputTruncationPolicy.headTokens, cap - contract.inputTruncationPolicy.tailTokens)
    let tail = cap - head
    if head <= 0 || tail <= 0 { return Array(ids.prefix(cap)) }
    return Array(ids.prefix(head)) + Array(ids.suffix(tail))
  }

  private func outputBudget(inputCount: Int) -> Int {
    max(contract.minOutputTokens, contract.maxLength - inputCount - contract.specialsBudget)
  }

  private func truncateOutput(_ ids: [Int], budget: Int) -> [Int] {
    if contract.outputTruncationPolicy.kind == "tail" || ids.count <= budget {
      return Array(ids.prefix(budget))
    }
    // head_tail
    let head = min(
      contract.outputTruncationPolicy.headTokens,
      budget - contract.outputTruncationPolicy.tailTokens)
    let tail = budget - head
    if head <= 0 || tail <= 0 { return Array(ids.prefix(budget)) }
    return Array(ids.prefix(head)) + Array(ids.suffix(tail))
  }

  // MARK: - Special-token + segment assembly (sequence-driven, config-only)

  private func specialID(for token: String) -> Int? {
    contract.specialTokenIds[token]
  }

  private func assembleSpecials(inIDs: [Int], outIDs: [Int]) -> [Int] {
    var ids = [Int]()
    for token in contract.pairTemplate.sequence {
      switch token {
      case "input": ids.append(contentsOf: inIDs)
      case "output": ids.append(contentsOf: outIDs)
      default:
        if let sid = specialID(for: token) { ids.append(sid) }
      }
    }
    return ids
  }

  /// Walk the same template; flip from `inputSegmentId` to `outputSegmentId`
  /// at the `output` slot. Matches BERT `create_token_type_ids_from_sequences`
  /// ([0]*(cls+A+sep) + [1]*(B+sep)). `none` ⇒ all pad-segment (RoBERTa-style,
  /// model ignores token_type).
  private func segmentIDs(inputCount: Int, outputCount: Int) -> [Int] {
    let policy = contract.tokenTypePolicy
    let inputSeg = policy.inputSegmentId ?? 0
    let outputSeg = policy.outputSegmentId ?? 1
    let padSeg = policy.padSegmentId ?? 0

    if policy.kind == "none" || !policy.needsSegmentIds {
      let total = assembleSpecials(
        inIDs: [Int](repeating: 0, count: inputCount),
        outIDs: [Int](repeating: 0, count: outputCount)
      ).count
      return [Int](repeating: padSeg, count: total)
    }

    var segments = [Int]()
    var current = inputSeg
    for token in contract.pairTemplate.sequence {
      switch token {
      case "input": segments.append(contentsOf: repeatElement(current, count: inputCount))
      case "output":
        current = outputSeg
        segments.append(contentsOf: repeatElement(current, count: outputCount))
      default:
        if specialID(for: token) != nil { segments.append(current) }
      }
    }
    return segments
  }
}
