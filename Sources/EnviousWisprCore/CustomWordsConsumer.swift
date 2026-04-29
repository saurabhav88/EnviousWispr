import Foundation

/// Services that hold a synchronized copy of the active custom-words list.
///
/// `CustomWordsPropagator` (in the App target) writes new lists to all registered
/// consumers via this property. Consumers MUST NOT call `propagator.update(_:)`
/// synchronously from inside this setter; doing so triggers a DEBUG `precondition`.
@MainActor
package protocol CustomWordsConsumer: AnyObject {
  var customWords: [CustomWord] { get set }
}
