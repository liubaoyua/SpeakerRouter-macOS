import AppKit
import SwiftUI

// Own the complete window surface so no system menu material or insets surround
// the panel. The hosting controller reports size changes when its content changes.
@MainActor
final class RouterPanelWindow: NSPanel {
  private let hostingController: NSHostingController<AnyView>
  private var sizeObservation: NSKeyValueObservation?
  var anchor: (() -> (button: NSRect, screen: NSRect)?)?

  init<Content: View>(content: Content) {
    hostingController = NSHostingController(rootView: AnyView(content))
    super.init(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    title = "SpeakerRouter"
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    hidesOnDeactivate = false
    level = .popUpMenu
    collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    animationBehavior = .none
    hostingController.safeAreaRegions = []
    hostingController.sizingOptions = [.preferredContentSize]

    let container = NSView()
    let hostingView = hostingController.view
    hostingView.autoresizingMask = [.width, .height]
    container.addSubview(hostingView)
    contentView = container

    sizeObservation = hostingController.observe(\.preferredContentSize, options: [.new]) {
      [weak self] _, change in
      guard let size = change.newValue else { return }
      Task { @MainActor [weak self] in self?.fitContent(size) }
    }
    fitContent(hostingController.sizeThatFits(in: NSSize(width: 408, height: 10_000)))
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  func show() {
    fitContent(hostingController.sizeThatFits(in: NSSize(width: 408, height: 10_000)))
    makeKeyAndOrderFront(nil)
  }

  private func fitContent(_ size: NSSize) {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
      return
    }
    let size = NSSize(width: ceil(size.width), height: ceil(size.height))
    var frame = NSRect(origin: NSPoint(x: self.frame.minX, y: self.frame.maxY - size.height), size: size)
    if let (button, screen) = anchor?() {
      frame.origin.x = min(max(button.midX - size.width / 2, screen.minX + 6), screen.maxX - size.width - 6)
      frame.origin.y = max(screen.minY + 6, button.minY - 6 - size.height)
    }
    setFrame(frame, display: isVisible)
    hostingController.view.frame = contentView?.bounds ?? .zero
    invalidateShadow()
  }

  override func cancelOperation(_ sender: Any?) {
    orderOut(nil)
  }
}
