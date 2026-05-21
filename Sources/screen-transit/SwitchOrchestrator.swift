import Foundation

class SwitchOrchestrator: EventSourceDelegate {

    // =========================================================================
    /// Loaded application configuration with delay and switch rules.
    private let config: ScreenTransitConfig

    // =========================================================================
    /// Service for sending DDC/CI commands to displays.
    private let ddcService: DDCService

    // =========================================================================
    /// Active event sources being monitored.
    private var eventSources: [EventSource] = []

    // =========================================================================
    /// Pending work items keyed by rule name for reconnection storm debouncing.
    private var pendingWork: [String: DispatchWorkItem] = [:]

    // -------------------------------------------------------------------------
    /// Creates an orchestrator with the given configuration and DDC service.
    init(config: ScreenTransitConfig, ddcService: DDCService) {
        self.config = config
        self.ddcService = ddcService
    }

    // -------------------------------------------------------------------------
    /// Registers an event source and begins monitoring its events.
    func addEventSource(_ source: EventSource) {
        source.delegate = self
        eventSources.append(source)
        source.start()
    }

    // -------------------------------------------------------------------------
    /// Matches an incoming event against configured rules and schedules DDC commands.
    func eventSource(
        _ source: EventSource,
        didDetect trigger: SwitchRule.Trigger,
        forDevice identifier: String
    ) {
        Log.debug(
            "Event received: source=\(source.sourceType) "
                + "device=\(identifier) trigger=\(trigger.rawValue)"
        )

        let matchingRules = config.rules.filter { rule in
            let isMatch = rule.source == source.sourceType
                && rule.deviceIdentifier == identifier
                && rule.trigger == trigger

            Log.debug(
                "  Rule '\(rule.name)': "
                    + "source=\(rule.source == source.sourceType) "
                    + "device=\(rule.deviceIdentifier == identifier) "
                    + "trigger=\(rule.trigger == trigger) "
                    + "→ \(isMatch ? "MATCH" : "skip")"
            )

            return isMatch
        }

        if matchingRules.isEmpty {
            Log.debug("No rules matched")
        }

        for rule in matchingRules {
            scheduleSwitch(rule: rule)
        }
    }

    // -------------------------------------------------------------------------
    /// Schedules a DDC input switch after the configured delay, cancelling any pending switch for the same rule.
    private func scheduleSwitch(rule: SwitchRule) {
        pendingWork[rule.name]?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            Log.info(
                "Executing rule: \(rule.name) "
                    + "→ display \(rule.display), input \(rule.input)"
            )

            let isSuccessful = self.ddcService.setInput(
                display: rule.display,
                inputCode: rule.input
            )

            if isSuccessful {
                Log.info("Input switch successful")
            } else {
                Log.error("Input switch failed for rule: \(rule.name)")
            }

            self.pendingWork.removeValue(forKey: rule.name)
        }

        pendingWork[rule.name] = work

        DispatchQueue.main.asyncAfter(
            deadline: .now() + config.delay,
            execute: work
        )
    }
}
