import IOBluetooth
import Foundation

class BluetoothEventSource: NSObject, EventSource {

    // =========================================================================
    /// Identifies this source as "bluetooth" for rule matching.
    let sourceType = "bluetooth"

    // =========================================================================
    /// Delegate that receives connect and disconnect events.
    weak var delegate: EventSourceDelegate?

    // =========================================================================
    /// Device identifiers (normalised MACs) that need disconnect monitoring.
    private let disconnectIdentifiers: Set<String>

    // =========================================================================
    /// Retained reference to the global connect notification registration.
    private var connectNotification: IOBluetoothUserNotification?

    // =========================================================================
    /// Repeating timer that polls connection state of devices in
    /// disconnectIdentifiers. Used in place of IOBluetooth's per-device
    /// disconnect notification, which does not fire reliably for multi-host
    /// keyboards (e.g. Logitech MX Keys S) when they switch channels.
    private var pollTimer: Timer?

    // =========================================================================
    /// Last known isConnected() state per disconnect-watched identifier.
    private var lastConnectedState: [String: Bool] = [:]

    // =========================================================================
    /// How often to poll connection state. 1s gives near-immediate UX response
    /// without measurable CPU cost.
    private let pollInterval: TimeInterval = 1.0

    // -------------------------------------------------------------------------
    /// Creates a source that monitors Bluetooth events for the given identifiers.
    init(disconnectIdentifiers: Set<String>) {
        self.disconnectIdentifiers = disconnectIdentifiers
        super.init()
    }

    // -------------------------------------------------------------------------
    /// Registers for global Bluetooth connect notifications and starts polling
    /// for disconnects. Polling is only enabled when at least one rule needs
    /// disconnect tracking.
    func start() {
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceDidConnect(_:device:))
        )

        if connectNotification != nil {
            Log.info("Bluetooth event source registered")
        } else {
            Log.error("Failed to register Bluetooth connect notifications")
        }

        if !disconnectIdentifiers.isEmpty {
            startDisconnectPolling()
        }
    }

    // -------------------------------------------------------------------------
    /// Handles a Bluetooth device connection event from IOBluetooth.
    @objc private func deviceDidConnect(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        guard let rawAddress = device.addressString else {
            Log.debug("Connect event with nil address, skipping")
            return
        }

        let identifier = MACAddress.normalise(rawAddress)
        let deviceName = device.name ?? "unknown"
        Log.info("Bluetooth device connected: \(identifier)")
        Log.debug(
            "Bluetooth connect detail: mac=\(identifier) "
                + "name=\"\(deviceName)\""
        )

        delegate?.eventSource(
            self,
            didDetect: .connect,
            forDevice: identifier
        )

        // Keep the poll baseline in sync so a transient connect doesn't get
        // mistakenly classified as a fresh disconnect on the next tick.
        if disconnectIdentifiers.contains(identifier) {
            lastConnectedState[identifier] = true
        }
    }

    // -------------------------------------------------------------------------
    /// Starts the disconnect-detection polling timer and seeds the baseline
    /// state from the current connection status of each watched device.
    private func startDisconnectPolling() {
        for identifier in disconnectIdentifiers {
            lastConnectedState[identifier] = isDeviceCurrentlyConnected(identifier)
        }

        Log.debug(
            "Disconnect polling started "
                + "(\(pollInterval)s interval, "
                + "\(disconnectIdentifiers.count) device(s))"
        )

        pollTimer = Timer.scheduledTimer(
            withTimeInterval: pollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.pollDisconnects()
        }
    }

    // -------------------------------------------------------------------------
    /// Compares current isConnected() state against the last poll for each
    /// watched device. A true → false transition synthesises a disconnect
    /// event for the delegate.
    private func pollDisconnects() {
        for identifier in disconnectIdentifiers {
            let nowConnected = isDeviceCurrentlyConnected(identifier)
            let wasConnected = lastConnectedState[identifier] ?? false

            if wasConnected && !nowConnected {
                Log.info("Bluetooth device disconnected: \(identifier)")
                delegate?.eventSource(
                    self,
                    didDetect: .disconnect,
                    forDevice: identifier
                )
            }

            lastConnectedState[identifier] = nowConnected
        }
    }

    // -------------------------------------------------------------------------
    /// Looks up the paired Bluetooth device with the given identifier and
    /// returns its current connection state. Returns false if the device is
    /// not paired or no paired devices exist.
    private func isDeviceCurrentlyConnected(_ identifier: String) -> Bool {
        guard let pairedDevices = IOBluetoothDevice.pairedDevices()
                as? [IOBluetoothDevice] else {
            return false
        }

        for device in pairedDevices {
            guard let rawAddress = device.addressString else { continue }
            if MACAddress.normalise(rawAddress) == identifier {
                return device.isConnected()
            }
        }

        return false
    }

}
