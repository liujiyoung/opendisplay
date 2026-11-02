/// The presentation sequence is shared by TCP and UDP for a sender session.
/// Delivery acknowledgement and loss accounting belong only to each UDP flow.
struct CursorSequenceState {
    private(set) var lastPresented: UInt64 = 0
    private var lastUDP: UInt64 = 0
    private var needsAcknowledgement = true

    mutating func resetSession() { self = CursorSequenceState() }

    mutating func beginUDPFlow() {
        lastUDP = 0
        needsAcknowledgement = true
    }

    mutating func receiveUDP(_ sequence: UInt64) -> (acknowledge: Bool, lost: Int) {
        guard sequence > 0 else { return (false, 0) }
        let acknowledge = needsAcknowledgement
        needsAcknowledgement = false
        let lost: Int
        if lastUDP == 0 { lost = 0 }
        else if sequence <= lastUDP { lost = 1 }
        else { lost = Int(min(sequence - lastUDP - 1, 1_000_000)) }
        lastUDP = max(lastUDP, sequence)
        return (acknowledge, lost)
    }

    mutating func acceptForPresentation(_ sequence: UInt64) -> Bool {
        guard sequence > lastPresented else { return false }
        lastPresented = sequence
        return true
    }
}
