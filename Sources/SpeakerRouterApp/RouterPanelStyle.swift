import AppKit
import SwiftUI

struct RouterPanelStyle {
  var panel: Color { color(0xf7f9fe) }
  var ink: Color { color(0x252e3f) }
  var muted: Color { color(0x5b687d) }
  var accent: Color { color(0x225ed2) }
  var tint: Color { color(0xe7effe) }
  var line: Color { color(0xdce4f0) }
  var success: Color { color(0x167457) }
  var heroTile: Color { Color.white.opacity(0.60) }
  var heroBorder: Color { color(0xc1d5fc) }
  var heroStart: Color { color(0xeef5ff) }
  var heroEnd: Color { color(0xcfdeff) }
  var heroGlow: Color { color(0xa3c4ff) }
  var musicInk: Color { color(0x9f3554) }
  var musicTint: Color { color(0xf9e4ea) }
  var browserInk: Color { color(0x176655) }
  var browserTint: Color { color(0xe0edea) }

  var sliderFill: NSColor { nsColor(0x225ed2) }
  var sliderRim: NSColor { nsColor(0xffffff) }

  func sliderTrack(hero: Bool) -> NSColor {
    hero ? nsColor(0xafc7ee) : nsColor(0xdce4f0)
  }

  private func color(_ rgb: UInt32) -> Color {
    Color(nsColor: nsColor(rgb))
  }

  private func nsColor(_ rgb: UInt32) -> NSColor {
    return NSColor(
      srgbRed: CGFloat((rgb >> 16) & 255) / 255,
      green: CGFloat((rgb >> 8) & 255) / 255,
      blue: CGFloat(rgb & 255) / 255,
      alpha: 1
    )
  }
}
