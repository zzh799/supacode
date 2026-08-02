import AppKit
import SwiftUI

// SwiftUI's window scenes never set `collectionBehavior`, so a reopened
// Settings window snaps back to the Space it was last shown on. Pin it to the
// active Space and let it float over a full-screen main window.
struct SettingsWindowSpaceBehavior: NSViewRepresentable {
  func makeNSView(context: Context) -> SettingsWindowSpaceBehaviorNSView {
    SettingsWindowSpaceBehaviorNSView()
  }

  func updateNSView(_ nsView: SettingsWindowSpaceBehaviorNSView, context: Context) {}
}

@MainActor
final class SettingsWindowSpaceBehaviorNSView: NSView {
  private var keyObserver: NSObjectProtocol?

  deinit {
    MainActor.assumeIsolated {
      guard let keyObserver else { return }
      NotificationCenter.default.removeObserver(keyObserver)
      self.keyObserver = nil
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    clearObserver()
    guard let window else { return }
    // Tag the window so callers can tell the settings window is already open.
    // The settings scene is a WindowGroup, and openWindow(id:) spawns a fresh
    // instance every call, so detection has to go through the window itself.
    window.identifier = NSUserInterfaceItemIdentifier(WindowID.settings)
    // Re-assert on key so a SwiftUI reconfigure can't clobber the behavior.
    keyObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.apply() }
    }
    apply()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  private func apply() {
    guard let window else { return }
    // Re-assert the identifier here too so a SwiftUI reconfigure that replaces
    // the window can't silently drop it.
    window.identifier = NSUserInterfaceItemIdentifier(WindowID.settings)
    var behavior = window.collectionBehavior
    behavior.remove(.canJoinAllSpaces)
    behavior.remove(.fullScreenPrimary)
    behavior.insert(.moveToActiveSpace)
    behavior.insert(.fullScreenAuxiliary)
    window.collectionBehavior = behavior
  }

  private func clearObserver() {
    guard let keyObserver else { return }
    NotificationCenter.default.removeObserver(keyObserver)
    self.keyObserver = nil
  }
}

extension View {
  /// Keeps the Settings window on the active Space instead of switching back to the Space it was last shown on.
  func movesSettingsWindowToActiveSpace() -> some View {
    background(SettingsWindowSpaceBehavior())
  }
}
