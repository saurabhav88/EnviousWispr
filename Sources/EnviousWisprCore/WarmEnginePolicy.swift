/// How long to keep the audio engine warm after recording stops.
///
/// A warm engine enables instant pre-roll capture on the next recording,
/// eliminating first-word clipping. The tradeoff is power usage while warm.
public enum WarmEnginePolicy: String, CaseIterable, Sendable {
    case off
    case seconds10
    case seconds30
    case seconds60
    case always
}
