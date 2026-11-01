import AppKit
import ApplicationServices
import Darwin
import EnviousWisprCore
import Foundation

/// The Accessibility attributes a speaker capture copies (#4013 chunk 13A). Exactly what the
/// native, rules and self-mute (#4248) readers consume (`CallAXNode`), plus a window's title and
/// a page's address.
package enum CallAXAttribute: String, Sendable, CaseIterable {
  case role = "AXRole"
  case title = "AXTitle"
  case description = "AXDescription"
  case value = "AXValue"
  case identifier = "AXIdentifier"
  case domIdentifier = "AXDOMIdentifier"
  case domClassList = "AXDOMClassList"
  case size = "AXSize"
  case children = "AXChildren"
  case url = "AXURL"
  case windows = "AXWindows"
  case menuBar = "AXMenuBar"
  case markChar = "AXMenuItemMarkChar"
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
  /// Several attributes of one element in one message, answered in the order asked (#4248):
  /// the live access batches them, which a slow app answers far faster than one message per
  /// attribute. Without one, each attribute is read alone.
  package var readMany: (Element, [CallAXAttribute]) -> [CallAXRead<Element>]
  package var hash: (Element) -> Int
  package var same: (Element, Element) -> Bool
  package var now: () -> ContinuousClock.Instant

  package init(
    read: @escaping (Element, CallAXAttribute) -> CallAXRead<Element>,
    readMany: ((Element, [CallAXAttribute]) -> [CallAXRead<Element>])? = nil,
    hash: @escaping (Element) -> Int, same: @escaping (Element, Element) -> Bool,
    now: @escaping () -> ContinuousClock.Instant
  ) {
    self.read = read
    self.readMany = readMany ?? { element, attributes in attributes.map { read(element, $0) } }
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

  /// The Teams app answers Accessibility slowly: in the #4248 Teams run a whole copy of about
  /// 260 nodes took 118 to 399 ms and three in four copies hit the 400 ms bound (2026-10-31).
  /// A characterization value under measurement, not yet a sized bound.
  package static let teamsApp = CallAXBounds(
    maxNodes: 6_000, maxDepth: 64, budget: .milliseconds(1_000))
}

/// What a capture skips in one provider's tree (#4013 13B runtime receipt). The live Zoom app
/// answers a generic failure, every time, for the children of some toolbar buttons ("End",
/// "More meeting controls") and for the identifier of a banner in its home window; read, those
/// made every copy unreadable. Rather than call a failed read complete, the Zoom policy does not
/// read those branches: the home window (no identifier, titled exactly "Zoom Workplace") is
/// never copied, and the children of the two toolbar buttons are not read. Those buttons are
/// recognised by their identifiers ("leave", "more"), the same in every Zoom language, and only
/// outside a participant tile or the participants list, the structures `ZoomAppSpeakerReader`
/// uses. Every read still made fails as before; any other element is read whole. Other providers
/// read everything.
package enum CallAXCapturePolicy: Sendable, Equatable {
  case standard
  case zoomApp

  static let zoomHomeTitle = "Zoom Workplace"
  /// The toolbar buttons whose children Zoom never answers for (measured 2026-10-29).
  static let zoomToolbarIdentifiers: Set<String> = ["leave", "more"]
  /// The roles whose subtrees hold Zoom's speaker evidence: tiles and the participants list.
  static let zoomEvidenceRoles: Set<String> = ["AXTabGroup", "AXOutline"]

  /// Whether a window is skipped before anything below it is read.
  func skipsWindow(identifier: String?, title: String?) -> Bool {
    self == .zoomApp && identifier == nil && title == Self.zoomHomeTitle
      && !ZoomCallWindow.isMeeting(identifier: identifier, title: title)
  }

  /// Whether an element's children are left unread.
  func prunesChildren(role: String, identifier: String?, insideEvidence: Bool) -> Bool {
    guard self == .zoomApp, role == "AXButton", !insideEvidence, let identifier else {
      return false
    }
    return Self.zoomToolbarIdentifiers.contains(identifier)
  }

  /// Whether an element's DOM id is read: buttons only, where the Teams app's microphone button
  /// carries it (#4248), and never in the Zoom app, a native app that has none.
  func readsDOMIdentifier(role: String) -> Bool {
    self != .zoomApp && role == "AXButton"
  }

  func isEvidence(role: String) -> Bool {
    self == .zoomApp && Self.zoomEvidenceRoles.contains(role)
  }
}

/// An immutable copy of one app's windows, and of the meeting pages inside them, with what the
/// copy can say about itself. A page that is not the meeting is never copied beyond its own node.
/// Where one copy's time went (#4248 timing receipt): numeric aggregates only, never content.
package struct CallAXCopyCost: Sendable, Equatable {
  package struct Window: Sendable, Equatable {
    package let nodes: Int
    package let ticks: UInt64
    package var messages = 0
    package var messageTime: Duration = .zero
  }
  /// Which message: the role batch, the role-dependent batch, or a single read.
  package enum Kind: String, Sendable, CaseIterable {
    case common, dependent, single
  }
  package struct Total: Sendable, Equatable {
    package var messages = 0
    package var time: Duration = .zero
  }
  /// Each copied window's elements, host ticks and messages, in copy order.
  package var windows: [Window] = []
  /// Messages sent to the app and the time spent inside them, overall and by kind.
  package var messages = 0
  package var messageTime: Duration = .zero
  package var byKind: [Kind: Total] = [:]

  package init() {}
}

package struct CallAXCapture: Sendable, Equatable {
  package let windows: [CallAXWindow]
  package let documents: [CallAXDocument]
  package let completeness: CallCaptureContext.Completeness
  /// Host times (`mach_absolute_time`) bracketing the reads.
  package let readStartHostTime: UInt64
  package let readEndHostTime: UInt64
  /// Elements copied (for the local capture health counts).
  package let nodesVisited: Int
  /// Reads that failed, button subtrees left unread, and windows skipped (`CallAXCapturePolicy`).
  package let failedReads: Int
  package let prunedControls: Int
  package let skippedWindows: Int
  /// The titles of the call app's checked accounts (`CallAccountMenu`), read from its menu bar
  /// after the windows, on the same queue, within its own small budget; `nil` when not read,
  /// not wholly readable or out of time. Never pressed.
  package let accountTitles: [String]?
  package let cost: CallAXCopyCost

  package init(
    windows: [CallAXWindow], documents: [CallAXDocument],
    completeness: CallCaptureContext.Completeness, readStartHostTime: UInt64,
    readEndHostTime: UInt64, nodesVisited: Int = 0, failedReads: Int = 0,
    prunedControls: Int = 0, skippedWindows: Int = 0, accountTitles: [String]? = nil,
    cost: CallAXCopyCost = .init()
  ) {
    self.accountTitles = accountTitles
    self.cost = cost
    self.nodesVisited = nodesVisited
    self.failedReads = failedReads
    self.prunedControls = prunedControls
    self.skippedWindows = skippedWindows
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
    policy: CallAXCapturePolicy = .standard, keepPage: @escaping (String) -> Bool,
    app: Element? = nil, hostTime: () -> UInt64
  ) -> CallAXCapture {
    let started = hostTime()
    let deadline = access.now().advanced(by: bounds.budget)
    var walk = Walk(
      access: access, bounds: bounds, deadline: deadline, policy: policy, keepPage: keepPage)
    var copied: [CallAXWindow] = []
    var skippedWindows = 0
    var windowCosts: [CallAXCopyCost.Window] = []
    for window in windows {
      let windowStart = hostTime()
      let nodesBefore = walk.count
      let messagesBefore = walk.messages
      let timeBefore = walk.messageTime
      defer {
        windowCosts.append(
          .init(
            nodes: walk.count - nodesBefore, ticks: hostTime() &- windowStart,
            messages: walk.messages - messagesBefore, messageTime: walk.messageTime - timeBefore))
      }
      if policy != .standard {
        // Only a window positively known not to be the call is skipped; a failed read keeps it.
        let identifier = walk.text(window, .identifier)
        let title = walk.text(window, .title)
        if !walk.unreadable, policy.skipsWindow(identifier: identifier, title: title) {
          skippedWindows += 1
          continue
        }
      }
      guard let root = walk.node(window, depth: 0, insideEvidence: false) else { continue }
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
    let ended = hostTime()
    // The account is read after the call's copy is settled, within its own budget, so it never
    // changes that copy's completeness or timing; anything short of a whole read is unknown.
    var accountTitles: [String]?
    if policy == .zoomApp, let app, completeness == .complete {
      let accountDeadline = access.now().advanced(by: CallAccountMenu.budget)
      let read: (Element, CallAXAttribute) -> CallAXRead<Element>? = { element, attribute in
        guard access.now() < accountDeadline else { return nil }
        let result = access.read(element, attribute)
        if case .failed = result { return nil }
        return result
      }
      if case .elements(let bars)? = read(app, .menuBar), let menuBar = bars.first {
        accountTitles = CallAccountMenu.checkedTitles(menuBar: menuBar, read: read)
        if access.now() >= accountDeadline { accountTitles = nil }
      }
    }
    return CallAXCapture(
      windows: copied, documents: walk.documents, completeness: completeness,
      readStartHostTime: started, readEndHostTime: ended, nodesVisited: walk.count,
      failedReads: walk.failedReads, prunedControls: walk.prunedControls,
      skippedWindows: skippedWindows, accountTitles: accountTitles,
      cost: {
        var cost = CallAXCopyCost()
        cost.windows = windowCosts
        cost.messages = walk.messages
        cost.messageTime = walk.messageTime
        cost.byKind = walk.byKind
        return cost
      }())
  }

  private struct Walk<Element> {
    let access: CallAXTreeAccess<Element>
    let bounds: CallAXBounds
    let deadline: ContinuousClock.Instant
    let policy: CallAXCapturePolicy
    let keepPage: (String) -> Bool
    var visited: [Int: [Element]] = [:]
    var count = 0
    var truncated = false
    var unreadable = false
    var failedReads = 0
    var prunedControls = 0
    var documents: [CallAXDocument] = []
    var messages = 0
    var messageTime: Duration = .zero
    var byKind: [CallAXCopyCost.Kind: CallAXCopyCost.Total] = [:]

    mutating func note(_ kind: CallAXCopyCost.Kind, since sent: ContinuousClock.Instant) {
      let spent = access.now() - sent
      messages += 1
      messageTime += spent
      byKind[kind, default: .init()].messages += 1
      byKind[kind, default: .init()].time += spent
    }

    init(
      access: CallAXTreeAccess<Element>, bounds: CallAXBounds, deadline: ContinuousClock.Instant,
      policy: CallAXCapturePolicy, keepPage: @escaping (String) -> Bool
    ) {
      self.access = access
      self.bounds = bounds
      self.deadline = deadline
      self.policy = policy
      self.keepPage = keepPage
    }

    /// One read, or nil without asking the app once the time budget is spent (the copy is then
    /// truncated), so a slow app is not messaged past the budget.
    mutating func read(_ element: Element, _ attribute: CallAXAttribute) -> CallAXRead<Element>? {
      guard access.now() < deadline else {
        truncated = true
        return nil
      }
      let sent = access.now()
      let result = access.read(element, attribute)
      note(.single, since: sent)
      if case .failed = result { failedReads += 1 }
      return result
    }

    /// Several attributes in one message, or nil without asking once the budget is spent. An
    /// answer of the wrong length counts as every attribute failing.
    mutating func readMany(_ element: Element, _ attributes: [CallAXAttribute])
      -> [CallAXRead<Element>]?
    {
      guard access.now() < deadline else {
        truncated = true
        return nil
      }
      let sent = access.now()
      var results = access.readMany(element, attributes)
      note(attributes.first == .role ? .common : .dependent, since: sent)
      if results.count != attributes.count {
        results = attributes.map { _ in .failed }
      }
      for case .failed in results { failedReads += 1 }
      return results
    }

    /// A text attribute from a batch: a failed read makes the copy unreadable.
    mutating func text(_ read: CallAXRead<Element>?) -> String? {
      switch read {
      case .text(let text)?: return text
      case .failed?:
        unreadable = true
        return nil
      default: return nil
      }
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

    mutating func node(_ element: Element, depth: Int, insideEvidence: Bool) -> CallAXNode? {
      guard !unreadable else { return nil }
      guard count < bounds.maxNodes, depth <= bounds.maxDepth, access.now() < deadline else {
        truncated = true
        return nil
      }
      guard !seen(element) else { return nil }
      count += 1
      // Message 1: the role and every attribute read whatever the role is.
      let common: [CallAXAttribute] = [
        .role, .title, .description, .value, .identifier, .domClassList, .size,
      ]
      guard let first = readMany(element, common) else { return nil }
      guard case .text(let role) = first[0] else {
        unreadable = true
        return nil
      }
      let title = text(first[1])
      let description = text(first[2])
      let value = text(first[3])
      let identifier = text(first[4])
      var classes: [String] = []
      switch first[5] {
      case .texts(let list): classes = list
      case .text(let one): classes = [one]
      case .failed: unreadable = true
      default: break
      }
      var width: Double?
      var height: Double?
      switch first[6] {
      case .size(let w, let h):
        width = w
        height = h
      case .failed: unreadable = true
      default: break
      }
      // Message 2: what the role allows. A DOM id is asked only where the policy reads it; a
      // page's children wait for its address (message 3); pruned children are never asked.
      let isPage = role == "AXWebArea"
      let pruned = policy.prunesChildren(
        role: role, identifier: identifier, insideEvidence: insideEvidence)
      if pruned { prunedControls += 1 }
      var second: [CallAXAttribute] = []
      if policy.readsDOMIdentifier(role: role) { second.append(.domIdentifier) }
      if isPage { second.append(.url) }
      if !isPage, !pruned { second.append(.children) }
      let answers = second.isEmpty ? [] : readMany(element, second)
      func answer(_ attribute: CallAXAttribute) -> CallAXRead<Element>? {
        second.firstIndex(of: attribute).flatMap { index in answers.map { $0[index] } }
      }
      let domIdentifier = text(answer(.domIdentifier))
      var url: String?
      var keptPage = true
      var childrenRead = answer(.children)
      if isPage {
        url = text(answer(.url))
        keptPage = url.map(keepPage) ?? false
        // Message 3: a kept page's children, after its address decided.
        childrenRead = keptPage && !pruned && answers != nil ? read(element, .children) : nil
      }
      var children: [CallAXNode] = []
      if keptPage, !pruned {
        let inside = insideEvidence || policy.isEvidence(role: role)
        switch childrenRead {
        case .elements(let list)?:
          for child in list {
            if let copy = node(child, depth: depth + 1, insideEvidence: inside) {
              children.append(copy)
            }
            if unreadable || truncated { break }
          }
        case .missing?, nil: break
        default: unreadable = true
        }
      }
      let copy = CallAXNode(
        role: role, title: title, description: description, value: value,
        identifier: identifier, domIdentifier: domIdentifier, domClassList: classes, width: width,
        height: height, children: children)
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
      readMany: { element, attributes in liveReadMany(element, attributes) },
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
    return liveDecode(attribute, value)
  }

  /// Several attributes of one element in one message (`AXUIElementCopyMultipleAttributeValues`,
  /// options 0, so one attribute's error does not stop the others). Same answers as reading
  /// each alone: an attribute the element lacks is missing, any other error failed.
  static func liveReadMany(_ element: AXUIElement, _ attributes: [CallAXAttribute])
    -> [CallAXRead<AXUIElement>]
  {
    guard AXUIElementSetMessagingTimeout(element, messagingTimeout) == .success else {
      return attributes.map { _ in .failed }
    }
    var values: CFArray?
    let status = AXUIElementCopyMultipleAttributeValues(
      element, attributes.map { $0.rawValue } as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0),
      &values)
    return decodeBatch(attributes, status: status, values: values as [AnyObject]?)
  }

  /// One batch answer, position by position. A failed call, or an answer of the wrong length,
  /// fails every attribute; an `AXValue` error entry is that attribute's own error; `CFNull` is
  /// missing.
  static func decodeBatch(_ attributes: [CallAXAttribute], status: AXError, values: [AnyObject]?)
    -> [CallAXRead<AXUIElement>]
  {
    guard status == .success, let values, values.count == attributes.count else {
      return attributes.map { _ in .failed }
    }
    return zip(attributes, values).map { attribute, value in
      if value is NSNull { return .missing }
      if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
        var error = AXError.success
        guard AXValueGetValue(value as! AXValue, .axError, &error) else { return .failed }
        switch error {
        case .noValue, .attributeUnsupported: return .missing
        default: return .failed
        }
      }
      return liveDecode(attribute, value)
    }
  }

  /// A successfully read value as the capture keeps it; an unexpected type is missing.
  static func liveDecode(_ attribute: CallAXAttribute, _ value: CFTypeRef) -> CallAXRead<AXUIElement> {
    switch attribute {
    case .children, .windows:
      guard let list = value as? [AXUIElement] else { return .missing }
      return .elements(list)
    case .menuBar:
      guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return .missing }
      return .elements([value as! AXUIElement])
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
  package static func live(
    pid: pid_t, bounds: CallAXBounds, policy: CallAXCapturePolicy = .standard,
    keepPage: @escaping (String) -> Bool
  ) -> CallAXCapture {
    let app = AXUIElementCreateApplication(pid)
    // Reading the role first wakes a Chromium browser's tree (#3802), as call detection does.
    _ = liveRead(app, .role)
    switch liveRead(app, .windows) {
    case .elements(let windows):
      return capture(
        windows: windows, access: liveAccess, bounds: bounds, policy: policy, keepPage: keepPage,
        app: app, hostTime: { mach_absolute_time() })
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

/// Finds the signed-in account in a call app's menu bar without opening or pressing anything
/// (#4013 chunk 14, plan r4). Observed in Zoom Workplace 2026-10-29
/// (`docs/audits/2026-10-27-4013/zoom-1on1-findings-2026-10-29.md`): the app menu (the menu
/// bar's second item, after Apple's) holds an account submenu whose items are titled
/// `<Display name>(<email>)` with identifier `menuItemDidClicked:`, beside an `addAccount:` item;
/// the account in use carries the mark `✓`. Identifiers and the mark are the same in every
/// language; titles are not read for structure.
package enum CallAccountMenu {
  static let accountIdentifier = "menuItemDidClicked:"
  static let addAccountIdentifier = "addAccount:"
  static let checkedMark = "\u{2713}"
  /// The most items any menu read here may hold; a longer menu is not read at all.
  static let maximumItems = 64
  /// The whole account read's own time; measured at about 1 ms (2026-10-29).
  static let budget: Duration = .milliseconds(50)

  /// The checked account items' titles in the submenu that holds `addAccount:`, or `nil` unless
  /// the read was whole: `read` answers `nil` for a failed read or a spent budget, and any such
  /// answer, or a menu longer than `maximumItems`, makes the account unknown. A missing check
  /// mark is an unchecked account; a mark that could not be read is unknown.
  package static func checkedTitles<Element>(
    menuBar: Element, read: (Element, CallAXAttribute) -> CallAXRead<Element>?
  ) -> [String]? {
    /// `nil` when the children could not be read whole.
    func elements(_ element: Element) -> [Element]? {
      switch read(element, .children) {
      case .elements(let list)?: return list.count > maximumItems ? nil : list
      case .missing?: return []
      default: return nil
      }
    }
    /// `.some(nil)` is a missing attribute; `nil` is a read that did not answer.
    func text(_ element: Element, _ attribute: CallAXAttribute) -> String?? {
      switch read(element, attribute) {
      case .text(let text)?: return .some(text)
      case .missing?: return .some(nil)
      default: return nil
      }
    }
    guard let bar = elements(menuBar), bar.count > 1, let appMenu = elements(bar[1])?.first,
      let items = elements(appMenu)
    else { return nil }
    for item in items {
      guard let submenus = elements(item) else { return nil }
      guard let submenu = submenus.first else { continue }
      guard let entries = elements(submenu) else { return nil }
      var identifiers: [String?] = []
      for entry in entries {
        guard let identifier = text(entry, .identifier) else { return nil }
        identifiers.append(identifier)
      }
      guard identifiers.contains(addAccountIdentifier) else { continue }
      var titles: [String] = []
      for (entry, identifier) in zip(entries, identifiers) where identifier == accountIdentifier {
        guard let mark = text(entry, .markChar) else { return nil }
        guard mark == checkedMark else { continue }
        guard let title = text(entry, .title) ?? nil else { return nil }
        titles.append(title)
      }
      return titles
    }
    return nil
  }

  /// `Saurabh A Vaish(saurabhav@example.com)` → `Saurabh A Vaish`: the text before the last
  /// bracket when the bracket closes the title and holds an address. Any other shape → `nil`.
  package static func displayName(fromTitle title: String) -> String? {
    guard title.hasSuffix(")"), let open = title.lastIndex(of: "(") else { return nil }
    let inner = title[title.index(after: open)..<title.index(before: title.endIndex)]
    guard inner.contains("@") else { return nil }
    let name = title[..<open].trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? nil : name
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

  /// The regular app that owns a microphone-holding process, found the same way call detection
  /// finds it (`CallEvidenceReader.app(for:holderPID:)`), so a call detection sees is a call
  /// speaker capture can read: Safari's shared WebKit audio process included. Otherwise the
  /// process itself when it is a regular app, else its parent when that is one. `nil` when none
  /// is.
  package static func owner(ofHolder pid: pid_t, bundleID: String) -> pid_t? {
    if let rule = CallAppCatalog.rule(forBundleID: bundleID),
      let app = CallEvidenceReader.app(for: rule, holderPID: pid)
    {
      return app.processIdentifier
    }
    if NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular { return pid }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    let parent = pid_t(info.pbi_ppid)
    return NSRunningApplication(processIdentifier: parent)?.activationPolicy == .regular
      ? parent : nil
  }
}
