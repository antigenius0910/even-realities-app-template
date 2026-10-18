import Combine
import Foundation

/// The app's single Bluetooth entry point: wraps the MentraBluetoothSDK facade,
/// republishes its state for SwiftUI, and fans out input/mic events to whoever
/// needs them (input log, notification viewer, mic meter).
@MainActor
final class BluetoothSession: ObservableObject {
    let sdk = MentraBluetoothSDK()

    @Published private(set) var glasses: GlassesRuntimeState
    @Published private(set) var scan: BluetoothScanState
    @Published private(set) var defaultDevice: Device?
    @Published private(set) var lastError: BluetoothSdkError?
    @Published private(set) var link: LinkStatus
    /// The model the user last asked to connect, until it connects, fails,
    /// or is disconnected.
    @Published private(set) var connectingModel: DeviceModel?

    /// Connection detail `glasses` doesn't carry: each glasses arm while the
    /// pair is still connecting, and the R1 ring.
    struct LinkStatus: Equatable {
        var leftArmConnected = false
        var rightArmConnected = false
        var ringConnected = false
        var ringBatteryLevel: Int?

        init(status: GlassesStatus) {
            leftArmConnected = status.leftArmConnected
            rightArmConnected = status.rightArmConnected
            ringConnected = status.controllerConnected
            ringBatteryLevel = status.controllerBatteryLevel >= 0 ? status.controllerBatteryLevel : nil
        }
    }

    let events = PassthroughSubject<BluetoothEvent, Never>()
    let micPcm = PassthroughSubject<MicPcmEvent, Never>()

    init() {
        glasses = sdk.glasses
        scan = sdk.scanState
        defaultDevice = sdk.defaultDevice
        link = LinkStatus(status: sdk.glassesStatus)
        sdk.delegate = self
    }

    // MARK: - Connection state

    func isConnected(_ model: DeviceModel) -> Bool {
        model == .r1 ? link.ringConnected : glasses.ready
    }

    /// Glasses count as connecting once either arm is up, even when the
    /// connect came from an automatic reconnect rather than a tap.
    func isConnecting(_ model: DeviceModel) -> Bool {
        if isConnected(model) { return false }
        if model == .r1 { return connectingModel == .r1 }
        return connectingModel == model || glasses.connected || link.leftArmConnected || link.rightArmConnected
    }

    // MARK: - Actions

    func startScan(_ model: DeviceModel) {
        lastError = nil
        do { try sdk.startScan(model: model) } catch { fail(error) }
    }

    func stopScan() {
        sdk.stopScan()
    }

    func connect(_ device: Device) {
        lastError = nil
        connectingModel = device.model
        sdk.stopScan()
        do { try sdk.connect(to: device) } catch { fail(error) }
    }

    func connectDefault() {
        lastError = nil
        connectingModel = defaultDevice?.model
        do { try sdk.connectDefault() } catch { fail(error) }
    }

    func disconnect() {
        connectingModel = nil
        sdk.disconnect()
    }

    func clearDefaultDevice() {
        sdk.clearDefaultDevice()
    }

    private func fail(_ error: Error) {
        connectingModel = nil
        lastError = error as? BluetoothSdkError
            ?? BluetoothSdkError(code: "error", message: String(describing: error))
    }
}

extension BluetoothSession: MentraBluetoothSDKDelegate {
    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didUpdateGlasses glasses: GlassesRuntimeState) {
        self.glasses = glasses
        // Arm and ring keys live in the "glasses" store category, so this
        // callback also fires when they change.
        link = LinkStatus(status: sdk.glassesStatus)
        if let model = connectingModel, isConnected(model) {
            connectingModel = nil
        }
    }

    func mentraBluetoothSDK(_: MentraBluetoothSDK, didUpdateScan scan: BluetoothScanState) {
        self.scan = scan
    }

    func mentraBluetoothSDK(_: MentraBluetoothSDK, didChangeDefaultDevice device: Device?) {
        defaultDevice = device
    }

    func mentraBluetoothSDK(_: MentraBluetoothSDK, didReceive event: BluetoothEvent) {
        events.send(event)
    }

    func mentraBluetoothSDK(_: MentraBluetoothSDK, didReceiveMicPcm event: MicPcmEvent) {
        micPcm.send(event)
    }

    func mentraBluetoothSDK(_: MentraBluetoothSDK, didFail error: BluetoothSdkError) {
        lastError = error
    }
}
