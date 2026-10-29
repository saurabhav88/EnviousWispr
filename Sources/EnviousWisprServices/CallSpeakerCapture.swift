import AppKit
import ApplicationServices
import Darwin
import EnviousWisprCore
import Foundation

/// The Accessibility attributes a speaker capture copies (#4013 chunk 13A). Exactly what the
/// native and rules readers consume (`CallAXNode`), plus a window's title and a page's address.
package enum CallAXAttribute: String, Sendable, CaseIterable {
  case role = "AXRole"
  case title = "AXTitle"
  case description = "AXDescription"
  case value = "AXValue"
  case identifier = "AXIdentifier"
  case domClassList = "AXDOMClassList"
  case size = "AXSize"
  case children = "AXChildren"
  case url = "AXURL"
  case windows = "AXWindows"
}

/// One attribute read. `missing` is an element without the attribute (optional, not a failure);
/// `failed` is a read that could not answer (timeout, app busy).
package enum CallAXRead<Element> {
  case text(String)
  case texts([String])
  case size(width: Double, height: Double)
  case elements([Element])
  case missing
  case failed
}

/// How a capture reads one app's tree. Tests supply literal trees; `CallSpeakerCapture.live`
/// messages the app. `same` decides identity: `hash` only narrows the comparison, so two
/// different elements with equal hashes are both copied.
package struct CallAXTreeAccess<Element> {
  package var read: (Element, CallAXAttribute) -> CallAXRead<Element>
  package var hash: (Element) -> Int
  package var same: (Element, Element) -> Bool
  package var now: () -> ContinuousClock.Instant

  package init(
    read: @escaping (Element, CallAXAttribute) -> CallAXRead<Element>,
    hash: @escaping (Element) -> Int, same: @escaping (Element, Element) -> Bool,
    now: @escaping () -> ContinuousClock.Instant
  ) {
    self.read = read
    self.hash = hash
    self.same = same
    self.now = now
  }
}

/// Bounds of one capture. Provisional (#4013 13A): to be measured with the live adapter.
package struct CallAXBounds: Sendable, Equatable {
  package var maxNodes: Int
  package var maxDepth: Int
  package var budget: Duration

  package init(maxNodes: Int, maxDepth: Int, budget: Duration) {
    self.maxNodes = maxNodes
    self.maxDepth = maxDepth
    self.budget = budget
  }

  package static let standard = CallAXBounds(
    maxNodes: 6_000, maxDepth: 64, budget: .milliseconds(400))
}

/// An immutable copy of one app's windows, and of the meeting pages inside them, with what the
/// copy can say about itself. A page that is not the meeting is never copied beyond its own node.
package struct CallAXCapture: Sendable, Equatable {
  package let windows: [CallAXWindow]
  package let documents: [CallAXDocument]
  package let completeness: CallCaptureContext.Completeness
  /// Host times (`mach_absolute_time`) bracketing the reads.
  package let readStartHostTime: UInt64
  package let readEndHostTime: UInt64

  package init(
    windows: [CallAXWindow], documents: [CallAXDocument],
    completeness: CallCaptureContext.Completeness, readStartHostTime: UInt64,
    readEndHostTime: UInt64
  ) {
    self.windows = windows
    self.documents = documents
    self.completeness = completeness
    self.readStartHostTime = readStartHostTime
    self.readEndHostTime = readEndHostTime
  }
}

