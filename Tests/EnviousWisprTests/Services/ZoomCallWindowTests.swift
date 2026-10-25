import Testing

@testable import EnviousWisprServices

/// #4036: EnviousMeet noticed a Zoom call only when the window title held the English
/// "Zoom Meeting", so a French, Spanish or Japanese Zoom never got "Ask to record". When these
/// fail, a Zoom call in another language goes unnoticed, or a non-meeting window counts as a call.
@Suite("Zoom meeting windows in every language", .tags(.productOutcome))
struct ZoomCallWindowTests {
  typealias Read = ZoomCallWindow.Read

  /// Windows as (identifier, title) reads, classified the way the reader does.
  func verdict(_ windows: [(Read, Read)]) -> ZoomCallWindow.Verdict {
    ZoomCallWindow.classify(
      windowCount: windows.count, identifier: { windows[$0].0 }, title: { windows[$0].1 })
  }

  @Test("The meeting window counts in English and French, as read live from Zoom 7.1.9")
  func liveMeetingWindows() {
    let meeting = Read.value("zm.meeting.window.main")
    let home = (Read.missing, Read.value("Zoom Workplace"))
    #expect(verdict([home, (meeting, .value("Zoom Meeting"))]) == .call)
    #expect(verdict([home, (meeting, .value("Réunion Zoom"))]) == .call)
    // The join preview window already carries the identifier.
    #expect(verdict([(meeting, .value("Alex Doe's Zoom Meeting")), home]) == .call)
    #expect(verdict([home]) == .none)
  }

  @Test("Every localized meeting and webinar title counts without the identifier")
  func localizedTitles() {
    let titles = [
      "Zoom Meeting", "Reunión de Zoom", "Réunion Zoom", "Riunione Zoom", "Zoom ミーティング",
      "Zoom 회의", "Zoom-vergadering", "Spotkanie Zoom", "Reunião Zoom", "Конференция Zoom",
      "Zoom-möte", "Zoom Toplantısı", "Cuộc họp Zoom", "Zoom会议", "Zoom會議",
      "Zoom Webinar", "Zoom-Webinar", "Seminario web de Zoom", "Webinaire Zoom", "Webinar Zoom",
      "Zoom ウェビナー", "Zoom 웨비나", "Webinar w Zoomie", "Вебинар Zoom", "Zoom Web Semineri",
      "Hội thảo trực tuyến Zoom", "Zoom网络研讨会", "Zoom網路研討會",
    ]
    for title in titles {
      #expect(verdict([(.missing, .value(title))]) == .call, "\(title)")
    }
    // Zoom's own Vietnamese strings arrive decomposed; spacing around a title is ignored.
    let decomposed = "Cuộc họp Zoom".decomposedStringWithCanonicalMapping
    #expect(decomposed.unicodeScalars.count > "Cuộc họp Zoom".unicodeScalars.count)
    #expect(verdict([(.missing, .value(decomposed))]) == .call)
    #expect(verdict([(.missing, .value("  RÉUNION ZOOM \n"))]) == .call)
  }

  /// The old rule (`contains("zoom meeting")`) missed "Réunion Zoom" and took any window whose
  /// title merely held the phrase; the whole title must match now.
  @Test("Other Zoom windows do not count")
  func otherWindows() {
    for title in ["Zoom Workplace", "Zoom", "zoom meeting prep", "Réunion Zoom notes", ""] {
      #expect(verdict([(.missing, .value(title))]) == .none, "\(title)")
    }
    #expect(verdict([(.value("zm.home.window"), .value("Zoom Workplace"))]) == .none)
  }

  @Test("A failed read is unknown only when no window proved a meeting")
  func failedReads() {
    let meeting = Read.value("zm.meeting.window.main")
    #expect(verdict([(meeting, .failed)]) == .call)
    #expect(verdict([(.failed, .value("Réunion Zoom"))]) == .call)
    #expect(verdict([(.failed, .failed), (meeting, .missing)]) == .call)
    #expect(verdict([(.missing, .failed), (.missing, .value("Zoom Workplace"))]) == .unknown)
    #expect(verdict([(.failed, .value("Zoom Workplace"))]) == .unknown)
    #expect(verdict([]) == .none)
  }

  @Test("The title is not read once the identifier proves a meeting")
  func stopsAtIdentifier() {
    var titleReads = 0
    let result = ZoomCallWindow.classify(
      windowCount: 2, identifier: { _ in .value("zm.meeting.window.main") },
      title: { _ in
        titleReads += 1
        return .missing
      })
    #expect(result == .call)
    #expect(titleReads == 0)
  }
}
