import Foundation

enum MACAddress {

    // -------------------------------------------------------------------------
    /// Normalises a MAC address to uppercase colon-separated format.
    static func normalise(_ address: String) -> String {
        address
            .uppercased()
            .replacingOccurrences(of: "-", with: ":")
    }

    // -------------------------------------------------------------------------
    /// Validates that a string is a well-formed MAC address (AA:BB:CC:DD:EE:FF).
    static func isValid(_ address: String) -> Bool {
        let octets = address.components(separatedBy: ":")
        guard octets.count == 6 else { return false }

        return octets.allSatisfy { octet in
            octet.count == 2 && octet.allSatisfy { $0.isHexDigit }
        }
    }
}
