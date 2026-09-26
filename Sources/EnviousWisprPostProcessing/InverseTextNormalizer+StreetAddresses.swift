import Foundation

/// #3211: a dictated US street address gets its numbers written and its commas, English route
/// only. Founder samples: Parakeet's `9 High Plains Road Shelton Connecticut 06484` pasted with no
/// commas, and `Three twenty West 38th Street, apartment two twenty, …` kept both numbers spelled,
/// because a single digit then a ten ("three twenty") is ambiguous in prose. Inside a complete
/// address it is not.
///
/// Style (recorded on #3211): the words the speaker said stay (`West`, `Street`, `apartment`,
/// `New York`), no postal abbreviations; only digits and commas are added. The pass fires only on
/// a WHOLE address: house number, street ending in a street-type word, optional unit, city, state,
/// ZIP. Anything short of that (no state, no ZIP, an ambiguous city split) is left exactly as
/// spoken. Baseline v1 (#3211, 46 Azure clips): Parakeet 19/34, WhisperKit 26/34 on main 67490d7b.
extension InverseTextNormalizer {

  /// Full street-type words, a subset of USPS Publication 28 Appendix C1 (never the abbreviations).
  static let streetTypes = [
    "Road", "Street", "Avenue", "Lane", "Drive", "Boulevard", "Court", "Way", "Place", "Circle",
    "Terrace", "Parkway", "Trail", "Highway",
  ]
  static let streetDirections = [
    "Northeast", "Northwest", "Southeast", "Southwest", "North", "South", "East", "West",
  ]
  /// Unit words as a recogniser writes them; the case the speaker got is kept.
  static let streetUnitWords = [
    "Apartment", "apartment", "Apt", "apt", "Suite", "suite", "Unit", "unit", "Room", "room",
    "Floor", "floor",
  ]
  static let usStates = [
    "Alabama", "Alaska", "Arizona", "Arkansas", "California", "Colorado", "Connecticut",
    "Delaware", "Florida", "Georgia", "Hawaii", "Idaho", "Illinois", "Indiana", "Iowa", "Kansas",
    "Kentucky", "Louisiana", "Maine", "Maryland", "Massachusetts", "Michigan", "Minnesota",
    "Mississippi", "Missouri", "Montana", "Nebraska", "Nevada", "New Hampshire", "New Jersey",
    "New Mexico", "New York", "North Carolina", "North Dakota", "Ohio", "Oklahoma", "Oregon",
    "Pennsylvania", "Rhode Island", "South Carolina", "South Dakota", "Tennessee", "Texas", "Utah",
    "Vermont", "Virginia", "Washington", "West Virginia", "Wisconsin", "Wyoming",
    "District of Columbia",
  ]
  /// USPS two-letter codes, read only when the recogniser already wrote them in capitals.
  static let usStateCodes = [
    "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI", "ID", "IL", "IN", "IA", "KS",
    "KY", "LA", "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY",
    "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV",
    "WI", "WY", "DC",
  ]

