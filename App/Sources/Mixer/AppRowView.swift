import MixerCore
import MonitorUIKit
import SwiftUI
import UniformTypeIdentifiers

struct AppRowView: View {
    static let height: CGFloat = 54

    let row: MixerEngine.Row
    let engine: MixerEngine
    let wheel: ScrollWheelMonitor
    let isSelected: Bool

    private var icon: NSImage {
        if let url = row.bundleURL { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .application)
    }

    private var percent: Int { Int((row.setting.volume * 100).rounded()) }
    private var isSolo: Bool { engine.soloID == row.id }
    private var isQuiet: Bool { row.setting.muted || row.silenced }
    /// Idle and hidden apps recede, but the controls stay at full contrast.
    private var identityOpacity: Double { row.isRunning && !row.hidden ? 1 : 0.5 }

    private var volume: Binding<Double> {
        Binding(
            get: { Double(row.setting.volume) },
            set: { value in
                // Option-click resets, as on the system's own sliders.
                if NSEvent.modifierFlags.contains(.option) {
                    engine.setVolume(1, for: row.id)
                    return
                }
                // 100% removes the tap entirely, so make it easy to land on.
                engine.setVolume(abs(value - 1) < 0.03 ? 1 : Float(value), for: row.id)
            })
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 28, height: 28)
                .opacity(identityOpacity)
                .overlay(alignment: .bottomTrailing) {
                    if row.isPlaying {
                        Circle()
                            .fill(TTColor.accent)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(.background, lineWidth: 1.5))
                    }
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(row.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(identityOpacity)
                    if isSolo {
                        Text("SOLO")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(TTColor.accent.opacity(0.35), in: Capsule())
                    }
                    if row.failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .help("Could not control this app's audio. Move the slider to retry.")
                            .accessibilityLabel("Could not control this app's audio")
                    }
                    Spacer(minLength: 4)
                    Button {
                        engine.reset(row.id)
                    } label: {
                        Text(isQuiet ? "Muted" : "\(percent)%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(percent > 100 && !isQuiet ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .frame(width: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Click to reset to 100%")
                    .accessibilityLabel("Reset \(row.name) to 100 percent")
                }
                Slider(value: volume, in: 0...Double(AppVolume.maxVolume))
                    .onHover { inside in
                        if inside {
                            wheel.hoveredID = row.id
                        } else if wheel.hoveredID == row.id {
                            wheel.hoveredID = nil
                        }
                    }
                    .help("Scroll to adjust. Option-click to reset. Above 100% boosts.")
                    .accessibilityLabel("\(row.name) volume")
                    .accessibilityValue(isQuiet ? "Muted" : "\(percent) percent")
            }

            Button {
                engine.setMuted(!row.setting.muted, for: row.id)
            } label: {
                Image(systemName: isQuiet ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 20)
                    .foregroundStyle(row.setting.muted ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .help(row.setting.muted ? "Unmute" : "Mute")
            .accessibilityLabel(row.setting.muted ? "Unmute \(row.name)" : "Mute \(row.name)")
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button(isSolo ? "End Solo" : "Solo (Mute Others)") {
                engine.solo(isSolo ? nil : row.id)
            }
            .disabled(!row.isRunning)
            Button("Reset to 100%") { engine.reset(row.id) }
                .disabled(row.setting.isDefault)
            Divider()
            Button(row.hidden ? "Show in List" : "Hide from List") {
                engine.setHidden(!row.hidden, for: row.id)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
