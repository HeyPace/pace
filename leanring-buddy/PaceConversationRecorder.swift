import Foundation

nonisolated struct ConversationEvent: Codable, Equatable, Identifiable, Sendable {
    nonisolated enum Origin: String, Codable, Sendable {
        case voice, typed, assistant, progress, proactive, reminder, failure
    }

    nonisolated enum DeliveryState: String, Codable, Sendable {
        case accepted, completed, interrupted, cancelled
    }

    let eventID: String
    let turnID: String?
    let role: PaceChatRole
    let origin: Origin
    var text: String
    let createdAt: Date
    var deliveryState: DeliveryState

    var id: String { eventID }

    init(eventID: String = UUID().uuidString, turnID: String? = nil,
         role: PaceChatRole, origin: Origin, text: String,
         createdAt: Date = Date(), deliveryState: DeliveryState = .completed) {
        self.eventID = eventID
        self.turnID = turnID
        self.role = role
        self.origin = origin
        self.text = text
        self.createdAt = createdAt
        self.deliveryState = deliveryState
    }
}

@MainActor
protocol PaceConversationEventPersisting: AnyObject {
    func upsertConversationEvent(_ event: ConversationEvent)
}

/// A single event identity joins accepted input, committed output and chat reloads.
/// Speech playback and replay do not create events or infer what was heard.
@MainActor
final class PaceConversationRecorder {
    private let persister: any PaceConversationEventPersisting
    private let chatSession: PaceChatSession
    private var recordedEvents: [String: ConversationEvent] = [:]

    init(persister: any PaceConversationEventPersisting, chatSession: PaceChatSession) {
        self.persister = persister
        self.chatSession = chatSession
    }

    @discardableResult
    func acceptRequest(_ text: String, origin: ConversationEvent.Origin,
                       eventIdentifier: String = UUID().uuidString) -> ConversationEvent {
        if let existingEvent = recordedEvents[eventIdentifier] { return existingEvent }
        return record(ConversationEvent(eventID: eventIdentifier, turnID: eventIdentifier,
            role: .user, origin: origin, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            deliveryState: .accepted))
    }

    @discardableResult
    func record(_ event: ConversationEvent) -> ConversationEvent {
        guard !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return event }
        recordedEvents[event.eventID] = event
        persister.upsertConversationEvent(event)
        chatSession.upsertConversationEvent(event)
        return event
    }

    func event(withIdentifier eventIdentifier: String) -> ConversationEvent? {
        recordedEvents[eventIdentifier]
    }

    func updateDeliveryState(_ deliveryState: ConversationEvent.DeliveryState,
                             eventIdentifier: String, visibleText: String? = nil) {
        guard var event = recordedEvents[eventIdentifier] else { return }
        event.deliveryState = deliveryState
        if let visibleText { event.text = visibleText }
        record(event)
    }
}