  /// The address pattern, built once. Case-sensitive: capitals are how a name is told from prose.
  /// Every repetition is bounded, so a long near miss costs a bounded amount per start position.
  static let streetAddressPattern: String = {
    let numWord = #"(?i:"# + unitsTensAlt + #"|hundred|thousand)"#
    let digitWord = #"(?i:zero|oh|o|one|two|three|four|five|six|seven|eight|nine)"#
    let cap = #"[A-Z][\p{L}'’.-]*"#
    let longestFirst: ([String]) -> String = { words in
      words.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }
        .joined(separator: "|")
    }
    // The whole spoken number, "and" included ("one hundred and twenty three"); a match that
    // starts inside a longer number is refused in `streetAddresses` (Codex diff review r1).
    let house = #"(\d{1,6}|"# + numWord + #"(?:\s+(?:(?i:and)\s+)?"# + numWord + #"){0,5})"#
    let street =
      #"((?:(?:"# + cap + #"|\d{1,3}(?:st|nd|rd|th))\s+){1,4}(?:"#
      + streetTypes.joined(separator: "|")
      + #"))"#
    // One reading per gap (atomic): a comma, a line break, or spaces. An ambiguous whitespace run
    // here made a long near miss backtrack (6.9 s for 59,200 characters before this).
    let sep = #"((?>[^\S\n]*,[^\S\n]*\n?[^\S\n]*|[^\S\n]*\n[^\S\n]*|[^\S\n]+))"#
    // Written ("12", "4B", "4 B") or spoken ("two twenty", "one hundred and twenty three",
    // "four B"); a trailing single capital is the unit letter, never the start of the city.
    let unitNum =
      #"(?:\d{1,5}(?:[A-Z]|\s+[A-Z])?(?![\p{L}\d])|"# + numWord + #"(?:\s+(?:(?i:and)\s+)?"# + numWord
      + #"){0,5}(?:\s+[A-Z](?![\p{L}]))?)"#
    let unit =
      #"(?:((?:"# + streetUnitWords.joined(separator: "|") + #")\.?\s+"# + unitNum
      + #"|#\s?\d{1,5}[A-Z]?)"#
      + sep + #")?"#
    let city = #"("# + cap + #"(?:\s+"# + cap + #"){0,2})"#
    let state = #"("# + longestFirst(usStates) + #"|"# + usStateCodes.joined(separator: "|") + #")"#
    let zip =
      #"(\d{5}(?:-\d{4}|\s+(?i:dash|hyphen)\s+(?:\d{4}|"# + digitWord + #"(?:\s+"# + digitWord
      + #"){3}))?|"# + digitWord + #"(?:\s+"# + digitWord
      + #"){4}(?:\s+(?i:dash|hyphen)\s+(?:\d{4}|"#
      + digitWord + #"(?:\s+"# + digitWord + #"){3}))?)"#
    return #"(?<![\p{L}\d'’-])(?<!\d[,.])"# + house + #"\s+(?:(?:"# + streetDirections.joined(separator: "|")
      + #")\s+)?"# + street + sep + unit + city + sep + state + #"((?>[^\S\n]*,[^\S\n]*\n?[^\S\n]*|[^\S\n]*\n[^\S\n]*|[^\S\n]+))"# + zip
      + #"(?![\p{L}\d-])(?!\s+(?:"# + digitWord + #"(?![\p{L}])|\d))"#
  }()

  /// Groups of `streetAddressPattern`: 1 house, 2 street (with type), 3 street/unit separator,
  /// 4 unit (word and number), 5 unit/city separator, 6 city, 7 city/state separator, 8 state,
  /// 9 state/ZIP separator, 10 ZIP.
  func streetAddresses(_ t: String, protectFormatted: (String) -> String) -> String {
    // Cheap prefilter: no written or spoken five-digit run, no address.
    guard
      t.range(
        of:
          #"\d{5}|(?i:zero|oh|o|one|two|three|four|five|six|seven|eight|nine)\s+\w+\s+\w+\s+\w+\s+\w+"#,
        options: .regularExpression) != nil
    else { return t }
    return reSub(Self.streetAddressPattern, t, caseInsensitive: false) { m in
      guard let houseWords = m.g(1), let street = m.g(2), let city = m.g(6), let state = m.g(8),
        let zipWords = m.g(10)
      else { return nil }
      // The house number must be the whole number said: a match that begins after another number
      // word, alone or before "and", would format only the tail ("one hundred and 23 Main
      // Street"). A plain "and" is a conjunction ("the documents and nine High Plains Road").
      // Only the nearby text is read: copying all of it per match made a long transcript of many
      // addresses quadratic (Codex diff review r5: 300 addresses, 1.54 s).
      let location = m.result.range.location
      let windowStart = max(0, location - 48)
      let before = m.ns.substring(
        with: NSRange(location: windowStart, length: location - windowStart))
      let partOfLonger =
        #"(?i)(?:\b(?:"# + Self.unitsTensAlt + #"|hundred|thousand)(?:[^\S\n]+and)?|\d)[^\S\n]*$"#
      if before.range(of: partOfLonger, options: .regularExpression) != nil { return nil }
      // The city run must not hold a second street type: that split is ambiguous.
      let cityTokens = city.split(separator: " ").map(String.init)
      // A lone capital opening the city is a unit letter the unit pattern did not take.
      if cityTokens.first?.count == 1 { return nil }
      if cityTokens.contains(where: { Self.streetTypes.contains($0) }) { return nil }
      guard let house = Self.addressNumber(houseWords), let zip = Self.zipCode(zipWords) else {
        return nil
      }
      // A year after a time word is a date, not a house number, written or spoken ("In 2019 Main
      // Street Bank", "In twenty twenty Main Street Bank"): read on the parsed value.
      if house.count == 4, let y = Int(house), (1900...2099).contains(y),
        before.range(
          of: #"(?i)\b(?:in|since|by|from|until|before|after)\s+$"#, options: .regularExpression)
          != nil
      {
        return nil
      }
      // A street name that begins with the house number's own spelling ("Nine" read as a name)
      // is fine; a street that is only a type word is not an address.
      var out =
        house + " " + Self.directionAndStreet(m.whole, houseWords: houseWords, street: street)
      out += Self.addressSeparator(m.g(3) ?? " ")
      if let unit = m.g(4) {
        guard let rendered = Self.renderUnit(unit) else { return nil }
        out += rendered + Self.addressSeparator(m.g(5) ?? " ")
      }
      out += city + Self.addressSeparator(m.g(7) ?? " ") + state + ((m.g(9) ?? " ").contains("\n") ? "\n" : " ") + zip
      return protectFormatted(out)
    }
  }

  /// The text between the house number and the street name (a direction word) plus the street.
  private static func directionAndStreet(_ whole: String, houseWords: String, street: String)
    -> String
  {
    guard let houseEnd = whole.range(of: houseWords)?.upperBound,
      let streetStart = whole.range(of: street, range: houseEnd..<whole.endIndex)?.lowerBound
    else { return street }
    let between = whole[houseEnd..<streetStart].trimmingCharacters(in: .whitespaces)
    return between.isEmpty ? street : between + " " + street
  }

  /// A comma where the speaker gave none; a line break the recogniser wrote is kept.
  private static func addressSeparator(_ sep: String) -> String {
    sep.contains("\n") ? (sep.contains(",") ? ",\n" : "\n") : ", "
  }

  /// House or unit number: written digits; a strict cardinal ("eleven", "four hundred"); a hundred
  /// pair ("three twenty" 320, "fifteen twenty" 1520); or single digits ("one oh one" 101).
  static func addressNumber(_ s: String) -> String? {
    if s.allSatisfy(\.isNumber) { return s }
    let words = s.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
    // Pair reading: <1 to 99> then <20 to 99> ("three twenty", "fifteen twenty", "twenty two
    // forty five"), first part x 100 + second. Only inside an accepted address.
    for split in 1..<words.count {
      let tail = Array(words[split...])
      guard let second = tens[tail[0]] else { continue }
      var low = second
      if tail.count == 2 {
        guard let u = units[tail[1]], (1...9).contains(u) else { continue }
        low += u
      } else if tail.count > 2 {
        continue
      }
      guard let high = wordsToInt(Array(words[..<split])), (1...99).contains(high) else { continue }
      return String(high * 100 + low)
    }
    if let d = digitString(words), d.first != "0" { return d }
    if let v = wordsToInt(words), v > 0 { return String(v) }
    return nil
  }

  /// Five digits (plus four), written or spoken one digit at a time; a leading zero is kept.
  static func zipCode(_ s: String) -> String? {
    let parts = s.components(separatedBy: CharacterSet.whitespaces).filter { !$0.isEmpty }
    if parts.count == 1, s.first?.isNumber == true { return s }  // 06103 or 06103-1234
    let dashAt = parts.firstIndex { ["dash", "hyphen"].contains($0.lowercased()) }
    let head = Array(parts[..<(dashAt ?? parts.count)]).map { $0.lowercased() }
    let five: String
    if head.count == 1, head[0].count == 5, head[0].allSatisfy(\.isNumber) {
      five = head[0]  // written five digits, spoken +4
    } else {
      guard head.count == 5, let spoken = digitString(head) else { return nil }
      five = spoken
    }
    guard let dashAt else { return five }
    let tail = Array(parts[(dashAt + 1)...])
    if tail.count == 1, tail[0].count == 4, tail[0].allSatisfy(\.isNumber) {
      return five + "-" + tail[0]
    }
    guard tail.count == 4, let four = digitString(tail.map { $0.lowercased() }) else { return nil }
    return five + "-" + four
  }

  /// `apartment two twenty` → `apartment 220`; `Suite four B` → `Suite 4B`; `#12` as written.
  private static func renderUnit(_ unit: String) -> String? {
    if unit.hasPrefix("#") { return unit }
    let parts = unit.split(whereSeparator: \.isWhitespace).map(String.init)
    guard parts.count >= 2 else { return nil }
    // Already written ("Suite 12", "Suite 4B", the list-marker pass's form): kept as is.
    if parts.count == 2, parts[1].range(of: #"^\d{1,5}[A-Z]?$"#, options: .regularExpression) != nil {
      return unit
    }
    // "Suite 4 B": the letter joins the number, as the list-marker pass writes it.
    if parts.count == 3, parts[1].allSatisfy(\.isNumber), parts[2].count == 1,
      parts[2].first?.isUppercase == true
    {
      return parts[0] + " " + parts[1] + parts[2]
    }
    var numberWords = Array(parts.dropFirst())
    var letter = ""
    if let last = numberWords.last, last.count == 1, last.first?.isUppercase == true,
      numberWords.count > 1
    {
      letter = last
      numberWords.removeLast()
    }
    guard let n = addressNumber(numberWords.joined(separator: " ")) else { return nil }
    return parts[0] + " " + n + letter
  }
}
