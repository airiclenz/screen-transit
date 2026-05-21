import Foundation

struct ScreenTransitConfig {

    // =========================================================================
    /// Seconds to wait before executing a DDC/CI command after a trigger event.
    let delay: Double

    // =========================================================================
    /// Ordered list of rules that map trigger events to display input switches.
    let rules: [SwitchRule]
}

struct SwitchRule {

    // =========================================================================
    /// Human-readable label for this rule, used in log output.
    let name: String

    // =========================================================================
    /// Event source type that this rule responds to (e.g. "bluetooth").
    let source: String

    // =========================================================================
    /// Source-specific device identifier (MAC address for Bluetooth).
    let deviceIdentifier: String

    // =========================================================================
    /// Target display number as reported by m1ddc display list (1-based).
    let display: Int

    // =========================================================================
    /// DDC/CI VCP 0x60 input source code to switch to.
    let input: Int

    // =========================================================================
    /// Whether this rule fires on device connect or disconnect.
    let trigger: Trigger

    enum Trigger: String {
        case connect
        case disconnect
    }
}

enum ConfigLoader {

    // -------------------------------------------------------------------------
    /// Reads, parses, and validates a YAML configuration file at the given path.
    static func load(from path: URL) -> ScreenTransitConfig? {
        guard let content = try? String(
            contentsOf: path,
            encoding: .utf8
        ) else {
            Log.error("Cannot read config file: \(path.path)")
            return nil
        }

        return parse(content)
    }

    // -------------------------------------------------------------------------
    /// Parses YAML content string into a validated configuration.
    private static func parse(_ content: String) -> ScreenTransitConfig? {
        let lines = content.components(separatedBy: .newlines)
        var delay = 1.0
        var rules: [SwitchRule] = []
        var currentRule: [String: String] = [:]
        var isParsingRules = false

        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespaces)

            if stripped.isEmpty || stripped.hasPrefix("#") {
                continue
            }

            let indentation = line.prefix { $0 == " " }.count

            if indentation == 0 {
                if let rule = flushRule(&currentRule) {
                    rules.append(rule)
                } else if !currentRule.isEmpty {
                    return nil
                }

                if stripped.hasPrefix("delay:") {
                    delay = Double(extractValue(from: stripped)) ?? 1.0
                } else if stripped.hasPrefix("rules:") {
                    isParsingRules = true
                }
                continue
            }

            guard isParsingRules else { continue }

            if stripped.hasPrefix("- ") {
                if let rule = flushRule(&currentRule) {
                    rules.append(rule)
                } else if !currentRule.isEmpty {
                    return nil
                }

                let pair = String(stripped.dropFirst(2))
                let (key, value) = parseKeyValue(pair)
                currentRule[key] = value
            } else {
                let (key, value) = parseKeyValue(stripped)
                currentRule[key] = value
            }
        }

        if let rule = flushRule(&currentRule) {
            rules.append(rule)
        } else if !currentRule.isEmpty {
            return nil
        }

        if rules.isEmpty {
            Log.info("Config contains no rules — running idle")
        }

        return ScreenTransitConfig(delay: delay, rules: rules)
    }

    // -------------------------------------------------------------------------
    /// Validates accumulated fields into a SwitchRule, then clears the dictionary.
    private static func flushRule(
        _ fields: inout [String: String]
    ) -> SwitchRule? {
        guard !fields.isEmpty else { return nil }

        let result = buildRule(from: fields)
        fields.removeAll()
        return result
    }

    // -------------------------------------------------------------------------
    /// Constructs and validates a SwitchRule from parsed YAML key-value pairs.
    private static func buildRule(
        from fields: [String: String]
    ) -> SwitchRule? {
        guard let name = fields["name"] else {
            Log.error("Rule missing required field: name")
            return nil
        }

        let source = fields["source"] ?? "bluetooth"

        guard let deviceIdentifier = fields["device_id"]
            ?? fields["bluetooth_mac"] else {
            Log.error("Rule '\(name)' missing required field: device_id")
            return nil
        }

        guard let displayString = fields["display"],
              let display = Int(displayString) else {
            Log.error("Rule '\(name)' missing or invalid field: display")
            return nil
        }

        guard let inputString = fields["input"],
              let input = Int(inputString),
              input > 0 else {
            Log.error(
                "Rule '\(name)' missing or invalid field: input "
                    + "(must be a positive integer)"
            )
            return nil
        }

        guard let triggerString = fields["trigger"],
              let trigger = SwitchRule.Trigger(rawValue: triggerString) else {
            Log.error(
                "Rule '\(name)' missing or invalid trigger "
                    + "(must be 'connect' or 'disconnect')"
            )
            return nil
        }

        let normalisedIdentifier = normaliseMAC(deviceIdentifier)

        if source == "bluetooth" {
            guard isValidMAC(normalisedIdentifier) else {
                Log.error(
                    "Rule '\(name)' has invalid MAC address: "
                        + "\(deviceIdentifier)"
                )
                return nil
            }
        }

        return SwitchRule(
            name: name,
            source: source,
            deviceIdentifier: normalisedIdentifier,
            display: display,
            input: input,
            trigger: trigger
        )
    }

    // -------------------------------------------------------------------------
    /// Extracts the value portion from a "key: value" YAML line.
    private static func extractValue(from line: String) -> String {
        guard let colonIndex = line.firstIndex(of: ":") else {
            return ""
        }

        let raw = String(line[line.index(after: colonIndex)...])
            .trimmingCharacters(in: .whitespaces)

        return stripQuotesAndComments(raw)
    }

    // -------------------------------------------------------------------------
    /// Splits a "key: value" string into its key and cleaned value components.
    private static func parseKeyValue(
        _ text: String
    ) -> (String, String) {
        guard let colonIndex = text.firstIndex(of: ":") else {
            return (text.trimmingCharacters(in: .whitespaces), "")
        }

        let key = String(text[..<colonIndex])
            .trimmingCharacters(in: .whitespaces)
        let raw = String(text[text.index(after: colonIndex)...])
            .trimmingCharacters(in: .whitespaces)

        return (key, stripQuotesAndComments(raw))
    }

    // -------------------------------------------------------------------------
    /// Removes surrounding quotes and trailing inline comments from a raw value.
    private static func stripQuotesAndComments(
        _ value: String
    ) -> String {
        if value.hasPrefix("\"") {
            let content = value.dropFirst()
            if let endQuote = content.firstIndex(of: "\"") {
                return String(content[..<endQuote])
            }
            return String(content)
        }

        if let hashIndex = value.firstIndex(of: "#") {
            return String(value[..<hashIndex])
                .trimmingCharacters(in: .whitespaces)
        }

        return value
    }

    // -------------------------------------------------------------------------
    /// Normalises a MAC address to uppercase colon-separated format.
    private static func normaliseMAC(_ address: String) -> String {
        address
            .uppercased()
            .replacingOccurrences(of: "-", with: ":")
    }

    // -------------------------------------------------------------------------
    /// Validates that a string is a well-formed MAC address (AA:BB:CC:DD:EE:FF).
    private static func isValidMAC(_ address: String) -> Bool {
        let octets = address.components(separatedBy: ":")
        guard octets.count == 6 else { return false }

        return octets.allSatisfy { octet in
            octet.count == 2 && octet.allSatisfy { $0.isHexDigit }
        }
    }
}
