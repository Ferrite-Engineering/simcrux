import Cocoa
import FlutterMacOS

/// Platform channel plugin for a directed cross-probe's foreground hand-off.
///
/// The shared `crux_window_chrome` package's `MethodChannelWindowForegroundHandoff`
/// invokes it. The user clicked Cross-probe to one named app in this one, the
/// active app, so this app yields activation to the target; the target, when
/// the request arrives with the hand-off, activates and brings its window to
/// the front. Since macOS 14 an app comes forward only when the active app
/// yields to it, so without the yield the target could only bounce its Dock
/// icon. A broadcast never reaches this plugin: the shared CXP runtime hands
/// over only on a request sent to one peer.
///
/// Channel name: `crux_window_chrome/foreground`
/// Methods:
///   - `yieldForeground({pid: int})` → `String?`
///     yields activation to the running application with that process
///     identifier (`NSApp.yieldActivation(to:)` on macOS 14 and later; earlier
///     releases need no yield) and answers `""`, or null when no such
///     application runs.
///   - `takeForeground({token: String})` → `Bool`
///     activates the app and orders this window front, then answers true. If
///     macOS declines the activation, the Dock icon bounces, so the user is
///     never left with nothing.
///   - anything else → `FlutterMethodNotImplemented`
class WindowForegroundPlugin {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    self.window = window
    channel = FlutterMethodChannel(
      name: "crux_window_chrome/foreground",
      binaryMessenger: messenger)
    channel.setMethodCallHandler(handle)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "yieldForeground":
      let args = call.arguments as? [String: Any]
      guard let pid = (args?["pid"] as? NSNumber)?.int32Value, pid > 0 else {
        result(nil)
        return
      }
      result(yieldForeground(to: pid_t(pid)))
    case "takeForeground":
      result(takeForeground())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func yieldForeground(to pid: pid_t) -> String? {
    guard let target = NSRunningApplication(processIdentifier: pid) else {
      return nil
    }
    if #available(macOS 14.0, *) {
      NSApp.yieldActivation(to: target)
    }
    return ""
  }

  private func takeForeground() -> Bool {
    if let window = window, window.isMiniaturized {
      window.deminiaturize(nil)
    }
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
    window?.makeKeyAndOrderFront(nil)
    // Activation on macOS 14 is cooperative and may be declined (the user
    // clicked elsewhere first). Then ask for attention instead.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      if !NSApp.isActive {
        NSApp.requestUserAttention(.informationalRequest)
      }
    }
    return true
  }
}
