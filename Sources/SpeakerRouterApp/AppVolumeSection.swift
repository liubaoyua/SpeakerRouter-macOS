import SwiftUI

struct AppVolumeSection: View {
  @ObservedObject var controller: AppVolumeController

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("应用音量")
        .font(.headline)

      if controller.isUnavailable {
        Text("暂时无法读取或调整应用音量")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if controller.rows.isEmpty {
        if !controller.isUnavailable {
          Text("没有应用正在通过 SpeakerRouter 播放")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if controller.rows.count > 4 {
        ScrollView {
          rows
        }
        .frame(height: 200)
      } else {
        rows
      }
    }
    .onAppear { controller.refresh() }
  }

  private var rows: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(controller.rows) { row in
        VStack(alignment: .leading, spacing: 4) {
          Text(row.name)
            .lineLimit(1)
            .help(row.name)

          HStack(spacing: 8) {
            Slider(
              value: Binding(
                get: { Double(row.percent) },
                set: { controller.setPercent(Int($0), for: row.id) }
              ),
              in: 0...200,
              step: 1
            ) {
              Text("\(row.name) 音量")
            }
            .labelsHidden()
            .accessibilityValue("\(row.percent)%")

            Text("\(row.percent)%")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .frame(width: 40, alignment: .trailing)

            Button {
              controller.toggleMute(for: row.id)
            } label: {
              Image(systemName: row.isMuted ? "speaker.slash.fill" : "speaker.wave.1")
                .frame(width: 16)
            }
            .help(row.isMuted ? "取消静音" : "静音")
            .accessibilityLabel(row.isMuted ? "取消静音" : "静音")

            Button {
              controller.reset(row.id)
            } label: {
              Image(systemName: "arrow.counterclockwise")
                .frame(width: 16)
            }
            .help("恢复默认音量（100%）")
            .accessibilityLabel("恢复默认音量")
            .disabled(row.percent == 100 && !row.isMuted)
          }
          .controlSize(.small)
        }
      }
    }
    .disabled(controller.isUnavailable)
  }
}
