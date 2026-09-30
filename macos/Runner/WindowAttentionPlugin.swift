import Cocoa
import FlutterMacOS

/// Platform channel plugin that requests the user's attention without stealing
/// focus, for CXP cross-probe requests.
///
/// The shared `crux_window_chrome` package's `MethodChannelWindowAttentionRequester`
/// invokes `requestUserAttention` on this channel when an actionable inbound
/// cross-probe lands. On macOS that maps to `NSApp.requestUserAttention`, which
/// bounces the dock icon — a courteous nudge that never raises or foregrounds
/// the window (decision 1 of the increment).
///
/// Channel name: `crux_window_chrome/attention`
/// Methods:
///   - `requestUserAttention({kind: "informational" | "critical"})` → null
///     `informational` → `.informationalRequest` (one bounce);
///     `critical` → `.criticalRequest` (bounces until focused).
class WindowAttentionPlugin {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "crux_window_chrome/attention",
      binaryMessenger: messenger)
    channel.setMethodCallHandler(handle)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestUserAttention":
      let args = call.arguments as? [String: Any]
      let kind = args?["kind"] as? String
      let requestType: NSApplication.RequestUserAttentionType =
        (kind == "critical") ? .criticalRequest : .informationalRequest
      NSApp.requestUserAttention(requestType)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
