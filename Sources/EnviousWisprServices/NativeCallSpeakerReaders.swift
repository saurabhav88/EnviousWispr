import EnviousWisprCore
import Foundation

/// Reads the Zoom desktop app's own talker signal (#4013 r1 R1). Observed on Zoom Workplace,
/// 2026-10-27 (`docs/audits/2026-10-27-4013/zoom-mac-names-findings.md`): every participant tile
/// is an `AXTabGroup` labelled `<Name>, Computer audio muted, Video off`, and the person talking
/// gets `, active speaker` added. The large Speaker-view tile alone is not evidence of talking,
/// except in the observed screen-share layouts where it is the only tile Zoom shows and follows
/// the talker (`shareSignal`, #4013 share plan §3.2).
///
/// The roster comes from the participants panel when it is open and complete (#4013 C1a,
/// 2026-10-28, `docs/audits/2026-10-27-4013/c1a-receipt.txt`): an `AXOutline` labelled
/// `Participants list` holds one `AXStaticText` per person, duplicates kept, and a
/// `Participants (N)` text gives the count. Zoom keeps the panel closed by default; then the roster
/// is the tiles', which cannot tell one person on two tiles from two people sharing a name.
package enum ZoomAppSpeakerReader {
  /// The audio-state part of a tile label, exactly as observed. A label without one is not a
  /// participant tile; an unobserved wording is not read rather than matched by prefix.
  static let audioStates: Set<String> = [
    "Computer audio muted", "Computer audio unmuted", "No audio connected",
  ]
  static let activeSpeakerFlag = "active speaker"
  static let noAudioState = "No audio connected"
  static let unmutedAudioState = "Computer audio unmuted"
  static let videoStates: Set<String> = ["Video off", "Video on"]
  static let participantsListLabel = "Participants list"
  static let participantsCountPrefix = "Participants ("
  /// The words Zoom puts in brackets after a name in the participants panel.
  static let panelTags: Set<String> = ["Host", "Co-host", "me", "Guest"]

  /// `share` is read from the whole capture before window choice (`shareContext`); `.none` means
  /// no share was seen, so only the tile-flag reading below runs.
  package static func read(
    windows: [CallAXWindow], accountTitles: [String]? = nil, share: ShareContext = .none
  ) -> CallSpeakerReading {
    var tileNames: [String] = []
    var speaking: [String] = []
    var selfNames: [String] = []
    // Every participants list on screen, each with the counts shown in its own window.
    var lists: [(rows: PanelRows, counts: Set<Int>)] = []
    // The counts the closed panel's toolbar button shows (C1a: "Open participants panel,
    // closed, 4 participants").
    var buttonCounts: Set<Int> = []
    // Every "Participants (N)" the call's windows show, with or without a list beside it.
    var panelCounts: Set<Int> = []
    for window in windows {
      let nodes = window.root.allNodes
      for node in nodes where node.role == "AXButton" {
        if let count = node.label.flatMap(closedPanelCount) { buttonCounts.insert(count) }
      }
      // Only the static text Zoom draws above the list (C1a). Capture tolerance (#4013 reading
      // resilience §3.1) copies a failed label as nothing on an unprotected role outside a tile
      // or the list, so such a role must never supply or contradict the count.
      let counts = Set(
        nodes.lazy.filter { $0.role == "AXStaticText" }.compactMap {
          $0.label.flatMap(participantCount)
        })
      panelCounts.formUnion(counts)
      for node in nodes where node.role == "AXOutline" && node.label == participantsListLabel {
        lists.append((panelRows(node), counts))
      }
    }
    // Speaker-view thumbnails carry a video state and show each participant once; the large
    // tile repeats one of them without it (C1a/C1b, 2026-10-28). With two people the large tile
    // is the other person and only the user has a thumbnail (2026-10-29).
    var thumbnails: [(name: String?, talking: Bool)] = []
    var largeTiles: [(name: String?, talking: Bool)] = []
    for node in windows.flatMap({ $0.root.allNodes }) {
      if node.role == "AXTabGroup", let label = node.label, let tile = parseTile(label) {
        // A tile with Zoom's structure but no name is still a person; it is kept unnamed. So is
        // one still joining ("No audio connected"), whose name may be Zoom's placeholder (#4190).
        let name: String? = tile.name.isEmpty || tile.isJoining ? nil : tile.name
        if let name {
          tileNames.append(name)
          if tile.isActiveSpeaker { speaking.append(name) }
        }
        if tile.hasVideoState {
          thumbnails.append((name, tile.isActiveSpeaker))
        } else {
          largeTiles.append((name, tile.isActiveSpeaker))
        }
      } else if node.role == "AXStaticText", let label = node.label,
        let name = selfName(fromParticipantEntry: label)
      {
        selfNames.append(name)
      }
    }
    // The panel lists each person once, so a name listed twice is two people. It counts as the
    // participant list only when it is the only list on screen and complete: every joined row is
    // bound to its name, and its own window shows exactly one "Participants (N)" count, equal to
    // the entries read. A longer list Zoom draws only partly, or two lists, fall back to the
    // tiles.
    let complete: PanelRows? =
      if lists.count == 1, let list = lists.first, !list.rows.entries.isEmpty,
        !list.rows.unresolved, list.counts == [list.rows.entries.count]
      {
        list.rows
      } else {
        nil
      }
    let allCounts = buttonCounts.union(panelCounts)
    // Every other count the call shows, the button's included, must say the same. With the panel
    // closed only the button counts; a list on screen that is not complete leaves it unknown.
    let count: Int? =
      if let complete {
        allCounts.isSubset(of: [complete.entries.count]) ? complete.entries.count : nil
      } else {
        lists.isEmpty && allCounts.count == 1 ? allCounts.first : nil
      }
    // The large tile is a person of its own only when the call's count says so: one more than
    // the thumbnails, under a name no thumbnail shows. Otherwise it repeats a thumbnail.
    let thumbnailNames = thumbnails.compactMap(\.name)
    var people = thumbnails
    if largeTiles.count == 1, let large = largeTiles.first, let name = large.name,
      let count, count == thumbnails.count + 1, !thumbnailNames.contains(name)
    {
      people.append(large)
    }
    let flaggedOutsidePeople =
      people.count == thumbnails.count && largeTiles.contains(where: \.talking)
    // During a share, lists in windows the reading does not use still protect it (PR #4352
    // cloud review): their `(me)` marks and their names shown twice.
    let selfList = uniqueInOrder(selfNames + (share.isSharing ? share.selfMarks : []))
    let peopleNames = people.compactMap(\.name)
    let participants = people.enumerated().map { index, tile in
      CallParticipant(
        key: index < thumbnails.count ? "thumbnail-\(index)" : "large", name: tile.name,
        isTalking: tile.talking,
        isSelf: tile.name != nil && selfList == [tile.name!]
          && peopleNames.filter { $0 == tile.name }.count == 1)
    }
    // Every list's own duplicates are two people, whether or not that list is complete.
    let listedTwice = lists.reduce(into: Set<String>()) { shared, list in
      shared.formUnion(repeatedNames(list.rows.entries.map { panelEntry($0).name }))
    }.union(share.isSharing ? share.listedTwice : [])
    // Identity holds when the tiles are the people and no talking flag sits elsewhere.
    let identity = !thumbnails.isEmpty && !flaggedOutsidePeople
    let account = accountName(fromTitles: accountTitles)
    // The user's share hid every count (#4013 share plan §3.3); read from the whole capture.
    // Every tile the copy shows must be in the windows read, so a person in a window window
    // choice left out can never be missing from a two-person proof.
    let countHidden =
      share.hostShare && !share.countShown
      && share.tileCount == thumbnails.count + largeTiles.count
    // During a screen share Zoom may show the talker without a flag (#4013 share plan §3.1-3.2):
    // a `Talking:` label in the collapsed floating window, or one tile that follows the talker.
    if share.isSharing, let signal = shareSignal(windows: windows, share: share) {
      return shareReading(
        signal, selfList: selfList, account: account, complete: complete, count: count,
        listedTwice: listedTwice, countHidden: countHidden)
    }
    let flagSource: CallSpeakerReading.TalkerSource? =
      participants.contains(where: \.isTalking) ? .flag : nil
    if let complete {
      let names = complete.entries.map { panelEntry($0).name }
      return CallSpeakerReading(
        speaking: uniqueInOrder(speaking),
        roster: CallSpeakerRoster(names: names, selfNames: selfList),
        rosterFromParticipantList: true, participants: participants,
        participantIdentityEstablished: identity,
        sharedNames: listedTwice.union(repeatedNames(peopleNames)),
        // Complete only when every count the call shows agrees with it; a conflict leaves the
        // names as names but never confirms that anyone left.
        participantListComplete: count != nil, participantCount: count,
        accountSelfNames: account, talkerSource: flagSource, countHiddenByShare: countHidden)
    }
    return CallSpeakerReading(
      speaking: uniqueInOrder(speaking),
      roster: CallSpeakerRoster(
        names: identity ? peopleNames : uniqueInOrder(tileNames), selfNames: selfList),
      rosterFromParticipantList: false, participants: participants,
      participantIdentityEstablished: identity,
      sharedNames: listedTwice.union(repeatedNames(peopleNames)),
      participantCount: count, accountSelfNames: account, talkerSource: flagSource,
      countHiddenByShare: countHidden)
  }

  /// The talker signal a screen-share layout shows instead of an `active speaker` flag.
  enum ShareSignal: Equatable {
    /// The collapsed floating window's `Talking: <name>`; `""` when nobody talks.
    case label(String)
    /// The one tile Zoom shows, which follows the talker and keeps the last one through silence.
    case loneTile(name: String, talking: Bool)
  }

  /// The share signal in the chosen windows, or `nil` when the layout is not one of the observed
  /// share shapes (then the tile-flag reading applies, as before). Every tile Zoom draws counts,
  /// large, unnamed and joining ones included.
  /// - No tile at all: exactly one `Talking: ` text in a compact window.
  /// - Exactly one tile, named and not joining: the meeting window's large tile (no video state)
  ///   while someone else shares (Side-by-side: Speaker), or a compact window's tile while the
  ///   user shares ("Show active speaker video"). It talks when its audio is unmuted or Zoom
  ///   flags it.
  static func shareSignal(windows: [CallAXWindow], share: ShareContext) -> ShareSignal? {
    let tiles = windows.flatMap { window in
      window.root.allNodes.compactMap { node -> (window: CallAXWindow, tile: Tile)? in
        guard node.role == "AXTabGroup", let label = node.label, let tile = parseTile(label)
        else { return nil }
        return (window, tile)
      }
    }
    if tiles.isEmpty {
      let labels = windows.filter(isCompactWindow).flatMap(talkingLabels)
      return labels.count == 1 ? .label(labels[0]) : nil
    }
    guard tiles.count == 1, let only = tiles.first, !only.tile.name.isEmpty, !only.tile.isJoining
    else { return nil }
    let isMeeting = ZoomCallWindow.isMeeting(
      identifier: only.window.root.identifier, title: only.window.title)
    let shape =
      (share.guestShare && isMeeting && !only.tile.hasVideoState)
      || (share.hostShare && isCompactWindow(only.window))
    guard shape else { return nil }
    return .loneTile(
      name: only.tile.name, talking: only.tile.isUnmuted || only.tile.isActiveSpeaker)
  }

  /// A share-layout reading (#4013 share plan §3.0-3.2). It needs the user's own name
  /// (`identifiedSelf`): without it the reading is quiet and adds no name, and a signal naming
  /// the user is quiet too, so the user's own speech never becomes a far-side vote. Lists in the
  /// chosen windows keep their shared names, self marks and complete-roster facts; the signal
  /// alone never makes a list complete.
  static func shareReading(
    _ signal: ShareSignal, selfList: [String], account: [String], complete: PanelRows?,
    count: Int?, listedTwice: Set<String>, countHidden: Bool
  ) -> CallSpeakerReading {
    var participants: [CallParticipant] = []
    let source: CallSpeakerReading.TalkerSource
    if let me = identifiedSelf(marks: selfList, account: account) {
      switch signal {
      case .label(let name):
        if !name.isEmpty, name != me {
          participants = [
            CallParticipant(key: "talking-label", name: name, isTalking: true, isSelf: false)
          ]
        }
      case .loneTile(let name, let talking):
        if name != me {
          participants = [
            CallParticipant(key: "lone-tile", name: name, isTalking: talking, isSelf: false)
          ]
        }
      }
    }
    switch signal {
    case .label: source = .label
    case .loneTile: source = .loneTile
    }
    let shown = participants.compactMap(\.name)
    let speaking = participants.filter(\.isTalking).compactMap(\.name)
    if let complete {
      return CallSpeakerReading(
        speaking: speaking,
        roster: CallSpeakerRoster(
          names: complete.entries.map { panelEntry($0).name }, selfNames: selfList),
        rosterFromParticipantList: true, participants: participants,
        participantIdentityEstablished: true, sharedNames: listedTwice,
        participantListComplete: count != nil, participantCount: count,
        accountSelfNames: account, talkerSource: source, countHiddenByShare: countHidden)
    }
    return CallSpeakerReading(
      speaking: speaking, roster: CallSpeakerRoster(names: shown, selfNames: selfList),
      rosterFromParticipantList: false, participants: participants,
      participantIdentityEstablished: true, sharedNames: listedTwice, participantCount: count,
      accountSelfNames: account, talkerSource: source, countHiddenByShare: countHidden)
  }

  /// The participants panel's rows (2026-10-29, `zoom-1on1-findings-2026-10-29.md`): each person
  /// is an `AXCell` whose identifier says what it is. A joined person's row
  /// (`ZMHCTableItemType_PANELIST`) holds one text, the entry, and a "More options for <name>"
  /// button; the row counts only when that button names the same person, since Zoom fills a
  /// joining row before binding it to anyone. Waiting-room rows and section headers are not
  /// people on the call. A joined row Zoom has not bound, or a row of an unobserved kind, is
  /// unresolved: the list is then not complete.
  struct PanelRows: Equatable {
    var entries: [String] = []
    var unresolved = false
  }

  static let joinedRowIdentifier = "ZMHCTableItemType_PANELIST"
  static let notJoinedRowIdentifiers: Set<String> = [
    "ZMHCTableItemType_PANELIST_Group", "ZMHCTableItemType_WAITINGLIST",
    "ZMHCTableItemType_WAITINGLIST_Group",
  ]
  static let moreOptionsPrefix = "More options for "
  static let moreOptionsStates = [", collapsed", ", expanded"]

  static func panelRows(_ outline: CallAXNode) -> PanelRows {
    var rows = PanelRows()
    for cell in outline.allNodes where cell.role == "AXCell" {
      if cell.identifier == joinedRowIdentifier {
        if let entry = boundEntry(cell) {
          rows.entries.append(entry)
        } else {
          rows.unresolved = true
        }
      } else if let identifier = cell.identifier, notJoinedRowIdentifiers.contains(identifier) {
        continue
      } else {
        // A row of an unobserved kind, filled or still empty, may be a person.
        rows.unresolved = true
      }
    }
    return rows
  }

  /// A joined row's entry, when its one text and its "More options for" button name the same
  /// person; otherwise `nil`.
  static func boundEntry(_ cell: CallAXNode) -> String? {
    let texts = cell.children.filter { $0.role == "AXStaticText" }.compactMap(\.label)
    guard texts.count == 1, let entry = texts.first else { return nil }
    let name = panelEntry(entry).name
    let bound = moreOptionsStates.map { moreOptionsPrefix + name + $0 }
    return cell.children.contains { $0.role == "AXMenuButton" && bound.contains($0.label ?? "") }
      ? entry : nil
  }

  /// The signed-in account's display name when exactly one account is checked and its title has
  /// the observed shape; otherwise none.
  static func accountName(fromTitles titles: [String]?) -> [String] {
    guard let titles, titles.count == 1,
      let name = CallAccountMenu.displayName(fromTitle: titles[0])
    else { return [] }
    return [name]
  }

  static let closedPanelButtonPrefix = "Open participants panel, closed, "

  /// `Open participants panel, closed, 4 participants` → 4 (Zoom also writes `1 participants`,
  /// 2026-10-29). Only the observed English shape; any other text, a waiting-room tail included,
  /// → `nil`, so another language leaves it unknown.
  static func closedPanelCount(_ label: String) -> Int? {
    guard label.hasPrefix(closedPanelButtonPrefix) else { return nil }
    let rest = label.dropFirst(closedPanelButtonPrefix.count)
    let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
    guard !digits.isEmpty, let count = Int(digits) else { return nil }
    let tail = rest.dropFirst(digits.count)
    guard tail == " participants" || (count == 1 && tail == " participant") else { return nil }
    return count
  }

  /// `Participants (4)` → 4. Any other text → `nil`.
  static func participantCount(_ label: String) -> Int? {
    guard label.hasPrefix(participantsCountPrefix), label.hasSuffix(")") else { return nil }
    let digits = label.dropFirst(participantsCountPrefix.count).dropLast()
    guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else {
      return nil
    }
    return Int(digits)
  }

  // MARK: - Screen share (#4013 share plan §3.0)

  /// What the WHOLE capture says about a screen share and about counts, read before window
  /// choice (#4013 share plan §3.0, review r2 R1): the share toolbar and the count texts sit in
  /// windows the speaker reading never receives, so they are read here, from every copied
  /// window, and passed on explicitly. They never supply participants.
  package struct ShareContext: Sendable, Equatable {
    /// The user is sharing: Zoom showed its share toolbar window.
    package let hostShare: Bool
    /// Someone else is sharing: the meeting window shows the shared content.
    package let guestShare: Bool
    /// Any participant count or participants list appeared anywhere in the copy, readable or
    /// not. Absent is not unknown: a count Zoom shows in a shape we do not parse still counts
    /// as shown, so only a copy with no count at all can say the share hid it.
    package let countShown: Bool
    /// Names any participants list in the copy shows twice, and the user's `(me)` marks, from
    /// EVERY window (PR #4352 cloud review): a share reading may be read from the floating
    /// window alone while the list sits in a popped-out window window choice leaves out, and
    /// these only ever protect (a shared name is never voted; a mark only tells who the user is).
    package let listedTwice: Set<String>
    package let selfMarks: [String]
    /// Every participant tile the copy shows, in any window, named or not.
    package let tileCount: Int

    package static let none = ShareContext(hostShare: false, guestShare: false, countShown: false)

    package var isSharing: Bool { hostShare || guestShare }

    package init(
      hostShare: Bool, guestShare: Bool, countShown: Bool, listedTwice: Set<String> = [],
      selfMarks: [String] = [], tileCount: Int = 0
    ) {
      self.tileCount = tileCount
      self.hostShare = hostShare
      self.guestShare = guestShare
      self.countShown = countShown
      self.listedTwice = listedTwice
      self.selfMarks = selfMarks
    }
  }

  /// Observed 2026-11-03 (run `20261103-083021-4013-share-talking-label-discovery-c469`): every
  /// host-share copy has this window; no copy without a share does.
  static let shareToolbarWindowTitle = "zoom share toolbar window"
  /// The meeting window's shared-content element while someone else shares (every guest-share
  /// copy; Granola `isShareContent`).
  static let receivingShareLabel = "Share content"
  /// The participants panel toolbar button, open or closed, with or without a count
  /// ("Open participants panel, closed, 3 participants, 1 person is waiting").
  static let participantsPanelButtonPrefixes = [
    "Open participants panel", "Close participants panel",
  ]

  package static func shareContext(windows: [CallAXWindow]) -> ShareContext {
    let hostShare = windows.contains { $0.title == shareToolbarWindowTitle }
    let guestShare = windows.contains { window in
      ZoomCallWindow.isMeeting(identifier: window.root.identifier, title: window.title)
        && window.root.allNodes.contains {
          $0.role == "AXUnknown" && $0.label == receivingShareLabel
        }
    }
    let countShown = windows.contains { window in
      window.root.allNodes.contains { node in
        guard let label = node.label else { return false }
        if node.role == "AXOutline", label == participantsListLabel { return true }
        if node.role == "AXStaticText", label.hasPrefix(participantsCountPrefix) { return true }
        return node.role == "AXButton"
          && participantsPanelButtonPrefixes.contains { label.hasPrefix($0) }
          && label.contains { $0.isNumber }
      }
    }
    let nodes = windows.flatMap { $0.root.allNodes }
    let rows = nodes.filter { $0.role == "AXOutline" && $0.label == participantsListLabel }
      .map { panelRows($0).entries }
    let listedTwice = rows.reduce(into: Set<String>()) { shared, entries in
      shared.formUnion(repeatedNames(entries.map { panelEntry($0).name }))
    }
    // Only a bound participants-list row's `(me)` counts here, never any other text (a chat
    // message ending in "(me)" must not say who the user is).
    let selfMarks = uniqueInOrder(rows.flatMap { $0.compactMap(selfName(fromParticipantEntry:)) })
    let tileCount = nodes.filter { node in
      node.role == "AXTabGroup" && node.label.flatMap(parseTile) != nil
    }.count
    return ShareContext(
      hostShare: hostShare, guestShare: guestShare, countShown: countShown,
      listedTwice: listedTwice, selfMarks: selfMarks, tileCount: tileCount)
  }

  /// The one name the user goes by in this reading, or `nil` when it cannot be told (#4013 share
  /// plan §3.0, review r1 F4): the panel's `(me)` mark when it names exactly one person, else
  /// exactly one checked account. A mark and an account that disagree, or two marks, are
  /// conflicting evidence: `nil`.
  static func identifiedSelf(marks: [String], account: [String]) -> String? {
    let marked = uniqueInOrder(marks)
    guard marked.count <= 1, account.count <= 1 else { return nil }
    if let mark = marked.first {
      if let other = account.first, other != mark { return nil }
      return mark
    }
    return account.first
  }

  /// The floating video window Zoom shows while the meeting window is hidden or full screen:
  /// it carries the mode buttons below (Granola `isCompactVideoWindow`'s English pair). Every
  /// observed floating window has both; the full-screen one lacks the other three modes, so
  /// only these two are required.
  static let compactWindowButtons: Set<String> = [
    "Hide thumbnail video", "Show active speaker video",
  ]

  static func isCompactWindow(_ window: CallAXWindow) -> Bool {
    guard !ZoomCallWindow.isMeeting(identifier: window.root.identifier, title: window.title)
    else { return false }
    let buttons = Set(window.root.allNodes.filter { $0.role == "AXButton" }.compactMap(\.label))
    return compactWindowButtons.isSubset(of: buttons)
  }

  static let talkingPrefix = "Talking: "

  /// `Talking: Bea Chen` → `Bea Chen`; `Talking: ` → `""` (nobody talking). Only the exact
  /// observed English prefix; any other text → `nil`.
  static func talkingName(_ label: String) -> String? {
    guard label.hasPrefix(talkingPrefix) else { return nil }
    return String(label.dropFirst(talkingPrefix.count))
  }

  /// Every `Talking: ` text a compact window shows (Zoom's collapsed floating window).
  static func talkingLabels(_ window: CallAXWindow) -> [String] {
    window.root.allNodes.filter { $0.role == "AXStaticText" }.compactMap {
      $0.label.flatMap(talkingName)
    }
  }

  /// `Saurabh A Vaish (Host, me)` → name `Saurabh A Vaish`. Only a trailing bracket made of
  /// Zoom's own tags is removed, so a name such as `Dana (Design)` keeps its bracket.
  static func panelEntry(_ label: String) -> (name: String, tags: [String]) {
    guard label.hasSuffix(")"), let open = label.range(of: " (", options: .backwards) else {
      return (label, [])
    }
    let tags = label[open.upperBound..<label.index(before: label.endIndex)]
      .components(separatedBy: ", ")
    guard tags.allSatisfy(panelTags.contains) else { return (label, []) }
    let name = String(label[..<open.lowerBound])
    return name.isEmpty ? (label, []) : (name, tags)
  }

  /// `Lee, Dana, Computer audio unmuted, Video off, active speaker` → name `Lee, Dana`, talking.
  /// Read from the end, where Zoom's structure is fixed: an optional `active speaker`, an
  /// optional video state, then exactly one audio state. Everything before that is the name, so
  /// commas and look-alike words inside a name survive. Any other ending is not read (no guess).
  typealias Tile = (
    name: String, isActiveSpeaker: Bool, hasVideoState: Bool, isJoining: Bool, isUnmuted: Bool
  )

  static func parseTile(_ label: String) -> Tile? {
    var parts = label.components(separatedBy: ", ")
    let isActiveSpeaker = parts.last == activeSpeakerFlag
    if isActiveSpeaker { parts.removeLast() }
    var hasVideoState = false
    if let last = parts.last, videoStates.contains(last) {
      parts.removeLast()
      hasVideoState = true
    }
    guard let state = parts.popLast(), audioStates.contains(state) else { return nil }
    // An empty name is returned as "": the tile is still a person the caller must not drop.
    // "No audio connected" is how a joining person's tile reads for its first moments.
    return (
      parts.joined(separator: ", "), isActiveSpeaker, hasVideoState, state == noAudioState,
      state == unmutedAudioState
    )
  }

  /// The participants panel marks the user: `Saurabh A Vaish (Host, me)` or `Dana (me)`.
  /// Only an explicit `me` counts; `(Host)` or `(Co-host)` alone is a role, not the user.
  static func selfName(fromParticipantEntry label: String) -> String? {
    guard label.hasSuffix(")"), let open = label.range(of: " (", options: .backwards) else {
      return nil
    }
    let inner = label[open.upperBound..<label.index(before: label.endIndex)]
    guard inner.components(separatedBy: ", ").contains("me") else { return nil }
    let name = String(label[..<open.lowerBound])
    return name.isEmpty ? nil : name
  }
}

