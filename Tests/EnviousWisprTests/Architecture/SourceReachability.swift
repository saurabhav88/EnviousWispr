import SwiftSyntax

/// Shared by the source-shape guards that must not count code which can never run (#3385
/// overnight evasion pass, 2026-10-05). Reads syntax only; a spelling it cannot reduce is treated
/// as live, so the guards stay loud rather than quiet.
enum SourceReachability {
  /// The value of a condition written as a literal `true` or `false`, through parentheses,
  /// whitespace and `!`; nil for anything else.
  static func constant(_ condition: String) -> Bool? {
    var text = condition.filter { !$0.isWhitespace }
    var negated = false
    while true {
      if text.hasPrefix("!") {
        negated.toggle()
        text.removeFirst()
      } else if text.hasPrefix("("), text.hasSuffix(")") {
        text = String(text.dropFirst().dropLast())
      } else {
        break
      }
    }
    switch text {
    case "true": return !negated
    case "false": return negated
    default: return nil
    }
  }

  /// A statement that always leaves the enclosing block: `return`, `throw`, or
  /// `if <constant true> { return }` (also `throw`). Only the block's own statements are read,
  /// so a `return` inside a nested closure or a conditional branch does not count.
  static func exitsUnconditionally(_ item: CodeBlockItemSyntax) -> Bool {
    func isExit(_ list: CodeBlockItemListSyntax) -> Bool {
      list.contains { $0.item.is(ReturnStmtSyntax.self) || $0.item.is(ThrowStmtSyntax.self) }
    }
    if item.item.is(ReturnStmtSyntax.self) || item.item.is(ThrowStmtSyntax.self) { return true }
    guard
      let branch = item.item.as(ExpressionStmtSyntax.self)?.expression.as(IfExprSyntax.self)
        ?? item.item.as(IfExprSyntax.self)
    else { return false }
    return constant(branch.conditions.trimmedDescription) == true && isExit(branch.body.statements)
  }
}
