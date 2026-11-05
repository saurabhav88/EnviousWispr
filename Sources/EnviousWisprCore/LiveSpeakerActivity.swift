import Foundation

/// Who was talking in one stretch of written call-track audio, as the live speaker model saw it
/// (#4355 PR C). `activeSlots` lists every model slot whose probability passed the threshold:
/// empty means no speaker speech, two or more means overlap. A slot is a number inside one
/// `epoch`, NOT a person: the model orders slots by arrival and can misattribute or reuse one
/// without any signal, so consumers attribute conservatively and re-derive names from current
/// evidence rather than treating `(epoch, slot)` as a permanent identity.
package struct LiveSpeakerActivity: Sendable, Equatable {
  package let epoch: Int
  package let span: MeetingAudioSpan
  package let activeSlots: [Int]

  package init(epoch: Int, span: MeetingAudioSpan, activeSlots: [Int]) {
    self.epoch = epoch
    self.span = span
    self.activeSlots = activeSlots
  }
}