package enum CallSpeakerCapture {
  /// Copies `windows` of one app within `bounds`. `keepPage` says, from a page's address,
  /// whether a web area is the meeting; any other page is cut at its own node, so no other
  /// page's content is copied. A required read that fails (a role, children, the window list)
  /// or an optional read that fails makes the copy unreadable; reaching a bound makes it
  /// truncated, as does a copy whose reads ran past the time budget; an element already copied
  /// (a cycle) is not copied again.
  package static func capture<Element>(
    windows: [Element], access: CallAXTreeAccess<Element>, bounds: CallAXBounds,
    keepPage: @escaping (String) -> Bool, hostTime: () -> UInt64
  ) -> CallAXCapture {
    let started = hostTime()
    let deadline = access.now().advanced(by: bounds.budget)
    var walk = Walk(access: access, bounds: bounds, deadline: deadline, keepPage: keepPage)
    var copied: [CallAXWindow] = []
    for window in windows {
      guard let root = walk.node(window, depth: 0) else { continue }
      var title: String?
      switch walk.read(window, .title) {
      case .text(let text)?: title = text
      case .failed?: walk.unreadable = true
      default: break
      }
      copied.append(CallAXWindow(title: title, root: root))
    }
    // The budget covers every read, the last element's included, not only node entry.
    if access.now() >= deadline { walk.truncated = true }
    let completeness: CallCaptureContext.Completeness =
      walk.unreadable ? .unreadable : (walk.truncated ? .truncated : .complete)
    return CallAXCapture(
      windows: copied, documents: walk.documents, completeness: completeness,
      readStartHostTime: started, readEndHostTime: hostTime())
  }

  private struct Walk<Element> {
    let access: CallAXTreeAccess<Element>
    let bounds: CallAXBounds
    let deadline: ContinuousClock.Instant
    let keepPage: (String) -> Bool
    var visited: [Int: [Element]] = [:]
    var count = 0
    var truncated = false
    var unreadable = false
    var documents: [CallAXDocument] = []

    init(
      access: CallAXTreeAccess<Element>, bounds: CallAXBounds, deadline: ContinuousClock.Instant,
      keepPage: @escaping (String) -> Bool
    ) {
      self.access = access
      self.bounds = bounds
      self.deadline = deadline
      self.keepPage = keepPage
    }

    /// One read, or nil without asking the app once the time budget is spent (the copy is then
    /// truncated), so a slow app is not messaged past the budget.
    mutating func read(_ element: Element, _ attribute: CallAXAttribute) -> CallAXRead<Element>? {
      guard access.now() < deadline else {
        truncated = true
        return nil
      }
      return access.read(element, attribute)
    }

    /// Whether `element` was copied already; records it when not.
    mutating func seen(_ element: Element) -> Bool {
      let key = access.hash(element)
      if visited[key, default: []].contains(where: { access.same($0, element) }) { return true }
      visited[key, default: []].append(element)
      return false
    }

    mutating func text(_ element: Element, _ attribute: CallAXAttribute) -> String? {
      switch read(element, attribute) {
      case .text(let text)?: return text
      case .failed?:
        unreadable = true
        return nil
      default: return nil
      }
    }

    mutating func node(_ element: Element, depth: Int) -> CallAXNode? {
      guard !unreadable else { return nil }
      guard count < bounds.maxNodes, depth <= bounds.maxDepth, access.now() < deadline else {
        truncated = true
        return nil
      }
      guard !seen(element) else { return nil }
      count += 1
      guard let roleRead = read(element, .role) else { return nil }
      guard case .text(let role) = roleRead else {
        unreadable = true
        return nil
      }
      let title = text(element, .title)
      let description = text(element, .description)
      let value = text(element, .value)
      let identifier = text(element, .identifier)
      var classes: [String] = []
      switch read(element, .domClassList) {
      case .texts(let list)?: classes = list
      case .text(let one)?: classes = [one]
      case .failed?: unreadable = true
      default: break
      }
      var width: Double?
      var height: Double?
      switch read(element, .size) {
      case .size(let w, let h)?:
        width = w
        height = h
      case .failed?: unreadable = true
      default: break
      }
      var url: String?
      var keptPage = true
      if role == "AXWebArea" {
        url = text(element, .url)
        keptPage = url.map(keepPage) ?? false
      }
      var children: [CallAXNode] = []
      if keptPage {
        switch read(element, .children) {
        case .elements(let list)?:
          for child in list {
            if let copy = node(child, depth: depth + 1) { children.append(copy) }
            if unreadable || truncated { break }
          }
        case .missing?, nil: break
        default: unreadable = true
        }
      }
      let copy = CallAXNode(
        role: role, title: title, description: description, value: value,
        identifier: identifier, domClassList: classes, width: width, height: height,
        children: children)
      if role == "AXWebArea", keptPage, let url {
        documents.append(CallAXDocument(url: url, root: copy))
      }
      return copy
    }
  }

  // MARK: - Live

  /// Seconds one Accessibility message may take.
  static let messagingTimeout: Float = 0.1

  /// The live tree access: every read sets its own element's messaging timeout first (#4127).
  package static var liveAccess: CallAXTreeAccess<AXUIElement> {
    CallAXTreeAccess<AXUIElement>(
      read: { element, attribute in liveRead(element, attribute) },
      hash: { Int(CFHash($0)) }, same: { CFEqual($0, $1) }, now: { ContinuousClock.now })
  }

  static func liveRead(_ element: AXUIElement, _ attribute: CallAXAttribute) -> CallAXRead<
    AXUIElement
  > {
    guard AXUIElementSetMessagingTimeout(element, messagingTimeout) == .success else {
      return .failed
    }
    var value: CFTypeRef?
    switch AXUIElementCopyAttributeValue(element, attribute.rawValue as CFString, &value) {
    case .success: break
    case .noValue, .attributeUnsupported: return .missing
    default: return .failed
    }
    guard let value else { return .missing }
    switch attribute {
    case .children, .windows:
      guard let list = value as? [AXUIElement] else { return .missing }
      return .elements(list)
    case .domClassList:
      if let list = value as? [String] { return .texts(list) }
      return .missing
    case .size:
      guard CFGetTypeID(value) == AXValueGetTypeID() else { return .missing }
      var size = CGSize.zero
      guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return .missing }
      return .size(width: Double(size.width), height: Double(size.height))
    case .url:
      if let url = value as? URL { return .text(url.absoluteString) }
      if let text = value as? String { return .text(text) }
      return .missing
    default:
      if let text = value as? String { return .text(text) }
      return .missing
    }
  }

  /// Copies every window of the app `pid` within `bounds`. Unreadable when the window list
  /// itself cannot be read; an app with no windows gives an empty, complete copy.
  package static func live(pid: pid_t, bounds: CallAXBounds, keepPage: @escaping (String) -> Bool)
    -> CallAXCapture
  {
    let app = AXUIElementCreateApplication(pid)
    // Reading the role first wakes a Chromium browser's tree (#3802), as call detection does.
    _ = liveRead(app, .role)
    switch liveRead(app, .windows) {
    case .elements(let windows):
      return capture(
        windows: windows, access: liveAccess, bounds: bounds, keepPage: keepPage,
        hostTime: { mach_absolute_time() })
    case .missing:
      let now = mach_absolute_time()
      return CallAXCapture(
        windows: [], documents: [], completeness: .complete, readStartHostTime: now,
        readEndHostTime: now)
    default:
      let now = mach_absolute_time()
      return CallAXCapture(
        windows: [], documents: [], completeness: .unreadable, readStartHostTime: now,
        readEndHostTime: now)
    }
  }
}

/// The app instance a speaker capture reads for a recording's call app (#4013 chunk 13A). Only
/// a capture target, never kept past the reading or saved.
package struct CallSpeakerTarget: Sendable, Equatable {
  package let pid: pid_t
  package let rule: CallAppCatalog.Rule

  package init(pid: pid_t, rule: CallAppCatalog.Rule) {
    self.pid = pid
    self.rule = rule
  }

  /// The regular app that owns a microphone-holding process: the process itself when it is a
  /// regular app, else its parent when that is one (a browser's or call app's helper). `nil`
  /// when neither is, so a helper is never matched to an app by name alone.
  package static func owner(ofHolder pid: pid_t) -> pid_t? {
    if NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular { return pid }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    let parent = pid_t(info.pbi_ppid)
    return NSRunningApplication(processIdentifier: parent)?.activationPolicy == .regular
      ? parent : nil
  }
}
