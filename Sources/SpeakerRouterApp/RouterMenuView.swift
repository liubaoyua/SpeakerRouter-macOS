import AppKit
import SpeakerRouterCore
import SwiftUI

struct RouterMenuView: View {
  @ObservedObject var model: RouterViewModel
  @State private var showingSettings = false
  @State private var showingDevicePreferences = false
  @State private var confirmingDriverUninstall = false

  private let style = RouterPanelStyle()
  private var panelShape: RoundedRectangle { RoundedRectangle(cornerRadius: 8) }

  var body: some View {
    VStack(spacing: 0) {
      header
      if showingSettings {
        settings
      } else {
        controls
      }
      footer
    }
    .padding(1)
    .frame(width: 408)
    .foregroundStyle(style.ink)
    .background(style.panel, in: panelShape)
    .clipShape(panelShape)
    .overlay {
      panelShape.strokeBorder(style.line)
        .allowsHitTesting(false)
    }
    .tint(style.accent)
    .environment(\.colorScheme, .light)
  }

  private var header: some View {
    VStack(spacing: 0) {
      HStack(spacing: 9) {
        symbolTile(.audioLines, size: 32, iconSize: 19, radius: 10)
        VStack(alignment: .leading, spacing: 2) {
          Text("SpeakerRouter")
            .font(.system(size: 13, weight: .bold))
          Text(showingSettings ? "设置" : "音频路由")
            .font(.system(size: 11))
            .foregroundStyle(style.muted)
        }
        Spacer()
        Text(model.manualLockedUID == nil ? "自动路由" : "手动锁定")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(style.accent)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(style.tint, in: RoundedRectangle(cornerRadius: 6))
      }
      .padding(.horizontal, 13)
      .frame(height: 54)
      rule
    }
  }

