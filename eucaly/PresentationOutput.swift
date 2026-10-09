import Foundation

/// A coherent value from Current. Preview and renderers never publish output.
nonisolated struct PresentationOutputSnapshot {
    let slide: Slide?
    let isPresenting: Bool
    let slidesVisible: Bool
    var projectionWindowID: UInt32? = nil
    var projectionWindowGeneration: UUID? = nil
}

nonisolated enum PresentationOutputEvent {
    case changed(PresentationOutputSnapshot)
    case project(PresentationOutputSnapshot)
    case show(PresentationOutputSnapshot)
    case stopped
}