/// Reads the Microsoft Teams app (teams2) (#4013 r1 R1). Observed 2026-10-27
/// (`docs/audits/2026-10-27-4013/teams-mac-names-findings.md`): the compact meeting view shows
/// `<Name> (Guest) is speaking`; roster rows read `<Name>[ (Guest)], <role>, <state>`; the
/// user's own tile reads `Myself video, <Name>, ...`. A role such as `Organizer` never marks the
/// user, and the main meeting window showed no talker signal, so none is read from it.
package enum TeamsAppSpeakerReader {
  static let speakingSuffix = " is speaking"
  static let guestSuffix = " (Guest)"
  static let selfTilePrefix = "Myself video, "
  /// Roles Teams places after the name in a roster row.
  static let roles: Set<String> = [
    "Organizer", "Co-organizer", "Presenter", "Attendee", "Meeting guest",
  ]
  /// The mute state that ends a roster row.
  static let muteStates: Set<String> = ["Muted", "Unmuted"]
  /// What follows the name on the user's own tile ("Muted, Has context menu").
  static let tileStates: Set<String> = [
    "Muted", "Unmuted", "Has context menu", "Context menu is available",
  ]

  package static func read(windows: [CallAXWindow]) -> CallSpeakerReading {
    var speaking: [String] = []
    var rosterNames: [String] = []
    var selfTiles: [String] = []
    var tileNames: [String] = []
    var unnamedTalker = false
    var selfTileTalking = false
    // Each window's roster rows and the "In this meeting, N total" counts shown in that window.
    var rosters: [(names: [String], counts: Set<Int>)] = []
    // Every "In this meeting, N total" any window of the call shows.
    var allCounts: Set<Int> = []
    for window in windows {
      let nodes = window.root.allNodes
      let names = nodes.filter { $0.role == "AXRow" }.compactMap { $0.label.flatMap(rosterName) }
      let counts = Set(nodes.compactMap { $0.label.flatMap(meetingCount) })
      allCounts.formUnion(counts)
      if !names.isEmpty { rosters.append((names, counts)) }
    }
    for node in windows.flatMap({ $0.root.allNodes }) {
      guard let label = node.label else {
        // A gallery tile with no label at all can still hold the talking frame: someone
        // unknown is talking.
        if node.role == "AXMenuItem", hasTalkingFrame(node) { unnamedTalker = true }
        continue
      }
      switch node.role {
      case "AXGroup" where label.hasSuffix(speakingSuffix):
        let name = displayName(String(label.dropLast(speakingSuffix.count)))
        if name.isEmpty { unnamedTalker = true } else { speaking.append(name) }
      case "AXRow":
        if let name = rosterName(label) { rosterNames.append(name) }
      case "AXMenuItem" where label.hasPrefix(selfTilePrefix):
        selfTiles.append(String(label.dropFirst(selfTilePrefix.count)))
        if hasTalkingFrame(node) { selfTileTalking = true }
      case "AXMenuItem":
        // The main window marks the talker's gallery tile with a frame carrying this class
        // (C1 Teams run 2, 2026-10-28; the signal Superwhisper reads).
        let talkingTile = hasTalkingFrame(node)
        if let name = tileName(label) {
          tileNames.append(name)
          if talkingTile { speaking.append(name) }
        } else if talkingTile {
          unnamedTalker = true
        }
      default:
        break
      }
    }
    // The self tile's text continues past the name ("Saurabh Vaish, Muted, ..."). A roster name
    // marks the user only when the text after it is a tile state or nothing, so "Lee" never
    // matches "Myself video, Lee, Dana, ...". More than one match is ambiguous: nobody is marked.
    let candidates = uniqueInOrder(rosterNames).filter { name in
      selfTiles.contains { tile in
        if tile == name { return true }
        guard tile.hasPrefix(name + ", ") else { return false }
        // Every remaining part must be a known tile state, so "Lee, Muted engineer, Muted"
        // never makes "Lee" the user.
        return tile.dropFirst(name.count + 2).components(separatedBy: ", ")
          .allSatisfy(tileStates.contains)
      }
    }
    // With People closed there are no rows: the one self tile gives the user's exact name.
    let selfFromTile = selfTiles.count == 1 ? selfTileName(selfTiles[0]) : nil
    let selfNames =
      rosterNames.isEmpty
      ? (selfFromTile.map { [$0] } ?? []) : (candidates.count == 1 ? candidates : [])
    // The user's own tile talking is the user (the namer removes self); a self tile whose name is
    // not known adds nobody.
    if selfTileTalking, selfNames.count == 1 { speaking.append(selfNames[0]) }
    // A complete participant list (C1 Teams run, 2026-10-28): roster rows in exactly one window,
    // whose own "In this meeting, N total" count is the one count there and equals the people
    // read. Duplicate names stay; a partial, uncounted or contested list keeps its names for
    // suggestions but is not a participant list.
    let complete =
      rosters.count == 1 && rosters[0].counts == [rosters[0].names.count]
    // People: the roster rows when People is open, one row per person; otherwise the gallery
    // tiles, one per person, with the user's own tile. Never both, so a row and its tile are not
    // counted as two people. A talker shown in neither is still a participant.
    let shown: [String]
    if rosters.count == 1 {
      shown = rosters[0].names
    } else if rosters.isEmpty {
      shown = tileNames + (selfNames.count == 1 ? selfNames : [])
    } else {
      shown = []
    }
    let talking = Set(uniqueInOrder(speaking))
    var participants = shown.enumerated().map { index, name in
      CallParticipant(
        key: "person-\(index)", name: name, isTalking: talking.contains(name),
        isSelf: selfNames == [name] && shown.filter { $0 == name }.count == 1)
    }
    if unnamedTalker {
      participants.append(
        CallParticipant(key: "unnamed-talker", name: nil, isTalking: true, isSelf: false))
    }
    for (index, name) in uniqueInOrder(speaking).enumerated() where !shown.contains(name) {
      participants.append(
        CallParticipant(key: "talker-\(index)", name: name, isTalking: true, isSelf: false))
    }
    let agreed: Int? =
      complete && allCounts == [rosters[0].names.count] ? rosters[0].names.count : nil
    return CallSpeakerReading(
      speaking: uniqueInOrder(speaking),
      // With People closed the gallery is the roster offered for renaming.
      roster: CallSpeakerRoster(
        names: rosterNames.isEmpty ? shown : rosterNames, selfNames: selfNames),
      rosterFromParticipantList: complete, participants: participants,
      // Rows in two windows cannot be matched to each other: no identity.
      participantIdentityEstablished: rosters.count <= 1 && !participants.isEmpty,
      // Each representation's own duplicates are two people; rows and tiles are never added.
      sharedNames: rosters.reduce(into: repeatedNames(tileNames)) {
        $0.formUnion(repeatedNames($1.names))
      },
      // Rows in one window whose "In this meeting, N total" count equals the rows read, when no
      // other window of the call shows another count. The list is everyone, so a tile this
      // reader could not parse cannot hide a third person.
      participantListComplete: agreed != nil, participantCount: agreed)
  }

  static let compactViewPrefix = "Meeting compact view | "

  /// The meetings the windows showing meeting content belong to: each such window's title with
  /// the compact-view prefix removed, so the compact view and its main window are one meeting.
  /// `nil` when a window showing meeting content has no title (it cannot be matched).
  package static func meetingTitles(windows: [CallAXWindow]) -> Set<String>? {
    var titles: Set<String> = []
    for window in windows where showsMeeting(window.root) {
      guard let title = window.title, !title.isEmpty else { return nil }
      let compact = title.hasPrefix(compactViewPrefix)
      titles.insert(compact ? String(title.dropFirst(compactViewPrefix.count)) : title)
    }
    return titles
  }

  /// Whether a window holds anything this reader reads: a talker label, a roster row, a tile.
  static func showsMeeting(_ root: CallAXNode) -> Bool {
    root.allNodes.contains { node in
      guard let label = node.label else {
        return node.role == "AXMenuItem" && hasTalkingFrame(node)
      }
      switch node.role {
      case "AXGroup": return label.hasSuffix(speakingSuffix)
      case "AXRow": return rosterName(label) != nil
      case "AXMenuItem": return label.hasPrefix(selfTilePrefix) || tileName(label) != nil
      default: return false
      }
    }
  }

  /// `Saurabh Vaish, Muted, Has context menu` (after "Myself video, ") → `Saurabh Vaish`:
  /// trailing tile states removed, the rest kept exactly.
  static func selfTileName(_ tile: String) -> String? {
    var parts = tile.components(separatedBy: ", ")
    while let last = parts.last, tileStates.contains(last) { parts.removeLast() }
    let name = parts.joined(separator: ", ")
    return name.isEmpty ? nil : name
  }

  /// A gallery tile, `Alex Rivera (Guest), muted, Context menu is available` → `Alex Rivera`.
  /// Read from the end: tile states only, then the name. Any other ending is not a tile.
  static func tileName(_ label: String) -> String? {
    var parts = label.components(separatedBy: ", ")
    guard parts.last == "Context menu is available" else { return nil }
    while let last = parts.last, galleryTileStates.contains(last) { parts.removeLast() }
    let name = displayName(parts.joined(separator: ", "))
    return name.isEmpty ? nil : name
  }

  /// The class on the frame inside the talker's gallery tile in the main meeting window.
  static let talkingFrameClass = "vdi-frame-occlusion"

  /// Whether the tile's own subtree holds the talking frame. A tile nested inside it is another
  /// participant, so its frame is never this tile's.
  static func hasTalkingFrame(_ tile: CallAXNode) -> Bool {
    var queue = tile.children
    while !queue.isEmpty {
      let node = queue.removeFirst()
      if node.role == "AXMenuItem" { continue }
      if node.domClassList.contains(talkingFrameClass) { return true }
      queue.append(contentsOf: node.children)
    }
    return false
  }

  /// What follows the name on another participant's gallery tile (C1 Teams run, 2026-10-28).
  static let galleryTileStates: Set<String> = ["muted", "Context menu is available"]

  /// `In this meeting, 4 total` or `In this meeting, 4 total Mute all` → 4. Any other text → nil.
  static func meetingCount(_ label: String) -> Int? {
    let prefix = "In this meeting, "
    guard label.hasPrefix(prefix) else { return nil }
    let rest = label.dropFirst(prefix.count)
    let digits = rest.prefix { $0.isASCII && $0.isNumber }
    guard !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(" total") else { return nil }
    let tail = rest.dropFirst(digits.count + " total".count)
    guard tail.isEmpty || tail == " Mute all" else { return nil }
    return Int(digits)
  }

  /// `Alex Rivera (Guest), Meeting guest, Muted` → `Alex Rivera`. Read from the end: an optional
  /// mute state, then exactly one role; everything before is the name, so a role word inside a
  /// name survives. A row without that ending (the "In this meeting, 4 total" header) is not a
  /// person.
  static func rosterName(_ label: String) -> String? {
    var parts = label.components(separatedBy: ", ")
    if let last = parts.last, muteStates.contains(last) { parts.removeLast() }
    guard let role = parts.popLast(), roles.contains(role) else { return nil }
    let name = displayName(parts.joined(separator: ", "))
    return name.isEmpty ? nil : name
  }

  static func displayName(_ raw: String) -> String {
    raw.hasSuffix(guestSuffix) ? String(raw.dropLast(guestSuffix.count)) : raw
  }
}
