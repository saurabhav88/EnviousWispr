import Foundation

/// The three History tabs (#3147 §3.3). Raw values are persisted (`lastHistoryTab`) and used by
/// the DEBUG `history.list` tool, so they never change.
public enum HistoryTab: String, Codable, CaseIterable, Sendable {
  case dictations
  case transcripts
  case meetings
}
