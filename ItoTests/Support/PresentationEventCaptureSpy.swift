@testable import Ito

final class PresentationEventCaptureSpy: PresentationEventLogging {
    private(set) var events: [PresentationLogEvent] = []
    private(set) var formattedMessages: [String] = []

    func log(_ event: PresentationLogEvent) {
        events.append(event)
        formattedMessages.append(PresentationLogFormatter.format(event))
    }
}
