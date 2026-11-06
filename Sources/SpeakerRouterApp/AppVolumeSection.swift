import SwiftUI

struct AppVolumeSection: View {
  @ObservedObject var controller: AppVolumeController
  let style: RouterPanelStyle

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("应用音量")
        .font(.system(size: 12, weight: .semibold))
        .frame(height: 25, alignment: .center)
        .accessibilityAddTraits(.isHeader)

      if controller.isUnavailable {
        emptyMessage("暂时无法读取或调整应用音量")
      }
      if controller.rows.isEmpty {
        if !controller.isUnavailable {
          emptyMessage("没有应用正在通过 SpeakerRouter 播放")
        }
      } else if controller.rows.count > 4 {
        ScrollView { rows }
          .frame(height: 118)
      } else {
        rows
      }
    }
    .onAppear { controller.refresh() }
  }

  private var rows: some View {
    VStack(spacing: 3) {
      ForEach(controller.rows) { row in
        AppVolumeControls(row: row, controller: controller, style: style)
      }
    }
    .disabled(controller.isUnavailable)
  }

  private func emptyMessage(_ message: String) -> some View {
    HStack(spacing: 6) {
      RouterPanelIcon.audioLines.view(size: 13)
      Text(message)
    }
    .font(.system(size: 11))
    .foregroundStyle(style.muted)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .background(style.tint.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
  }
}

private struct AppVolumeControls: View {
  let row: AppVolumeRow
  let controller: AppVolumeController
  let style: RouterPanelStyle

  var body: some View {
    HStack(spacing: 6) {
      HStack(spacing: 6) {
        appTile
        Text(row.name)
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(1)
          .help(row.name)
      }
      .frame(width: 115, alignment: .leading)

      RouterVolumeSlider(
        value: Binding(
          get: { Double(row.percent) },
          set: { controller.setPercent(Int($0.rounded()), for: row.id) }
        ),
        maximum: 200,
        label: "\(row.name) 音量",
        percent: row.percent,
        style: style
      )
      .frame(height: 19)

      Text("\(row.percent)%")
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .frame(width: 36, alignment: .trailing)
        .accessibilityHidden(true)

      HStack(spacing: 0) {
        Button {
          controller.toggleMute(for: row.id)
        } label: {
          (row.isMuted ? RouterPanelIcon.muted : .volume)
            .view(size: 13)
            .frame(width: 23, height: 24)
            .contentShape(Rectangle())
        }
        .foregroundStyle(row.isMuted ? style.accent : style.muted)
        .help(row.isMuted ? "取消静音" : "静音")
        .accessibilityLabel("\(row.name) \(row.isMuted ? "取消静音" : "静音")")

        Button {
          controller.reset(row.id)
        } label: {
          RouterPanelIcon.reset.view(size: 13)
            .frame(width: 23, height: 24)
            .contentShape(Rectangle())
        }
        .foregroundStyle(style.muted)
        .help("恢复默认音量（100%）")
        .accessibilityLabel("\(row.name) 恢复默认音量")
        .disabled(row.percent == 100 && !row.isMuted)
      }
      .buttonStyle(.borderless)
    }
    .frame(height: 28)
  }

  private var appTile: some View {
    let icon: RouterPanelIcon
    let foreground: Color
    let background: Color
    switch row.id {
    case .bundle("com.apple.Music"):
      (icon, foreground, background) = (.music, style.musicInk, style.musicTint)
    case .bundle("com.apple.Safari"):
      (icon, foreground, background) = (.compass, style.browserInk, style.browserTint)
    default:
      (icon, foreground, background) = (.audioLines, style.accent, style.tint)
    }
    return icon.view(size: 14)
      .foregroundStyle(foreground)
      .frame(width: 22, height: 22)
      .background(background, in: RoundedRectangle(cornerRadius: 6))
  }
}
