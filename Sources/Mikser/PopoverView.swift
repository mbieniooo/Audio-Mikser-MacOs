import SwiftUI
import AppKit
import MikserCore

struct PopoverView: View {
    let model: MixerModel
    let onQuit: () -> Void
    private let rowHeight: CGFloat = 50
    private let maxVisibleRows = 8

    var body: some View {
        VStack(spacing: 0) {
            if model.rows.isEmpty {
                Text("No apps are playing audio.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            } else if model.rows.count > maxVisibleRows {
                ScrollView(.vertical) { rowList }
                    .frame(height: CGFloat(maxVisibleRows) * rowHeight)
            } else {
                rowList
            }
            Divider()
            FooterView(model: model, onQuit: onQuit)
        }
        .frame(width: 300)
    }

    private var rowList: some View {
        VStack(spacing: 0) {
            ForEach(model.rows) { row in
                AppRowView(row: row,
                           onLevel: { model.setLevel($0, for: row.id) },
                           onToggleMute: { model.setMuted(!row.muted, for: row.id) })
                    .frame(height: rowHeight)
                if row.id != model.rows.last?.id {
                    Divider().padding(.leading, 40)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct AppRowView: View {
    let row: MixerRow
    let onLevel: (Double) -> Void
    let onToggleMute: () -> Void
    @State private var dragValue: Double?

    private var shownLevel: Double { dragValue ?? row.level }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = row.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(row.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if row.isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .help("Playing now")
                    }
                    if let error = row.error {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                            .help("Playing at full volume: \(error)")
                    }
                    Spacer(minLength: 4)
                    Text("\(Int((shownLevel * 100).rounded()))%")
                        .font(.system(size: 11, weight: .regular).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { shownLevel },
                                      set: { value in dragValue = value; onLevel(value) }),
                       in: 0...1,
                       onEditingChanged: { editing in if !editing { dragValue = nil } })
                    .controlSize(.small)
                    .disabled(row.muted)
            }

            Button(action: onToggleMute) {
                Image(systemName: row.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(row.muted ? Color.red : Color.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.muted ? "Unmute" : "Mute")
        }
        .padding(.horizontal, 10)
        .opacity(row.muted ? 0.65 : 1)
    }
}

struct FooterView: View {
    let model: MixerModel
    let onQuit: () -> Void
    @State private var launchAtLogin = false
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        do { try model.setLaunchAtLogin(on); loginError = nil } catch { loginError = "\(error.localizedDescription)" }
                        launchAtLogin = model.launchAtLogin
                    }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Spacer()
                Button("Reset audio") { model.resetAudio() }
                    .controlSize(.small)
                    .help("Tear down and rebuild every scaled app's audio path")
                Button("Quit") { onQuit() }
                    .controlSize(.small)
            }
            if let loginError {
                Text(loginError).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onAppear { launchAtLogin = model.launchAtLogin }
    }
}
