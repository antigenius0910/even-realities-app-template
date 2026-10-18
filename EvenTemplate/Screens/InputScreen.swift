import SwiftUI

struct InputScreen: View {
    @EnvironmentObject private var session: BluetoothSession

    private struct LogEntry: Identifiable {
        let id: Int
        let time: String
        let text: String
    }

    private static let maxLogEntries = 50

    /// 24-hour clock with milliseconds, so gaps between gestures can be measured.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    @State private var log: [LogEntry] = []
    @State private var nextId = 0
    /// Gesture counts per device, then per gesture name. Unlike the log these
    /// are never trimmed, so they stay exact over a long test run.
    @State private var gestureCounts: [String: [String: Int]] = [:]

    var body: some View {
        Form {
            Section("Gesture counters") {
                if gestureCounts.isEmpty {
                    Text("No gestures yet.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(gestureCounts.keys.sorted(), id: \.self) { device in
                    let gestures = gestureCounts[device] ?? [:]
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(device): \(gestures.values.reduce(0, +)) received")
                        Text(gestures.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                            .font(.footnote.monospaced())
                            .foregroundColor(.secondary)
                    }
                }
            }
            Section("Input events") {
                Text("Live feed of touchpad gestures from the glasses, gestures from the R1 ring, button presses, head-up state, and battery updates. Tap or swipe on a connected device to see events arrive.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Button("Clear log and counters") {
                    log = []
                    gestureCounts = [:]
                }
                if log.isEmpty {
                    Text("No events yet.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(log) { entry in
                    Text("\(entry.time)  \(entry.text)")
                        .font(.footnote.monospaced())
                }
            }
        }
        .onReceive(session.events) { event in
            handle(event)
        }
    }

    private func handle(_ event: BluetoothEvent) {
        switch event {
        case let .touch(touch):
            let device = deviceLabel(touch)
            let gesture = touch.gestureName ?? "?"
            gestureCounts[device, default: [:]][gesture, default: 0] += 1
            append("touch \(gesture) (\(device))", timestamp: touch.timestamp)
        case let .buttonPress(press):
            append("button \(press.buttonId) \(press.pressType)", timestamp: press.timestamp)
        case let .raw(name, values):
            switch name {
            case "head_up":
                if let up = values["up"] as? Bool {
                    append("head \(up ? "up" : "down")")
                }
            case "battery_status":
                if let level = values["level"] as? Int {
                    let charging = values["charging"] as? Bool ?? false
                    append("battery \(level)%\(charging ? " charging" : "")")
                }
            default:
                break
            }
        default:
            break
        }
    }

    /// Ring taps can arrive straight from the ring or relayed by the glasses
    /// (source 2), so the source is part of the label to keep the paths apart.
    private func deviceLabel(_ touch: TouchEvent) -> String {
        let model = touch.deviceModel ?? "?"
        guard let source = touch.source else { return model }
        return "\(model) src \(source)"
    }

    /// `timestamp` is the driver's ms-since-epoch stamp taken when the BLE
    /// notification arrived; events without one use the time they reach the UI.
    private func append(_ text: String, timestamp: Int? = nil) {
        let date = timestamp.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date()
        let entry = LogEntry(
            id: nextId,
            time: Self.timeFormatter.string(from: date),
            text: text
        )
        nextId += 1
        log = Array([entry] + log.prefix(Self.maxLogEntries - 1))
    }
}
