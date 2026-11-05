// Direct handling on the day and week grids, shared by the Mac and the iPhone: the drag maths (15 minute steps) and a small undo list.
import Foundation

public enum DragMath {
    public static let step = 15  // minutes

    /// A drag's height, in whole 15 minute steps (a quarter hour is a quarter of `hourH`).
    public static func minutes(dy: Double, hourH: Double) -> Int { Int((dy / (hourH / 4)).rounded()) * step }

    /// The whole event, `minutes` later (or earlier) and `days` days over.
    public static func move(_ it: Item, minutes: Int, days: Int = 0) -> Item {
        var n = it
        n.start = addDays(it.start, days).addingTimeInterval(Double(minutes) * 60)
        n.end = addDays(it.end, days).addingTimeInterval(Double(minutes) * 60)
        return n
    }

    /// The bottom edge moved; the event never gets shorter than one step.
    public static func stretch(_ it: Item, minutes: Int) -> Item {
        var n = it
        n.end = max(it.start.addingTimeInterval(Double(step) * 60), it.end.addingTimeInterval(Double(minutes) * 60))
        return n
    }

    /// Where a tap at height `y` in a day column starts a new event: the half hour above it, as on the Mac.
    public static func slot(on day: Date, y: Double, hourH: Double) -> Date {
        let m = min(23 * 60 + 30, max(0, Int(y / hourH * 60) / 30 * 30))
        return cal.date(byAdding: .minute, value: m, to: day)!
    }
}

/// The steps Undo can take back, newest last. Each step puts one change back and says if it could not.
public final class UndoStack {
    private var steps: [() -> Failure?] = []
    public init() {}
    public var canUndo: Bool { !steps.isEmpty }
    public func push(_ undo: @escaping () -> Failure?) { steps.append(undo) }
    /// Takes back the newest change. Nil when it worked or there was nothing to take back.
    @discardableResult
    public func undo() -> Failure? { steps.popLast()?() }
}
