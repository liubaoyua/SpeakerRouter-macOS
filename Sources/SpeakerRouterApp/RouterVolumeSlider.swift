import AppKit
import SwiftUI

// An NSSlider keeps mouse, keyboard, and accessibility handling while its cell
// draws the track and thumb to match the rest of the panel.
struct RouterVolumeSlider: NSViewRepresentable {
  @Binding var value: Double
  let maximum: Double
  let label: String
  let percent: Int
  let style: RouterPanelStyle
  var inHero = false

  @Environment(\.isEnabled) private var isEnabled

  func makeCoordinator() -> Coordinator {
    Coordinator(value: $value)
  }

  func makeNSView(context: Context) -> NSSlider {
    let slider = NSSlider()
    let cell = VolumeCell()
    cell.controlSize = .small
    slider.cell = cell
    slider.minValue = 0
    slider.maxValue = maximum
    slider.isContinuous = true
    slider.target = context.coordinator
    slider.action = #selector(Coordinator.change(_:))
    return slider
  }

  func updateNSView(_ slider: NSSlider, context: Context) {
    context.coordinator.value = $value
    slider.doubleValue = value
    slider.isEnabled = isEnabled
    slider.setAccessibilityLabel(label)
    slider.setAccessibilityValueDescription("\(percent)%")
    if let cell = slider.cell as? VolumeCell {
      cell.fill = style.sliderFill
      cell.track = style.sliderTrack(hero: inHero)
      cell.rim = style.sliderRim
    }
    slider.needsDisplay = true
  }

  @MainActor
  final class Coordinator: NSObject {
    var value: Binding<Double>

    init(value: Binding<Double>) {
      self.value = value
    }

    @objc func change(_ slider: NSSlider) {
      value.wrappedValue = slider.doubleValue
    }
  }

  private final class VolumeCell: NSSliderCell {
    var fill = NSColor.controlAccentColor
    var track = NSColor.separatorColor
    var rim = NSColor.white

    private func geometry(flipped: Bool) -> (bar: NSRect, thumbCenter: NSPoint) {
      let flipped = controlView?.isFlipped ?? flipped
      let nativeBar = barRect(flipped: flipped)
      let nativeKnob = knobRect(flipped: flipped)
      // The thumb's center travels between its half-width insets. Draw the
      // visible rail over that same range and use its centerline for both parts.
      let inset = min(nativeKnob.width / 2, nativeBar.width / 2)
      let bar = NSRect(
        x: nativeBar.minX + inset,
        y: nativeBar.midY - 2.5,
        width: nativeBar.width - 2 * inset,
        height: 5
      )
      let thumbCenter = NSPoint(
        x: min(max(nativeKnob.midX, bar.minX), bar.maxX),
        y: bar.midY
      )
      return (bar, thumbCenter)
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
      let (bar, thumbCenter) = geometry(flipped: flipped)
      let shape = NSBezierPath(roundedRect: bar, xRadius: 2.5, yRadius: 2.5)
      (isEnabled ? track : track.withAlphaComponent(0.65)).setFill()
      shape.fill()

      guard thumbCenter.x > bar.minX else { return }
      NSGraphicsContext.saveGraphicsState()
      shape.addClip()
      (isEnabled ? fill : fill.withAlphaComponent(0.40)).setFill()
      NSBezierPath(rect: NSRect(
        x: bar.minX, y: bar.minY, width: thumbCenter.x - bar.minX, height: bar.height
      ))
        .fill()
      NSGraphicsContext.restoreGraphicsState()
    }

    override func drawKnob(_ rect: NSRect) {
      let center = geometry(flipped: false).thumbCenter
      let knob = NSRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)
      NSGraphicsContext.saveGraphicsState()
      let shadow = NSShadow()
      shadow.shadowBlurRadius = 3
      shadow.shadowOffset = NSSize(width: 0, height: -1)
      shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
      shadow.set()
      rim.setFill()
      NSBezierPath(ovalIn: knob).fill()
      NSGraphicsContext.restoreGraphicsState()
      (isEnabled ? fill : fill.withAlphaComponent(0.40)).setFill()
      NSBezierPath(ovalIn: knob.insetBy(dx: 1.5, dy: 1.5)).fill()
    }
  }
}