  private var rule: some View {
    Rectangle()
      .fill(style.line)
      .frame(height: 1)
      .accessibilityHidden(true)
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 10) {
      currentOutput
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text("输出设备")
            .font(.system(size: 12, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
          Spacer()
          Button {
            model.refresh()
          } label: {
            RouterPanelIcon.refresh.view(size: 15)
              .frame(width: 27, height: 27)
              .contentShape(Rectangle())
          }
          .buttonStyle(.borderless)
          .foregroundStyle(style.muted)
          .accessibilityLabel("重新扫描设备")
          .help("重新扫描设备")
        }
        if !model.devices.isEmpty {
          deviceList
        }
      }

      AppVolumeSection(controller: model.appVolumes, style: style)
      if let error = model.lastError {
        errorMessage(error)
      }
    }
    .padding(.horizontal, 13)
    .padding(.top, 11)
    .padding(.bottom, 10)
  }

  private var currentOutput: some View {
    let selected = model.devices.first { $0.id == model.selectedUID }
    let isRouting = selected.map { $0.id == model.activeOutputUID } ?? false
    let shape = RoundedRectangle(cornerRadius: 12)

    return VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 9) {
        symbolTile(
          selected.map(deviceSymbol) ?? .muted, size: 35, iconSize: 20, radius: 8, inHero: true
        )
        VStack(alignment: .leading, spacing: 1) {
          Text(isRouting ? "当前输出" : "音频输出")
            .font(.system(size: 11))
            .foregroundStyle(style.muted)
          Text(selected?.displayName ?? "未选择设备")
            .font(.system(size: 17, weight: .bold))
            .tracking(-0.4)
            .lineLimit(2)
        }
        Spacer(minLength: 0)
      }
      if let selected {
        deviceVolume(selected, inHero: true)
      }
      if !isRouting {
        Text(model.routeStatus)
          .font(.system(size: 11))
          .foregroundStyle(style.muted)
      }
    }
    .padding(11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      shape
        .fill(LinearGradient(
          colors: [style.heroStart, style.heroEnd], startPoint: .leading, endPoint: .trailing
        ))
        .overlay {
          shape.fill(EllipticalGradient(
            colors: [style.heroGlow, style.heroGlow.opacity(0)],
            center: UnitPoint(x: 1, y: 0.05),
            startRadiusFraction: 0,
            endRadiusFraction: 0.78
          ))
        }
        .overlay { shape.strokeBorder(style.heroBorder) }
    }
    .help(model.routeStatus)
  }

  @ViewBuilder
  private var deviceList: some View {
    if model.devices.count > 5 {
      ScrollView { deviceRows }
        .frame(height: 175)
    } else {
      deviceRows
    }
  }

  private var deviceRows: some View {
    VStack(spacing: 3) {
      ForEach(model.devices) { row in
        let selected = model.selectedUID == row.id
        Button {
          model.select(row.id)
        } label: {
          HStack(spacing: 7) {
            symbolTile(deviceSymbol(row), size: 27, iconSize: 14, radius: 8)
              .opacity(row.isOnline ? 1 : 0.62)
            Text(row.displayName)
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(row.isOnline ? style.ink : style.muted)
              .lineLimit(1)
            Spacer(minLength: 4)
            Text(row.isOnline ? deviceType(row) : "离线")
              .font(.system(size: 11))
              .foregroundStyle(style.muted)
            if selected {
              (model.manualLockedUID == row.id ? RouterPanelIcon.lock : .check)
                .view(size: 13)
                .foregroundStyle(style.accent)
                .frame(width: 15)
            } else {
              Color.clear.frame(width: 15, height: 1)
                .accessibilityHidden(true)
            }
          }
          .padding(.horizontal, 6)
          .frame(height: 33)
          .background(selected ? style.tint : .clear, in: RoundedRectangle(cornerRadius: 8))
          .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(RouterPanelButtonStyle())
        .disabled(!row.isOnline)
        .accessibilityLabel(row.displayName)
        .accessibilityValue(row.isOnline ? (selected ? "已选择" : deviceType(row)) : "离线")
        .help(row.displayName)
      }
    }
  }

  private var footer: some View {
    VStack(spacing: 0) {
      rule
      HStack(spacing: 4) {
        if model.driverState.isChanging {
          ProgressView()
            .controlSize(.mini)
        } else {
          Circle()
            .fill(model.driverState.isCompatibleForRouting ? style.success : style.muted)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
        }
        Text(model.driverState.isCompatibleForRouting ? "驱动已安装" : "驱动 · \(model.driverState.description)")
          .foregroundStyle(style.muted)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
          .help(model.driverState.description)
        Spacer(minLength: 0)
        if showingSettings {
          Button {
            NSApplication.shared.terminate(nil)
          } label: {
            Label("退出", systemImage: "power")
          }
          .buttonStyle(.borderless)
        } else {
          Button {
            model.useAutomaticRouting()
          } label: {
            HStack(spacing: 4) {
              RouterPanelIcon.bolt.view(size: 13)
              Text("自动选择")
            }
            .foregroundStyle(style.accent)
            .padding(.horizontal, 6)
            .frame(height: 25)
            .background(style.tint, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
          }
          .buttonStyle(RouterPanelButtonStyle())
          .disabled(model.manualLockedUID == nil)
        }
        Button {
          showingSettings.toggle()
          confirmingDriverUninstall = false
        } label: {
          (showingSettings ? RouterPanelIcon.back : .settings)
            .view(size: 15)
            .foregroundStyle(style.muted)
            .frame(width: 27, height: 27)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(showingSettings ? "返回" : "设置")
        .help(showingSettings ? "返回" : "设置")
      }
      .font(.system(size: 11))
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
    }
  }

  private var settings: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(
        "登录时自动启动",
        isOn: Binding(
          get: { model.launchAtLoginEnabled },
          set: { model.setLaunchAtLogin($0) }
        )
      )
      .toggleStyle(.switch)
      .controlSize(.small)

      Divider()
      DisclosureGroup("设备顺序与音量", isExpanded: $showingDevicePreferences) {
        if model.devices.isEmpty {
          Text("暂无设备")
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        } else if model.devices.count > 4 {
          ScrollView {
            devicePreferences
              .padding(.top, 8)
          }
          .frame(height: 205)
        } else {
          devicePreferences
            .padding(.top, 8)
        }
      }

      Divider()
      driverSettings
      if let error = model.lastError {
        errorMessage(error)
      }
    }
    .padding(14)
  }

  private var devicePreferences: some View {
    VStack(spacing: 8) {
      ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, row in
        VStack(spacing: 3) {
          HStack {
            Text(row.displayName)
              .font(.subheadline)
              .lineLimit(1)
              .help(row.displayName)
            if !row.isOnline {
              Text("离线")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            moveButton(row, offset: -1, disabled: index == 0)
            moveButton(row, offset: 1, disabled: index == model.devices.count - 1)
          }
          deviceVolume(row)
        }
      }
    }
  }

  private func moveButton(_ row: RoutableOutputDevice, offset: Int, disabled: Bool) -> some View {
    let action = offset < 0 ? "上移" : "下移"
    return Button {
      model.move(row.id, offset: offset)
    } label: {
      Image(systemName: offset < 0 ? "chevron.up" : "chevron.down")
        .frame(width: 22, height: 20)
    }
    .buttonStyle(.borderless)
    .disabled(disabled)
    .accessibilityLabel("\(action) \(row.displayName)")
    .help("\(action) \(row.displayName)")
  }

  private var driverSettings: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("音频驱动")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text(model.driverState.description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if model.driverState.primaryActionTitle != nil || model.driverState.canUninstall {
        HStack {
          if let title = model.driverState.primaryActionTitle {
            Button(title) { model.installOrUpdateDriver() }
          }
          if model.driverState.canUninstall {
            if confirmingDriverUninstall {
              Text("确认卸载？")
                .font(.caption)
                .foregroundStyle(.secondary)
              Button("确认", role: .destructive) {
                confirmingDriverUninstall = false
                model.uninstallDriver()
              }
              Button("取消") { confirmingDriverUninstall = false }
            } else {
              Button("卸载驱动", role: .destructive) { confirmingDriverUninstall = true }
            }
          }
        }
        .controlSize(.small)
      }
    }
  }

  private func deviceVolume(_ row: RoutableOutputDevice, inHero: Bool = false) -> some View {
    let percent = Int((row.preference.volume * 100).rounded())
    return HStack(spacing: 7) {
      RouterPanelIcon.volume.view(size: 15)
        .foregroundStyle(style.muted)
      RouterVolumeSlider(
        value: Binding(
          get: { row.preference.volume },
          set: { model.setVolume($0, for: row.id) }
        ),
        maximum: 1,
        label: "\(row.displayName) 音量",
        percent: percent,
        style: style,
        inHero: inHero
      )
      .frame(height: 19)
      Text("\(percent)%")
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .frame(width: 36, alignment: .trailing)
        .accessibilityHidden(true)
    }
  }

  private func errorMessage(_ error: String) -> some View {
    Label(error, systemImage: "exclamationmark.triangle")
      .font(.caption)
      .foregroundStyle(.red)
      .textSelection(.enabled)
  }

  private func symbolTile(
    _ icon: RouterPanelIcon, size: CGFloat, iconSize: CGFloat, radius: CGFloat, inHero: Bool = false
  ) -> some View {
    icon.view(size: iconSize)
      .foregroundStyle(style.accent)
      .frame(width: size, height: size)
      .background(inHero ? style.heroTile : style.tint, in: RoundedRectangle(cornerRadius: radius))
  }

  private func deviceSymbol(_ row: RoutableOutputDevice) -> RouterPanelIcon {
    switch row.preference.kind {
    case .headphones: .headphones
    case .display: .monitor
    case .builtInSpeaker: .laptop
    case .other: .speaker
    }
  }

  private func deviceType(_ row: RoutableOutputDevice) -> String {
    if row.preference.kind == .display { return "显示器" }
    return switch row.preference.transport {
    case .bluetooth, .bluetoothLE: "蓝牙"
    case .builtIn: "内建"
    case .usb: "USB"
    case .hdmi: "HDMI"
    case .displayPort: "DisplayPort"
    case .airPlay: "AirPlay"
    default:
      switch row.preference.kind {
      case .headphones: "耳机"
      case .display: "显示器"
      case .builtInSpeaker: "内建"
      case .other: "其他"
      }
    }
  }
}

private struct RouterPanelButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
  }
}
