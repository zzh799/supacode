import AppKit
import ComposableArchitecture
import Foundation
// UserNotifications types (UNNotification, UNNotificationResponse, …) are not
// Sendable in the macOS 15 SDK, but the framework dispatches them onto the main
// actor synchronously. @preconcurrency opts those types out of Swift 6 strict
// sendability so the delegate conformance compiles cleanly.
@preconcurrency import UserNotifications

/// Payload key under which the system notification stores the deeplink URL
/// that should be dispatched when the user taps the notification banner.
private nonisolated let deeplinkUserInfoKey = "supacode.deeplink"

private nonisolated let systemNotificationLogger = SupaLogger("SystemNotifications")

@MainActor
private final class ForegroundSystemNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  var onDeeplinkTap: ((URL) -> Void)?

  // UNUserNotificationCenterDelegate's requirements are nonisolated, so
  // conforming from a @MainActor class would require sending non-Sendable
  // UNNotification/UNUserNotificationCenter values across isolation domains.
  // UserNotifications always dispatches these callbacks on the main thread, so
  // we implement them nonisolated and hop back to the main actor with
  // MainActor.run only for the small bit that touches actor state.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    await Task.yield()
    return [.badge, .sound, .banner]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    await Task.yield()
    let userInfo = response.notification.request.content.userInfo
    guard let raw = userInfo[deeplinkUserInfoKey] as? String else { return }
    guard let url = URL(string: raw) else {
      systemNotificationLogger.warning("Dropped notification tap: userInfo deeplink is not a valid URL: \(raw)")
      return
    }
    await MainActor.run {
      self.onDeeplinkTap?(url)
    }
  }
}

@MainActor
private let foregroundSystemNotificationDelegate = ForegroundSystemNotificationDelegate()

@MainActor
private func configuredNotificationCenter() -> UNUserNotificationCenter {
  let center = UNUserNotificationCenter.current()
  if center.delegate !== foregroundSystemNotificationDelegate {
    center.delegate = foregroundSystemNotificationDelegate
  }
  return center
}

/// Registers a handler invoked on the main actor whenever the user taps a
/// delivered system notification that carries a supacode deeplink.
@MainActor
public func setSystemNotificationTapHandler(_ handler: @escaping @MainActor (URL) -> Void) {
  _ = configuredNotificationCenter()
  foregroundSystemNotificationDelegate.onDeeplinkTap = handler
}

public nonisolated struct SystemNotificationClient: Sendable {
  public struct AuthorizationRequestResult: Equatable, Sendable {
    public let granted: Bool
    public let errorMessage: String?

    public init(granted: Bool, errorMessage: String?) {
      self.granted = granted
      self.errorMessage = errorMessage
    }
  }

  public enum AuthorizationStatus: Equatable, Sendable {
    case authorized
    case denied
    case notDetermined
  }

  public var authorizationStatus: @MainActor @Sendable () async -> AuthorizationStatus
  public var requestAuthorization: @MainActor @Sendable () async -> AuthorizationRequestResult
  public var send: @MainActor @Sendable (_ title: String, _ body: String, _ deeplinkURL: URL?) async -> Void
  public var openSettings: @MainActor @Sendable () async -> Void

  public init(
    authorizationStatus: @escaping @MainActor @Sendable () async -> AuthorizationStatus,
    requestAuthorization: @escaping @MainActor @Sendable () async -> AuthorizationRequestResult,
    send: @escaping @MainActor @Sendable (_ title: String, _ body: String, _ deeplinkURL: URL?) async -> Void,
    openSettings: @escaping @MainActor @Sendable () async -> Void
  ) {
    self.authorizationStatus = authorizationStatus
    self.requestAuthorization = requestAuthorization
    self.send = send
    self.openSettings = openSettings
  }
}

extension SystemNotificationClient: DependencyKey {
  public static let liveValue = SystemNotificationClient(
    authorizationStatus: {
      let center = configuredNotificationCenter()
      let settings = await center.notificationSettings()
      switch settings.authorizationStatus {
      case .authorized, .provisional:
        return .authorized
      case .denied:
        return .denied
      case .notDetermined:
        return .notDetermined
      @unknown default:
        return .denied
      }
    },
    requestAuthorization: {
      let center = configuredNotificationCenter()
      do {
        let granted = try await center.requestAuthorization(
          options: [.alert, .badge, .sound]
        )
        return AuthorizationRequestResult(granted: granted, errorMessage: nil)
      } catch {
        return AuthorizationRequestResult(
          granted: false,
          errorMessage: error.localizedDescription
        )
      }
    },
    send: { title, body, deeplinkURL in
      let center = configuredNotificationCenter()
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      if let deeplinkURL {
        content.userInfo = [deeplinkUserInfoKey: deeplinkURL.absoluteString]
      }
      let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
      )
      try? await center.add(request)
    },
    openSettings: {
      guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
        return
      }
      _ = NSWorkspace.shared.open(url)
    }
  )

  public static let testValue = SystemNotificationClient(
    authorizationStatus: { .notDetermined },
    requestAuthorization: { AuthorizationRequestResult(granted: false, errorMessage: nil) },
    send: { _, _, _ in },
    openSettings: {}
  )
}

extension DependencyValues {
  public var systemNotificationClient: SystemNotificationClient {
    get { self[SystemNotificationClient.self] }
    set { self[SystemNotificationClient.self] = newValue }
  }
}
