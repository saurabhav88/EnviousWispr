import EnviousWisprCore
import EnviousWisprModelDelivery

extension ModelIdentity {
  /// #3546 §3.7 T1: the telemetry form of a speech model's delivery identity.
  /// AppKit converts here because ASR and Pipeline adapters cannot read
  /// delivery manifests themselves.
  var asrModelIdentity: ASRModelIdentity {
    ASRModelIdentity(name: name, revision: revision, variant: variant)
  }
}
