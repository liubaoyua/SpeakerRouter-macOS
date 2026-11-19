import AppKit

@MainActor
final class RouterStatusItemController: NSObject, NSWindowDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let panel: RouterPanelWindow
  private var localMouseMonitor: Any?
  private var globalMouseMonitor: Any?

  init(model: RouterViewModel, icon: NSImage) {
    panel = RouterPanelWindow(content: RouterMenuView(model: model))
    super.init()

    guard let button = statusItem.button else { return }
    button.image = icon
    button.toolTip = "SpeakerRouter"
    button.setAccessibilityLabel("SpeakerRouter")
    button.target = self
    button.action = #selector(togglePanel)
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    panel.delegate = self
    panel.anchor = { [weak button] in
      guard let button, let window = button.window, let screen = window.screen else { return nil }
      let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
      return (rect, screen.visibleFrame)
    }

    localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] event in
      guard let self else { return event }
      if self.panel.isVisible,
        event.window !== self.panel,
        event.window !== self.statusItem.button?.window
      {
        self.closePanel()
      }
      return event
    }
    globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] _ in
      self?.closePanel()
    }
  }

  @objc private func togglePanel() {
    if panel.isVisible {
      closePanel()
    } else {
      panel.show()
      statusItem.button?.highlight(true)
    }
  }

  private func closePanel() {
    panel.orderOut(nil)
    statusItem.button?.highlight(false)
  }

  func windowDidResignKey(_ notification: Notification) {
    closePanel()
  }

  isolated deinit {
    if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
    if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    NSStatusBar.system.removeStatusItem(statusItem)
  }
}
