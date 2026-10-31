import AppKit
import SwiftUI

/// Makes the hosting window a fixed utility window: no fullscreen, no zoom.
/// SwiftUI has no scene-level switch for this on macOS 15, so this small AppKit island sets it
/// once the view is in a window.
struct FixedWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowProbe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowProbe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
    }
}
