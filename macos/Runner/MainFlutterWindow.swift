import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var windowAttentionPlugin: WindowAttentionPlugin?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 800, height: 500)
    // Reopen where the user left it. AppKit saves the frame under this name
    // on every move and resize; a first launch keeps the XIB's 800x600.
    // The saved frame is applied with setFrame rather than left to AppKit's
    // restore, which fits it to the screen the window is on before it is
    // shown — always the main one — so a window left on a second monitor
    // reopened on the first.
    self.setFrameAutosaveName("MainWindow")
    if let saved = MainFlutterWindow.savedFrame(named: "MainWindow") {
      self.setFrame(saved, display: true)
    }

    RegisterGeneratedPlugins(registry: flutterViewController)
    // The native side of the portable CXP request-attention primitive (dock
    // bounce, never a focus steal).
    windowAttentionPlugin = WindowAttentionPlugin(
      messenger: flutterViewController.engine.binaryMessenger)
    // Registers the channels a Finder double-click delivers on. The singleton
    // buffers anything that arrived before now, which on a cold launch is the
    // document that caused the launch in the first place.
    IncomingFilePlugin.shared.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  /// The frame AppKit saved under [name], while it still overlaps a connected
  /// screen; nil otherwise (first launch, or that monitor is gone), which
  /// leaves AppKit's own placement.
  private static func savedFrame(named name: String) -> NSRect? {
    guard let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(name)")
    else { return nil }
    let values = saved.split(separator: " ").compactMap { Double($0) }
    guard values.count >= 4, values[2] > 0, values[3] > 0 else { return nil }
    let frame = NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
    guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) })
    else { return nil }
    return frame
  }
}
