import AppKit
import Carbon
import EnviousWisprServices
import Foundation

/// The Carbon and `NSEvent` calls that actually reach the desktop (#2455 C2).
///
/// **This module exists to be out of the unit suite's reach — enforced by a
/// CHECK, not by the compiler.** `EnviousWisprTests` declares no dependency on
/// this target, and only `EnviousWisprAppLive` builds one of these.
///
/// Be precise about what enforces that, because the obvious belief is wrong.
/// Measured 2026-08-26: a file in `Tests/EnviousWisprTests/` that imports this
/// module and constructs this type COMPILES AND LINKS under Xcode, with no
/// dependency edge declared anywhere. Xcode puts every built product in one
/// search path, so a declared edge orders the LINK and does not gate imports.
/// SwiftPM would reject it; CI runs Tuist and xcodebuild only, so SwiftPM never
/// gets the chance.
///
/// `scripts/check-dependency-direction.sh` is therefore the wall: it scans the
/// test targets and rejects this module by name. Delete that loop and the
/// boundary silently becomes a convention.
///
/// Every causal comment here moved with the behavior it explains, per the C2
/// contract. Where the reason was recorded against the old call site in
/// `HotkeyService`, it is recorded against the new one.
@MainActor
package final class LiveDesktopHotkeyEffects: DesktopHotkeyEffects {

  /// What a token actually identifies.
  ///
  /// Kept in a private table rather than handed out, because every payload here
  /// is an opaque handle whose only legal consumer is the framework that issued
  /// it. `remove(_:)` is the single release path, which is what makes double
  /// teardown a no-op instead of a double free.
  private enum Resource {
    case hotkey(EventHotKeyRef)
    case handler(EventHandlerRef, Unmanaged<CarbonHandlerBox>)
    case monitor(Any)
  }

  private var resources: [DesktopEffectToken: Resource] = [:]

  package init() {}

  // MARK: - Carbon handler

  package func installCarbonHandler(
    _ callback: @escaping @MainActor (DesktopHotkeyEvent) -> Void
  ) -> DesktopEffectToken? {
    var eventTypes = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyReleased)),
    ]

    // The user-data pointer addresses a box this adapter owns, NOT the policy
    // object. Before C2 it was an unretained `HotkeyService`, resolved on every
    // OS callback — correct only for as long as the service outlives the
    // handler, which nothing enforced. A retained box has a lifetime this class
    // controls, released in `remove(_:)` and only after `RemoveEventHandler`.
    let box = Unmanaged.passRetained(CarbonHandlerBox(callback))

    // Resolved HERE, not at construction: the application event target is a
    // process resource, and taking it in `init` would make merely building this
    // adapter touch the OS.
    var ref: EventHandlerRef?
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      liveCarbonHotkeyHandler,
      eventTypes.count,
      &eventTypes,
      box.toOpaque(),
      &ref
    )

    guard status == noErr, let ref else {
      if let ref {
        // Keep the retained box ALIVE if Carbon will not confirm detachment: it
        // may still hold the pointer, and releasing here would leave it reading
        // freed memory on the next hotkey. Leaking one closure is the strictly
        // safer failure.
        guard RemoveEventHandler(ref) == noErr else { return nil }
      }
      // No handler was installed, or it was cleanly detached — the box is
      // unreachable now, so release it or the closure leaks for the process life.
      box.release()
      return nil
    }

    let token = DesktopEffectToken()
    resources[token] = .handler(ref, box)
    return token
  }

  // MARK: - Registration

  package func registerHotkey(
    id: UInt32, keyCode: UInt16, rawModifiers: UInt64
  ) -> HotkeyRegistration {
    let hotkeyID = EventHotKeyID(signature: Self.hotkeySignature, id: id)
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(keyCode),
      UInt32(truncatingIfNeeded: rawModifiers),
      hotkeyID,
      GetApplicationEventTarget(),
      0,
      &ref
    )

    guard status == noErr else { return .refused(status: Int32(status)) }
    // #1175: the noErr-but-silent trap. Carbon can accept the registration and
    // still leave the ref nil, which is a shortcut that is registered, displayed,
    // and delivers nothing. It is NOT a failure — reporting one here would put a
    // false alarm in the signal that tells us a real user's shortcut died — and
    // it is not a success either, so it gets its own case.
    guard let ref else { return .acceptedWithoutToken }

    let token = DesktopEffectToken()
    resources[token] = .hotkey(ref)
    return .registered(token)
  }

  /// Four-char-code signature for EnviousWispr hotkeys.
  ///
  /// Moved verbatim from `HotkeyService`; it is meaningless apart from
  /// `registerHotkey`. The case is load-bearing — these are raw bytes packed into
  /// an `OSType`, so "EWSP" and "ewsp" are different signatures and a stale
  /// registration carrying the other one would not be recognised.
  private static let hotkeySignature: OSType = {
    var result: OSType = 0
    for char in "EWSP".utf8.prefix(4) {
      result = (result << 8) | OSType(char)
    }
    return result
  }()

  // MARK: - Modifier monitors

  package func installGlobalModifierMonitor(
    _ callback: @escaping @MainActor (DesktopModifierEvent) -> Void
  ) -> DesktopEffectToken? {
    // Global monitor callbacks may arrive off the main thread, and `NSEvent` is
    // not Sendable — so the event is decoded to plain values HERE and only those
    // cross the hop.
    let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
      let value = DesktopModifierEvent(
        keyCode: event.keyCode, rawFlags: UInt64(event.modifierFlags.rawValue))
      DispatchQueue.main.async {
        MainActor.assumeIsolated { callback(value) }
      }
    }
    return store(monitor)
  }

  package func installLocalModifierMonitor(
    _ callback: @escaping @MainActor (DesktopModifierEvent) -> Void
  ) -> DesktopEffectToken? {
    let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
      MainActor.assumeIsolated {
        callback(
          DesktopModifierEvent(
            keyCode: event.keyCode, rawFlags: UInt64(event.modifierFlags.rawValue)))
      }
      // Pass the event through. Returning nil here would swallow the keystroke
      // for the rest of the app while the callback still fired, so nothing in a
      // test would notice.
      return event
    }
    return store(monitor)
  }

  private func store(_ monitor: Any?) -> DesktopEffectToken? {
    guard let monitor else { return nil }
    let token = DesktopEffectToken()
    resources[token] = .monitor(monitor)
    return token
  }

  // MARK: - Teardown

  @discardableResult
  package func remove(_ token: DesktopEffectToken) -> Bool {
    // Removing first makes an unknown or already-released token a no-op rather
    // than a second framework call on a dead handle.
    guard let resource = resources.removeValue(forKey: token) else { return true }
    switch resource {
    case .hotkey(let ref):
      UnregisterEventHotKey(ref)
    case .handler(let ref, let box):
      // Order matters: the handler must be detached before the box it points at
      // is released, or an in-flight callback resolves freed memory. If Carbon
      // refuses, put the mapping BACK and report failure — the caller keeps its
      // token and can retry. Dropping it here would strand the handler with
      // nothing left able to name it.
      guard RemoveEventHandler(ref) == noErr else {
        resources[token] = .handler(ref, box)
        return false
      }
      box.release()
    case .monitor(let monitor):
      NSEvent.removeMonitor(monitor)
    }
    return true
  }
}

