import Foundation

/// Minimal test harness (Command Line Tools ship no XCTest/Swift Testing runtime).
/// Usage: `swift run mikser-selftest` ; exit code 1 if any check fails.
final class Harness {
    private(set) var passed = 0
    private(set) var failed = 0
    private var currentSuite = ""

    func suite(_ name: String, _ body: (Harness) -> Void) {
        currentSuite = name
        print("== \(name)")
        body(self)
    }

    func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
        if condition() {
            passed += 1
            print("  ok   \(name)")
        } else {
            failed += 1
            let d = detail()
            print("  FAIL \(name)\(d.isEmpty ? "" : " :: " + d)")
        }
    }

    func approx(_ name: String, _ a: Double, _ b: Double, tol: Double) {
        check(name, abs(a - b) <= tol, "got \(a), want \(b) ± \(tol)")
    }

    func finish() -> Never {
        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
