import AudioToolbox
import SwiftUI
import UIKit

struct InputScreen: View {
    @EnvironmentObject private var session: BluetoothSession

    private struct LogEntry: Identifiable {
        let id: Int
        let time: String
        let text: String
    }

    private enum TestPhase: Equatable {
        case idle
        case countdown(Int)
        case tapping(beat: Int)
        case done
    }

    /// The screen shows the newest 50 events; saved reports keep up to 500.
    private static let shownLogEntries = 50
    private static let maxLogEntries = 500
    private static let testBeats = 20

    /// 24-hour clock with milliseconds, so gaps between gestures can be measured.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let reportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter
    }()

    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    @State private var log: [LogEntry] = []
    @State private var nextId = 0
    /// Gesture counts per device, then per gesture name. Unlike the log these
    /// are never trimmed, so they stay exact over a long test run.
    @State private var gestureCounts: [String: [String: Int]] = [:]

    @State private var testPhase = TestPhase.idle
    @State private var testTask: Task<Void, Never>?
    /// When each beat was prompted, and each ring gesture that arrived while
    /// the test was recording.
    @State private var beatTimes: [Date] = []
    @State private var ringGestures: [(date: Date, relayed: Bool)] = []
    @State private var recording = false
    @State private var saveStatus: String?

    var body: some View {
        Form {
            Section("Tap test") {
                testStatus
                Button(isTestRunning ? "Stop" : "Start \(Self.testBeats)-tap test") {
                    if isTestRunning {
                        stopTapTest()
                    } else {
                        startTapTest()
                    }
                }
                if let saveStatus {
                    Text(saveStatus)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
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
                Button("Save log now") {
                    saveInputLog()
                }
                Text("Saves the counters and the last \(Self.maxLogEntries) events to Files › On My iPhone › Even Template › Reports. Tap test results are saved there automatically.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Button("Clear log and counters") {
                    clearLog()
                }
                if log.isEmpty {
                    Text("No events yet.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(log.prefix(Self.shownLogEntries)) { entry in
                    Text("\(entry.time)  \(entry.text)")
                        .font(.footnote.monospaced())
                }
            }
        }
        .onReceive(session.events) { event in
            handle(event)
        }
        .onDisappear {
            stopTapTest()
        }
    }

    // MARK: - Tap test

    private var isTestRunning: Bool {
        switch testPhase {
        case .countdown, .tapping: true
        case .idle, .done: false
        }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testPhase {
        case .idle:
            Text("Clears the log, counts down from 3, then beats once a second \(Self.testBeats) times with a click and a vibration. The beat count also shows on the glasses, which keeps them relaying ring taps to the phone. Tap the ring once on each beat, then compare the result with the count.")
                .font(.footnote)
                .foregroundColor(.secondary)
        case let .countdown(seconds):
            bigText("Get ready… \(seconds)")
        case let .tapping(beat):
            bigText("Tap \(beat) of \(Self.testBeats)")
        case .done:
            let missed = missedBeats
            let relayed = ringGestures.filter(\.relayed).count
            VStack(alignment: .leading, spacing: 4) {
                Text("\(ringGestures.count) ring gestures for \(beatTimes.count) beats")
                    .font(.headline)
                Text("Direct from the ring: \(ringGestures.count - relayed) · Via the glasses: \(relayed)")
                Text(missed.isEmpty
                     ? "Every beat had a ring gesture."
                     : "Beats with no ring gesture: \(missed.map(String.init).joined(separator: ", "))")
                Text("The counters below break the gestures down by type.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func bigText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
    }

    /// Each beat owns the time from 0.3s before it until 0.3s before the next
    /// beat (1s after the last one). The windows have no gaps, so a slow tap
    /// still lands on its beat instead of falling between two; taps arrive
    /// about 200-500 ms after the beat.
    private func beatWindow(_ index: Int) -> Range<Date> {
        let start = beatTimes[index].addingTimeInterval(-0.3)
        let end = index + 1 < beatTimes.count
            ? beatTimes[index + 1].addingTimeInterval(-0.3)
            : beatTimes[index].addingTimeInterval(1.0)
        return start ..< end
    }

    private func gestures(onBeat index: Int) -> [Date] {
        let window = beatWindow(index)
        return ringGestures.map(\.date).filter { window.contains($0) }.sorted()
    }

    private var missedBeats: [Int] {
        beatTimes.indices.filter { gestures(onBeat: $0).isEmpty }.map { $0 + 1 }
    }

    private func startTapTest() {
        stopTapTest()
        clearLog()
        beatTimes = []
        ringGestures = []
        UIApplication.shared.isIdleTimerDisabled = true
        testTask = Task { @MainActor in
            for seconds in stride(from: 3, through: 1, by: -1) {
                testPhase = .countdown(seconds)
                showOnGlasses("Ring tap test\nGet ready… \(seconds)")
                playCountdown()
                guard await sleepOneSecond() else { return }
            }
            recording = true
            for beat in 1 ... Self.testBeats {
                testPhase = .tapping(beat: beat)
                beatTimes.append(Date())
                showOnGlasses("Tap \(beat) / \(Self.testBeats)")
                playBeat()
                guard await sleepOneSecond() else { return }
            }
            // Keeps recording for one more second so the last tap's BLE
            // notification still counts.
            guard await sleepOneSecond() else { return }
            recording = false
            testPhase = .done
            showOnGlasses("Done: \(ringGestures.count) ring taps for \(Self.testBeats) beats")
            saveTestReport()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func stopTapTest() {
        testTask?.cancel()
        testTask = nil
        recording = false
        if isTestRunning {
            testPhase = .idle
        }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Keeps this app's page on the glasses for the whole test, and gives the
    /// wearer the beat count. The G2 only relays ring gestures to the phone
    /// (source 2) while an app page is showing; without one, the glasses'
    /// own UI takes the taps and the test would count them as missed.
    private func showOnGlasses(_ text: String) {
        guard session.glasses.ready else { return }
        let sdk = session.sdk
        Task { try? await sdk.displayText(text) }
    }

    /// Returns false when the test was stopped during the wait.
    private func sleepOneSecond() async -> Bool {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return !Task.isCancelled
    }

    // System sounds follow the ring/silent switch, so the vibration covers a
    // silenced phone.
    private func playCountdown() {
        AudioServicesPlaySystemSound(1103) // "Tink", distinct from the beat
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func playBeat() {
        AudioServicesPlaySystemSound(1104) // keyboard click
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: - Saved reports

    private func saveTestReport() {
        let missed = missedBeats
        let relayed = ringGestures.filter(\.relayed).count
        var lines = reportHeader("Ring tap test")
        lines += [
            "",
            "Result: \(ringGestures.count) ring gestures for \(beatTimes.count) beats",
            "Direct from the ring: \(ringGestures.count - relayed) · Via the glasses: \(relayed)",
            "Beats with no ring gesture: \(missed.isEmpty ? "none" : missed.map(String.init).joined(separator: ", "))",
            "",
            "Beats (delay = first ring gesture after the beat; a beat runs until 0.3s before the next):",
        ]
        for (index, beat) in beatTimes.enumerated() {
            let answers = gestures(onBeat: index)
            var outcome = answers.first.map { "delay \(Int(($0.timeIntervalSince(beat) * 1000).rounded())) ms" } ?? "MISSED"
            if answers.count > 1 {
                outcome += " (\(answers.count) gestures)"
            }
            lines.append("Beat \(index + 1)  \(Self.timeFormatter.string(from: beat))  \(outcome)")
        }
        lines += reportBody()
        writeReport(named: "tap-test", lines)
    }

    private func saveInputLog() {
        writeReport(named: "input-log", reportHeader("Input log") + reportBody())
    }

    private func reportHeader(_ title: String) -> [String] {
        let glasses = session.glasses
        return [
            title,
            "Saved: \(Self.reportDateFormatter.string(from: Date()))",
            "Glasses: \(glasses.ready ? "connected and ready" : glasses.connection.rawValue.lowercased())",
            "Glasses battery: \(glasses.battery?.level.map { "\($0)%" } ?? "unknown")",
            // controllerConnected is set by the R1 driver and also by the G2
            // when it relays a ring gesture, so it covers both paths.
            "Ring connected (directly or through the glasses): \(session.link.ringConnected ? "yes" : "no")",
        ]
    }

    private func reportBody() -> [String] {
        var lines = ["", "Gesture counters:"]
        if gestureCounts.isEmpty {
            lines.append("none")
        }
        for device in gestureCounts.keys.sorted() {
            let gestures = gestureCounts[device] ?? [:]
            let breakdown = gestures.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            lines.append("\(device): \(breakdown)")
        }
        lines += ["", "Event log, oldest first:"]
        lines += log.reversed().map { "\($0.time)  \($0.text)" }
        return lines
    }

    /// Writes to Documents/Reports, which the Files app lists under
    /// On My iPhone › Even Template (UIFileSharingEnabled in Info.plist).
    private func writeReport(named name: String, _ lines: [String]) {
        do {
            let folder = try FileManager.default
                .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Reports", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("\(name)_\(Self.fileNameFormatter.string(from: Date())).txt")
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            saveStatus = "Saved \(file.lastPathComponent)"
        } catch {
            saveStatus = "Could not save the report: \(error.localizedDescription)"
        }
    }

    // MARK: - Event log

    private func clearLog() {
        log = []
        gestureCounts = [:]
    }

    private func handle(_ event: BluetoothEvent) {
        switch event {
        case let .touch(touch):
            let device = deviceLabel(touch)
            let gesture = touch.gestureName ?? "?"
            gestureCounts[device, default: [:]][gesture, default: 0] += 1
            if recording, let relayed = ringPath(touch) {
                ringGestures.append((eventDate(touch.timestamp), relayed))
            }
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

    /// Whether a touch came from the ring: false when the ring sent it to the
    /// phone directly, true when the glasses relayed it (source 2, after the
    /// ring is handed off to them), nil for any other input.
    private func ringPath(_ touch: TouchEvent) -> Bool? {
        if touch.deviceModel == ControllerTypes.R1 { return false }
        if touch.source == 2 { return true }
        return nil
    }

    /// `timestamp` is the driver's ms-since-epoch stamp taken when the BLE
    /// notification arrived; events without one use the time they reach the UI.
    private func eventDate(_ timestamp: Int?) -> Date {
        timestamp.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date()
    }

    private func append(_ text: String, timestamp: Int? = nil) {
        let entry = LogEntry(
            id: nextId,
            time: Self.timeFormatter.string(from: eventDate(timestamp)),
            text: text
        )
        nextId += 1
        log = Array([entry] + log.prefix(Self.maxLogEntries - 1))
    }
}
