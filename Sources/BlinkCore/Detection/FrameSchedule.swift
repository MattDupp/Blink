import Foundation

/// Decides, for each camera frame, how much work it gets.
///
/// Every frame costs the same to read in full, and most of that cost is finding the eyes
/// (MEASURED in the running app, 2026-11-20: 12 to 15 ms with Vision, against 2 ms to cut
/// and classify them). Two facts allow skipping work without missing a blink:
///
///   - EYES DO NOT MOVE FAR IN A THIRTIETH OF A SECOND. The squares found on one frame
///     still frame the eyes on the next: the search runs on one frame in two, the frame
///     in between reads the same squares. Every frame is still classified.
///   - AN EMPTY CHAIR HAS NO BLINKS. After 3 s without a face, one frame in six is looked
///     at, enough to notice a return within a fifth of a second.
///
/// The two rules used to live in two different files, written two different ways. They
/// are one decision, so they are one type, tested as one.
public struct FrameSchedule {

    public enum Step: Equatable {
        /// Nobody has been there for a while: this frame is not looked at.
        case skip
        /// Read the eyes where the last search found them.
        case reuseSquares
        /// Search for the eyes, then read them.
        case search
    }

    /// Search for the eyes on one frame in this many, while they are found.
    ///
    /// MEASURED 2026-11-20 on three captures replayed from their whole frames (`make
    /// replay`): at 2 the blinks counted are those counted when every frame is searched.
    /// At 3, five false blinks appear in the two seconds where the person leans out of
    /// view: squares two frames old no longer frame the eyes of a head that moves.
    public var searchEvery = 2
    /// Searches without a face before the chair counts as empty (90 = 3 s).
    public var idleAfterSearches = 90
    /// While it is empty, look at one frame in this many.
    public var idleStride = 6

    private var frame = 0
    private var framesSinceSearch = 0
    private var searchesWithoutFace = 0
    private var haveEyes = false

    public init() {}

    /// Call once per frame. `everyFrame`: search whatever the rules say (a capture wants
    /// every frame read in full).
    public mutating func next(everyFrame: Bool = false) -> Step {
        frame += 1
        if everyFrame { return .search }
        if searchesWithoutFace >= idleAfterSearches && frame % idleStride != 0 { return .skip }
        if haveEyes && framesSinceSearch + 1 < searchEvery {
            framesSinceSearch += 1
            return .reuseSquares
        }
        return .search
    }

    /// Call after a search, with whether it found the eyes. A search that finds no face
    /// is repeated on the very next frame: stale squares are never kept.
    public mutating func searched(found: Bool) {
        haveEyes = found
        framesSinceSearch = 0
        searchesWithoutFace = found ? 0 : searchesWithoutFace + 1
    }
}
