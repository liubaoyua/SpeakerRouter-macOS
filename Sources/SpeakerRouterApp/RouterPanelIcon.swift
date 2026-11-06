import AppKit
import SwiftUI

// Outline artwork from Lucide 1.17.0. See ThirdParty/lucide/LICENSE.
enum RouterPanelIcon: CaseIterable {
  case audioLines
  case headphones
  case monitor
  case laptop
  case speaker
  case volume
  case refresh
  case check
  case music
  case compass
  case reset
  case bolt
  case settings
  case back
  case lock
  case muted

  private static let images = Dictionary(uniqueKeysWithValues: allCases.compactMap { icon in
    guard let paths = icon.paths else { return nil as (Self, NSImage)? }
    let svg = """
      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"
        fill="none" stroke="black" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
        \(paths)
      </svg>
      """
    guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
    image.isTemplate = true
    return (icon, image)
  })

  func view(size: CGFloat) -> some View {
    Group {
      if let image = Self.images[self] {
        Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
      } else {
        Image(systemName: fallback).resizable().scaledToFit()
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  private var paths: String? {
    switch self {
    case .audioLines:
      """
      <path d="M2 10v3" />
      <path d="M6 6v11" />
      <path d="M10 3v18" />
      <path d="M14 8v7" />
      <path d="M18 5v13" />
      <path d="M22 10v3" />
      """
    case .headphones:
      """
      <path d="M3 14h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a9 9 0 0 1 18 0v7a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3" />
      """
    case .monitor:
      """
      <rect width="20" height="14" x="2" y="3" rx="2" />
      <line x1="8" x2="16" y1="21" y2="21" />
      <line x1="12" x2="12" y1="17" y2="21" />
      """
    case .laptop:
      """
      <path d="M18 5a2 2 0 0 1 2 2v8.526a2 2 0 0 0 .212.897l1.068 2.127a1 1 0 0 1-.9 1.45H3.62a1 1 0 0 1-.9-1.45l1.068-2.127A2 2 0 0 0 4 15.526V7a2 2 0 0 1 2-2z" />
      <path d="M20.054 15.987H3.946" />
      """
    case .speaker:
      """
      <rect width="16" height="20" x="4" y="2" rx="2" />
      <path d="M12 6h.01" />
      <circle cx="12" cy="14" r="4" />
      <path d="M12 14h.01" />
      """
    case .volume:
      """
      <path d="M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z" />
      <path d="M16 9a5 5 0 0 1 0 6" />
      <path d="M19.364 18.364a9 9 0 0 0 0-12.728" />
      """
    case .refresh:
      """
      <path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8" />
      <path d="M21 3v5h-5" />
      <path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16" />
      <path d="M8 16H3v5" />
      """
    case .check:
      """
      <path d="M20 6 9 17l-5-5" />
      """
    case .music:
      """
      <path d="M9 18V5l12-2v13" />
      <circle cx="6" cy="18" r="3" />
      <circle cx="18" cy="16" r="3" />
      """
    case .compass:
      """
      <circle cx="12" cy="12" r="10" />
      <path d="m16.24 7.76-1.804 5.411a2 2 0 0 1-1.265 1.265L7.76 16.24l1.804-5.411a2 2 0 0 1 1.265-1.265z" />
      """
    case .reset:
      """
      <path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" />
      <path d="M3 3v5h5" />
      """
    case .bolt:
      """
      <path d="M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z" />
      """
    case .settings:
      """
      <path d="M14 17H5" />
      <path d="M19 7h-9" />
      <circle cx="17" cy="17" r="3" />
      <circle cx="7" cy="7" r="3" />
      """
    case .back:
      """
      <path d="m15 18-6-6 6-6" />
      """
    case .lock:
      nil
    case .muted:
      nil
    }
  }

  private var fallback: String {
    switch self {
    case .audioLines: "waveform"
    case .headphones: "headphones"
    case .monitor: "display"
    case .laptop: "laptopcomputer"
    case .speaker: "hifispeaker"
    case .volume: "speaker.wave.2"
    case .refresh: "arrow.clockwise"
    case .check: "checkmark"
    case .music: "music.note"
    case .compass: "safari"
    case .reset: "arrow.counterclockwise"
    case .bolt: "bolt"
    case .settings: "slider.horizontal.3"
    case .back: "chevron.left"
    case .lock: "lock"
    case .muted: "speaker.slash"
    }
  }
}
