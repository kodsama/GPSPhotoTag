import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Sensible default window size for the walkthrough layout.
    let defaultSize = NSSize(width: 900, height: 760)
    self.setContentSize(defaultSize)
    self.minSize = NSSize(width: 640, height: 560)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
