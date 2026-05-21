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

    // -------------------------------------------------------------------------
    /// Creates a source that monitors Bluetooth events for the given identifiers.
    init(disconnectIdentifiers: Set<String>) {
        self.disconnectIdentifiers = disconnectIdentifiers
        super.init()
    }

    // -------------------------------------------------------------------------
    /// Registers for global Bluetooth device connection notifications.
    func start() {
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceDidConnect(_:device:))
        )
        Log.info("Bluetooth event source registered")
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

        let identifier = normaliseMAC(rawAddress)
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

        if disconnectIdentifiers.contains(identifier) {
            device.register(
                forDisconnectNotification: self,
                selector: #selector(deviceDidDisconnect(_:device:))
            )
        }
    }

    // -------------------------------------------------------------------------
    /// Handles a Bluetooth device disconnection event from IOBluetooth.
    @objc private func deviceDidDisconnect(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        guard let rawAddress = device.addressString else {
            Log.debug("Disconnect event with nil address, skipping")
            return
        }

        let identifier = normaliseMAC(rawAddress)
        let deviceName = device.name ?? "unknown"
        Log.info("Bluetooth device disconnected: \(identifier)")
        Log.debug(
            "Bluetooth disconnect detail: mac=\(identifier) "
                + "name=\"\(deviceName)\""
        )

        delegate?.eventSource(
            self,
            didDetect: .disconnect,
            forDevice: identifier
        )
    }

    // -------------------------------------------------------------------------
    /// Normalises a MAC address to uppercase colon-separated format.
    private func normaliseMAC(_ address: String) -> String {
        address
            .uppercased()
            .replacingOccurrences(of: "-", with: ":")
    }
}