/// What the Carbon user-data pointer actually addresses.
@MainActor
private final class CarbonHandlerBox {
  let callback: @MainActor (DesktopHotkeyEvent) -> Void
  init(_ callback: @escaping @MainActor (DesktopHotkeyEvent) -> Void) {
    self.callback = callback
  }
}

/// The C trampoline. Decodes the event and hands plain values to the box.
///
/// `GetEventKind` and `GetEventParameter` are Carbon calls but install nothing —
/// they read an event already delivered — so they are not desktop effects and
/// have no gate.
private func liveCarbonHotkeyHandler(
  _: EventHandlerCallRef?,
  _ event: EventRef?,
  _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event, let userData else { return OSStatus(eventNotHandledErr) }

  var hotkeyID = EventHotKeyID()
  let status = GetEventParameter(
    event,
    UInt32(kEventParamDirectObject),
    UInt32(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotkeyID
  )
  guard status == noErr else { return OSStatus(eventNotHandledErr) }

  let value = DesktopHotkeyEvent(
    id: hotkeyID.id,
    isRelease: GetEventKind(event) == UInt32(kEventHotKeyReleased))

  let box = Unmanaged<CarbonHandlerBox>.fromOpaque(userData).takeUnretainedValue()
  MainActor.assumeIsolated { box.callback(value) }
  return noErr
}
