import CoreGraphics
import SwiftUI

/// Reads SVG path data (the `d` attribute) into a SwiftUI `Path`, for the closing film's app
/// logos (#4528). It covers every command the logo data uses: M L H V C S Q T A Z, absolute and
/// relative. Arcs become cubic Béziers, as browsers draw them. Malformed data stops at the last
/// complete command, so a bad logo draws partly instead of crashing the film.
enum SVGPathData {
  static func path(_ data: String) -> Path {
    var reader = Reader(data)
    var path = Path()
    var current = CGPoint.zero
    var start = CGPoint.zero
    var lastControl: CGPoint?
    var lastCommand: Character = " "
    var command: Character = " "

    while true {
      if let next = reader.command() {
        command = next
      } else if !reader.hasNumber || command == " " || command == "Z" || command == "z" {
        break  // the end, or numbers no command can take
      } else if command == "M" {
        command = "L"  // extra pairs after a move are lines
      } else if command == "m" {
        command = "l"
      }
      let relative = command.isLowercase
      let base = relative ? current : .zero
      func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: base.x + x, y: base.y + y) }

      switch command.uppercased().first {
      case "M":
        guard let x = reader.number(), let y = reader.number() else { return path }
        current = point(x, y)
        start = current
        path.move(to: current)
        lastControl = nil
      case "L":
        guard let x = reader.number(), let y = reader.number() else { return path }
        current = point(x, y)
        path.addLine(to: current)
        lastControl = nil
      case "H":
        guard let x = reader.number() else { return path }
        current = CGPoint(x: relative ? current.x + x : x, y: current.y)
        path.addLine(to: current)
        lastControl = nil
      case "V":
        guard let y = reader.number() else { return path }
        current = CGPoint(x: current.x, y: relative ? current.y + y : y)
        path.addLine(to: current)
        lastControl = nil
      case "C":
        guard let x1 = reader.number(), let y1 = reader.number(), let x2 = reader.number(),
          let y2 = reader.number(), let x = reader.number(), let y = reader.number()
        else { return path }
        let c2 = point(x2, y2)
        current = point(x, y)
        path.addCurve(to: current, control1: point(x1, y1), control2: c2)
        lastControl = c2
      case "S":
        guard let x2 = reader.number(), let y2 = reader.number(), let x = reader.number(),
          let y = reader.number()
        else { return path }
        let c1 = "CcSs".contains(lastCommand) ? reflect(lastControl, current) : current
        let c2 = point(x2, y2)
        current = point(x, y)
        path.addCurve(to: current, control1: c1, control2: c2)
        lastControl = c2
      case "Q":
        guard let x1 = reader.number(), let y1 = reader.number(), let x = reader.number(),
          let y = reader.number()
        else { return path }
        let c = point(x1, y1)
        current = point(x, y)
        path.addQuadCurve(to: current, control: c)
        lastControl = c
      case "T":
        guard let x = reader.number(), let y = reader.number() else { return path }
        let c = "QqTt".contains(lastCommand) ? reflect(lastControl, current) : current
        current = point(x, y)
        path.addQuadCurve(to: current, control: c)
        lastControl = c
      case "A":
        guard let rx = reader.number(), let ry = reader.number(), let angle = reader.number(),
          let large = reader.flag(), let sweep = reader.flag(), let x = reader.number(),
          let y = reader.number()
        else { return path }
        let end = point(x, y)
        addArc(
          to: &path, from: current, to: end, rx: rx, ry: ry, degrees: angle, large: large,
          sweep: sweep)
        current = end
        lastControl = nil
      case "Z":
        path.closeSubpath()
        current = start
        lastControl = nil
      default:
        return path
      }
      lastCommand = command
    }
    return path
  }

  private static func reflect(_ control: CGPoint?, _ around: CGPoint) -> CGPoint {
    guard let control else { return around }
    return CGPoint(x: 2 * around.x - control.x, y: 2 * around.y - control.y)
  }

  /// SVG's endpoint arc (SVG 1.1 F.6.5) as cubic Béziers, each at most a quarter turn.
  private static func addArc(
    to path: inout Path, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
    degrees: CGFloat, large: Bool, sweep: Bool
  ) {
    var rx = abs(rxIn)
    var ry = abs(ryIn)
    guard rx > 0, ry > 0, p0 != p1 else {
      path.addLine(to: p1)
      return
    }
    let phi = degrees * .pi / 180
    let cosPhi = cos(phi)
    let sinPhi = sin(phi)
    let dx = (p0.x - p1.x) / 2
    let dy = (p0.y - p1.y) / 2
    let x1 = cosPhi * dx + sinPhi * dy
    let y1 = -sinPhi * dx + cosPhi * dy
    let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if lambda > 1 {
      rx *= lambda.squareRoot()
      ry *= lambda.squareRoot()
    }
    let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
    var factor = (max(0, numerator) / denominator).squareRoot()
    if large == sweep { factor = -factor }
    let cx1 = factor * rx * y1 / ry
    let cy1 = -factor * ry * x1 / rx
    let center = CGPoint(
      x: cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2,
      y: sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2)

    func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
      let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
      return a
    }
    let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
    var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
    if !sweep && delta > 0 { delta -= 2 * .pi }
    if sweep && delta < 0 { delta += 2 * .pi }

    let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
    let step = delta / CGFloat(segments)
    let k = 4 / 3 * tan(step / 4)
    func onEllipse(_ t: CGFloat) -> CGPoint {
      CGPoint(
        x: center.x + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi,
        y: center.y + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
    }
    func derivative(_ t: CGFloat) -> CGPoint {
      CGPoint(
        x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi,
        y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
    }
    var t = theta1
    for index in 0..<segments {
      let next = t + step
      let from = onEllipse(t)
      let to = index == segments - 1 ? p1 : onEllipse(next)
      let d0 = derivative(t)
      let d1 = derivative(next)
      path.addCurve(
        to: to,
        control1: CGPoint(x: from.x + k * d0.x, y: from.y + k * d0.y),
        control2: CGPoint(x: to.x - k * d1.x, y: to.y - k * d1.y))
      t = next
    }
  }

  /// A cursor over the path text: commands, numbers ("-.5.5" is -0.5 then 0.5) and arc flags.
  private struct Reader {
    let chars: [Character]
    var index = 0

    init(_ text: String) { chars = Array(text) }

    mutating func skipSeparators() {
      while index < chars.count,
        chars[index] == " " || chars[index] == ","
          || chars[index]
            .isNewline
          || chars[index] == "\t"
      {
        index += 1
      }
    }

    mutating func command() -> Character? {
      skipSeparators()
      guard index < chars.count, chars[index].isLetter, chars[index] != "e", chars[index] != "E"
      else { return nil }
      defer { index += 1 }
      return chars[index]
    }

    var hasNumber: Bool {
      var probe = self
      probe.skipSeparators()
      guard probe.index < probe.chars.count else { return false }
      let c = probe.chars[probe.index]
      return c.isNumber || c == "-" || c == "+" || c == "."
    }

    mutating func flag() -> Bool? {
      skipSeparators()
      guard index < chars.count, chars[index] == "0" || chars[index] == "1" else { return nil }
      defer { index += 1 }
      return chars[index] == "1"
    }

    mutating func number() -> CGFloat? {
      skipSeparators()
      let begin = index
      if index < chars.count, chars[index] == "-" || chars[index] == "+" { index += 1 }
      var sawDot = false
      var sawDigit = false
      while index < chars.count {
        let c = chars[index]
        if c.isNumber {
          sawDigit = true
        } else if c == ".", !sawDot {
          sawDot = true
        } else {
          break
        }
        index += 1
      }
      if sawDigit, index < chars.count, chars[index] == "e" || chars[index] == "E" {
        index += 1
        if index < chars.count, chars[index] == "-" || chars[index] == "+" { index += 1 }
        while index < chars.count, chars[index].isNumber { index += 1 }
      }
      guard sawDigit, let value = Double(String(chars[begin..<index])) else {
        index = begin
        return nil
      }
      return CGFloat(value)
    }
  }
}
