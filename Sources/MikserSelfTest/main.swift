import Foundation
import MikserCore

let h = Harness()

h.suite("Types") { h in
    h.check("AppLevel clamps", AppLevel(level: 1.7, muted: false).level == 1)
    h.check("AppLevel.full is full", AppLevel.full.isFull)
    h.check("muted is not full", !AppLevel(level: 1, muted: true).isFull)
    h.check("muted gain is 0", AppLevel(level: 0.5, muted: true).effectiveGain == 0)
}

h.finish()
