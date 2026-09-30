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
