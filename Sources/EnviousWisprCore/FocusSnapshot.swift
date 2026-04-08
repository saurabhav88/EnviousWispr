/// Captures the user's focus context at recording time for context-aware polish.
/// Populated by AX context capture in PR 3. Defined now so types are stable.
public struct FocusSnapshot: Sendable {
    public let appName: String
    public let windowTitle: String?
    public let fieldRole: String?
    public let selectedText: String?
    public let beforeCursor: String?

    public init(
        appName: String,
        windowTitle: String? = nil,
        fieldRole: String? = nil,
        selectedText: String? = nil,
        beforeCursor: String? = nil
    ) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.fieldRole = fieldRole
        self.selectedText = selectedText
        self.beforeCursor = beforeCursor
    }
}
