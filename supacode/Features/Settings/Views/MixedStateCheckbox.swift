import AppKit
import SwiftUI

// Three-state checkbox backed by NSButton for mixed-state support.
enum CheckboxState: Equatable {
  case checked
  case unchecked
  case mixed
}

struct MixedStateCheckbox: NSViewRepresentable {
  let state: CheckboxState
  let onToggle: (Bool) -> Void

  // `NSViewRepresentable` is a `@MainActor` protocol in the macOS 15 SDK, so
  // these witnesses are implicitly main-actor isolated and can touch `NSButton`
  // and `Coordinator` directly without `assumeIsolated`.
  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(
      checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.toggled(_:)))
    button.allowsMixedState = true
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentHuggingPriority(.required, for: .vertical)
    applyState(to: button)
    return button
  }

  func updateNSView(_ button: NSButton, context: Context) {
    applyState(to: button)
    context.coordinator.onToggle = onToggle
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(onToggle: onToggle)
  }

  private func applyState(to button: NSButton) {
    switch state {
    case .checked: button.state = .on
    case .unchecked: button.state = .off
    case .mixed: button.state = .mixed
    }
  }

  @MainActor
  final class Coordinator: NSObject {
    var onToggle: (Bool) -> Void

    init(onToggle: @escaping (Bool) -> Void) {
      self.onToggle = onToggle
    }

    @objc func toggled(_ sender: NSButton) {
      // NSButton actions arrive on the main thread, and `Coordinator` is
      // `@MainActor`, so `sender`/`onToggle` are both main-actor isolated —
      // no `assumeIsolated` hop (and no `@Sendable` capture of `self`) needed.
      // Clicking mixed or off → on; clicking on → off.
      let newEnabled = sender.state != .off
      onToggle(newEnabled)
    }
  }
}
