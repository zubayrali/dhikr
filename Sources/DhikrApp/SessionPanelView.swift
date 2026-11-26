import SwiftUI
import DhikrCore

/// The ambient dropdown content — bismillah-inspired design language:
/// GeezaPro Arabic typesetting, ring progress as the emotional center,
/// density that feels at home living under the menu bar all day.
struct SessionPanelView: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let engine = controller.engine {
                    activeSession(engine)
                } else {
                    pickerView
                }
            }
            .padding(16)

            footerBar
        }
        .frame(width: 300)
    }

    // MARK: - footer: input device picker + quit — always visible, both states

    private var footerBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Menu {
                    Button(action: { controller.selectInputDevice(uid: nil) }) {
                        HStack {
                            Text("System Default")
                            if controller.inputUsesSystemDefault {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    Divider()
                    ForEach(controller.inputDevices, id: \.uid) { device in
                        Button(action: { controller.selectInputDevice(uid: device.uid) }) {
                            HStack {
                                Text(device.name)
                                if !controller.inputUsesSystemDefault && controller.selectedInputUID == device.uid {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "mic")
                            .font(.system(size: 10))
                        Text(controller.inputDeviceName.isEmpty
                             ? controller.deviceManager.resolveTargetName()
                             : controller.inputDeviceName)
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Spacer()

                Button(action: { (NSApp.delegate as? AppDelegate)?.quitGracefully() }) {
                    Image(systemName: "power")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Quit Dhikr")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    // MARK: - picker

    private var pickerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Dhikr")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if controller.streak > 0 {
                    Label("\(controller.streak)", systemImage: "flame.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 12, weight: .medium))
                }
                if controller.todayTotal > 0 {
                    Text("\(controller.todayTotal) today")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let u = controller.unfinished {
                Button(action: { controller.resumeUnfinished() }) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.uturn.forward.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Continue where you stopped")
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(u.setName) — \(u.counts.reduce(0, +))/\(u.targets.reduce(0, +))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(9)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }

            ForEach(DhikrLibrary.sets) { set in
                Button(action: { controller.startSession(set: set) }) {
                    HStack(spacing: 10) {
                        Text(set.steps.count > 1 ? "٣٣" : "١٠٠")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 26)
                        Text(set.name)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.quaternary.opacity(0.001))
                .overlay(alignment: .bottom) {
                    Divider().padding(.leading, 44)
                }
            }
        }
    }

    // MARK: - active session

    private func activeSession(_ engine: SessionEngine) -> some View {
        VStack(spacing: 10) {
            // listening state + input device
            HStack(spacing: 5) {
                if controller.listening {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 10))
                        .symbolEffect(.pulse)
                    Text(controller.inputDeviceName.isEmpty
                         ? "Listening"
                         : controller.inputDeviceName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Image(systemName: "mic.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(controller.voiceAvailable ? "Voice inactive" : "Tap mode")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // step position for multi-step sets
                if engine.steps.count > 1 {
                    Text("\(engine.currentStep + 1)/\(engine.steps.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }

            // input level meter
            if controller.listening {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(.green.opacity(0.65))
                            .frame(width: geo.size.width * CGFloat(controller.audioLevel))
                    }
                }
                .frame(height: 3)
            }

            // the dhikr — GeezaPro is the system's proper Arabic typeface
            if let dhikr = engine.currentDhikr {
                Text(dhikr.arabic)
                    .font(.custom("GeezaPro", size: 28))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
                Text(dhikr.transliteration)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // ring progress — the tap target and emotional center
            Button(action: { controller.tap() }) {
                ZStack {
                    Circle()
                        .stroke(.quaternary, lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: CGFloat(engine.currentCount) / CGFloat(max(1, engine.currentTarget)))
                        .stroke(.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.25), value: engine.currentCount)
                    VStack(spacing: 0) {
                        Text("\(engine.currentCount)")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("of \(engine.currentTarget)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 108, height: 108)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottom) {
                Text("tap or press space")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
                    .offset(y: 14)
            }
            .padding(.bottom, 12)

            // session controls
            HStack(spacing: 10) {
                Button(action: { controller.pauseToggle() }) {
                    Label(engine.paused ? "Resume" : "Pause",
                          systemImage: engine.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .controlSize(.small)
                Button(action: { controller.endSession() }) {
                    Label("End", systemImage: "stop.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .controlSize(.small)
            }
            .buttonStyle(.bordered)

            // live transcript — dimmed diagnostic line
            if !controller.lastTranscript.isEmpty {
                Text(controller.lastTranscript)
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, .rightToLeft)
            }
        }
    }
}
