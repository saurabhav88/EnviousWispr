enum InputDevicePreferencePolicy {
  static func reconciled(
    preferredOverride: String,
    selectedUID: String,
    connectedUIDs: Set<String>
  ) -> (preferredOverride: String, selectedUID: String) {
    if !preferredOverride.isEmpty {
      if connectedUIDs.contains(preferredOverride) {
        return (preferredOverride, preferredOverride)
      }
      return ("", preferredOverride)
    }

    if !selectedUID.isEmpty, connectedUIDs.contains(selectedUID) {
      return (selectedUID, selectedUID)
    }

    return ("", selectedUID)
  }
}
