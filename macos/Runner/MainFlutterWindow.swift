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
    // on every move and resize, and restores it here; a first launch keeps
    // the XIB's 800x600. Without it every launch opened at 800x600.
    _ = self.setFrameUsingName("MainWindow")
    self.setFrameAutosaveName("MainWindow")

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
}
