import AppKit
import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

// MARK: - Settings window presentation.

/// Surfaces the already-open settings window, or opens it when none exists.
///
/// The settings scene is a `WindowGroup`, so `openWindow(id:)` spawns a fresh
/// window instance on every call. Re-invoking it while a window is already
/// open — e.g. switching sidebar pages, or re-triggering the selection bridge
/// — would pile up duplicate settings windows, so every call site goes through
/// this instead of calling `openWindow` directly.
@MainActor
private enum SettingsWindowPresenter {
  static func present(openWindow: OpenWindowAction) {
    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == WindowID.settings }) {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
      NSApp.activate()
    } else {
      openWindow(id: WindowID.settings)
    }
  }
}

// MARK: - Selection → settings window bridge.

/// Observes `store.settings.selection` and opens the dedicated settings window when it becomes non-nil.
/// Applied to the main window content so the environment action is always available.
private struct OpenSettingsOnSelection: ViewModifier {
  @Environment(\.openWindow) private var openWindow
  let store: StoreOf<AppFeature>

  func body(content: Content) -> some View {
    content
      .onChange(of: store.settings.selection) { _, new in
        guard new != nil else { return }
        // Do not gate on `old == nil`: the modifier's reference value can be
        // stale (the main window doesn't re-render for selection changes), so
        // a sidebar click inside the open window can look like a nil → non-nil
        // transition. The window-existence check below is authoritative.
        SettingsWindowPresenter.present(openWindow: openWindow)
      }
  }
}

extension View {
  func openSettingsOnSelection(store: StoreOf<AppFeature>) -> some View {
    modifier(OpenSettingsOnSelection(store: store))
  }
}

// MARK: - Menu button.

/// Settings menu button that opens the dedicated settings window and supports custom keyboard shortcuts.
struct SettingsMenuButton: View {
  @Environment(\.openWindow) private var openWindow
  let shortcutOverrides: [AppShortcutID: AppShortcutOverride]
  let onOpen: () -> Void

  var body: some View {
    let settings = AppShortcuts.openSettings.effective(from: shortcutOverrides)
    Button("Settings...", systemImage: "gear") {
      onOpen()
      SettingsWindowPresenter.present(openWindow: openWindow)
    }
    .appKeyboardShortcut(settings)
  }
}
