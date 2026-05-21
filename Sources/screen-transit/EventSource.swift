import Foundation

protocol EventSourceDelegate: AnyObject {

    // -------------------------------------------------------------------------
    /// Notifies the delegate that a device event was detected.
    func eventSource(
        _ source: EventSource,
        didDetect trigger: SwitchRule.Trigger,
        forDevice identifier: String
    )
}

protocol EventSource: AnyObject {

    // =========================================================================
    /// Identifier for the type of events this source monitors (e.g. "bluetooth").
    var sourceType: String { get }

    // =========================================================================
    /// Delegate that receives trigger events from this source.
    var delegate: EventSourceDelegate? { get set }

    // -------------------------------------------------------------------------
    /// Begins monitoring for device events.
    func start()
}
