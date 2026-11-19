import Foundation

/// A socket or codec header is not a picture. Presentation belongs to a
/// particular connection and starts only after its first video sample.
struct ReceiverVideoPresentation: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var isReady = false
    private(set) var isLocked = false
    private(set) var isHoldingPreviousFrame = false
    private var active = false

    func accepts(_ generation: UInt64) -> Bool { active && self.generation == generation }

    mutating func begin(_ generation: UInt64, retainingPicture: Bool = false) {
        isHoldingPreviousFrame = retainingPicture && isReady && !isLocked
        self.generation = generation
        active = true
        isReady = false
        isLocked = false
    }

    mutating func receivedFrame(_ generation: UInt64) {
        guard accepts(generation), !isLocked else { return }
        isHoldingPreviousFrame = false
        isReady = true
    }

    mutating func endHold(_ generation: UInt64) {
        guard accepts(generation) else { return }
        isHoldingPreviousFrame = false
    }

    mutating func setLocked(_ locked: Bool, generation: UInt64) {
        guard accepts(generation) else { return }
        if isLocked != locked { isReady = false }
        if locked { isHoldingPreviousFrame = false }
        isLocked = locked
    }

    mutating func end(_ generation: UInt64) {
        guard accepts(generation) else { return }
        active = false
        isHoldingPreviousFrame = false
        isReady = false
        isLocked = false
    }
}
