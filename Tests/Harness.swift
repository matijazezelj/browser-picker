// Browser Picker -- the shared test harness. No XCTest (CI has only the
// Command Line Tools): every suite calls check(), and ConfigTests' main
// exits non-zero if any check failed.

nonisolated(unsafe) var testFailures = 0

func check(_ ok: Bool, _ what: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
    if !ok { testFailures += 1; print("FAIL \(file):\(line): \(what())") }
}
