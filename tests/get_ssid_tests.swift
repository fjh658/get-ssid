// get_ssid_tests.swift — unit tests for get-ssid
//
// Compile:
//   xcrun swiftc -parse-as-library -DTESTING \
//     -target arm64-apple-macos11.0 \
//     get_ssid.swift tests/get_ssid_tests.swift \
//     -o /tmp/get-ssid-tests
//
// Run:
//   /tmp/get-ssid-tests

import Foundation

// MARK: - Lightweight test harness

private var _totalRun = 0
private var _totalFail = 0

@discardableResult
private func expect(_ condition: Bool,
                    _ msg: String = "",
                    file: String = #file,
                    line: Int = #line) -> Bool {
    _totalRun += 1
    if condition {
        return true
    } else {
        _totalFail += 1
        let loc = URL(fileURLWithPath: file).lastPathComponent
        print("    FAIL  \(loc):\(line)  \(msg)")
        return false
    }
}

private func assertEqual<T: Equatable>(_ a: T, _ b: T,
                                        _ msg: String = "",
                                        file: String = #file,
                                        line: Int = #line) {
    if !expect(a == b, msg.isEmpty ? "expected \(a) == \(b)" : msg, file: file, line: line) {}
}

private func assertTrue(_ v: Bool, _ msg: String = "", file: String = #file, line: Int = #line) {
    expect(v, msg.isEmpty ? "expected true" : msg, file: file, line: line)
}

private func assertFalse(_ v: Bool, _ msg: String = "", file: String = #file, line: Int = #line) {
    expect(!v, msg.isEmpty ? "expected false" : msg, file: file, line: line)
}

private func assertNil<T>(_ v: T?, _ msg: String = "", file: String = #file, line: Int = #line) {
    let desc = msg.isEmpty ? "expected nil, got \(v.map { "\($0)" } ?? "nil")" : msg
    expect(v == nil, desc, file: file, line: line)
}

private func section(_ name: String) {
    print("  [\(name)]")
}

// MARK: - normalizeSSID tests

private func testNormalizeSSID() {
    section("normalizeSSID")

    // Smart quotes replaced
    let input1 = "\u{2018}MyNetwork\u{2019}"
    let result1 = WiFiSSIDResolver.normalizeSSID(input1)
    assertEqual(result1, "'MyNetwork'", "smart quotes → ASCII apostrophe")
    assertFalse(result1.contains("\u{2018}"), "no left smart quote")
    assertFalse(result1.contains("\u{2019}"), "no right smart quote")

    // Whitespace trimmed
    assertEqual(WiFiSSIDResolver.normalizeSSID("  hello  "), "hello", "trim spaces")
    assertEqual(WiFiSSIDResolver.normalizeSSID("\nhello\n"), "hello", "trim newlines")
    assertEqual(WiFiSSIDResolver.normalizeSSID("\t hello \t"), "hello", "trim tabs+spaces")

    // Plain string unchanged
    assertEqual(WiFiSSIDResolver.normalizeSSID("MyWiFi"), "MyWiFi")

    // Empty string
    assertEqual(WiFiSSIDResolver.normalizeSSID(""), "")

    // Combined smart quotes + whitespace
    let input2 = "  \u{2018}Caf\u{00e9}\u{2019}  "
    assertEqual(WiFiSSIDResolver.normalizeSSID(input2), "'Caf\u{00e9}'")
}

// MARK: - ipv4ToData tests

private func testIPv4ToData() {
    section("ipv4ToData")

    // Valid IP
    if let data = WiFiSSIDResolver.ipv4ToData("192.168.1.1") {
        assertEqual(data.count, 4, "4 bytes")
        let bytes = [UInt8](data)
        assertEqual(bytes[0], 192); assertEqual(bytes[1], 168)
        assertEqual(bytes[2], 1);   assertEqual(bytes[3], 1)
    } else {
        expect(false, "192.168.1.1 should parse")
    }

    // Loopback
    if let data = WiFiSSIDResolver.ipv4ToData("127.0.0.1") {
        assertEqual([UInt8](data), [127, 0, 0, 1])
    } else {
        expect(false, "127.0.0.1 should parse")
    }

    // Zero
    if let data = WiFiSSIDResolver.ipv4ToData("0.0.0.0") {
        assertEqual([UInt8](data), [0, 0, 0, 0])
    } else {
        expect(false, "0.0.0.0 should parse")
    }

    // Broadcast
    if let data = WiFiSSIDResolver.ipv4ToData("255.255.255.255") {
        assertEqual([UInt8](data), [255, 255, 255, 255])
    } else {
        expect(false, "255.255.255.255 should parse")
    }

    // Invalid IPs
    assertNil(WiFiSSIDResolver.ipv4ToData("not.an.ip"), "not.an.ip")
    assertNil(WiFiSSIDResolver.ipv4ToData(""), "empty string")
    assertNil(WiFiSSIDResolver.ipv4ToData("999.999.999.999"), "999s")
}

// MARK: - isWiFiInterface tests

private func testIsWiFiInterface() {
    section("isWiFiInterface")

    // en0 — typically Wi-Fi; we just verify it returns a Bool without crashing
    let _ = WiFiSSIDResolver.isWiFiInterface("en0")
    expect(true, "en0 call did not crash")

    // lo0 is not Wi-Fi
    assertFalse(WiFiSSIDResolver.isWiFiInterface("lo0"), "lo0 is not Wi-Fi")

    // Nonexistent interface
    assertFalse(WiFiSSIDResolver.isWiFiInterface("fakeif99"), "fakeif99 is not Wi-Fi")
}

// MARK: - isTunnelInterface tests

private func testIsTunnelInterface() {
    section("isTunnelInterface")

    assertTrue(WiFiSSIDResolver.isTunnelInterface("utun0"), "utun0 is tunnel")
    assertTrue(WiFiSSIDResolver.isTunnelInterface("utun6"), "utun6 is tunnel")
    assertFalse(WiFiSSIDResolver.isTunnelInterface("en0"), "en0 is not tunnel")
    assertFalse(WiFiSSIDResolver.isTunnelInterface("lo0"), "lo0 is not tunnel")
    assertFalse(WiFiSSIDResolver.isTunnelInterface(""), "empty is not tunnel")
}

// MARK: - getSSID integration tests

private func testGetSSID() {
    section("getSSID (live)")

    // Default call: must not crash; result is nil or non-empty
    let r1 = WiFiSSIDResolver.getSSID()
    assertTrue(r1 == nil || !r1!.isEmpty,
               "getSSID() returned empty string, expected nil or non-empty")

    // Strict mode
    let r2 = WiFiSSIDResolver.getSSID(preferIface: "en0", strictInterface: true)
    assertTrue(r2 == nil || !r2!.isEmpty,
               "getSSID(strict) returned empty string")
}

// MARK: - verboseSnapshot tests

private func testVerboseSnapshot() {
    section("verboseSnapshot")

    let snap = WiFiSSIDResolver.verboseSnapshot(preferIface: "en0", strictInterface: false)
    assertTrue(snap.contains("diagnostics"), "contains 'diagnostics'")
    assertTrue(snap.contains("Service Order"), "contains 'Service Order'")
    assertTrue(snap.contains("Active Wi-Fi"), "contains 'Active Wi-Fi'")

    // Strict mode
    let snap2 = WiFiSSIDResolver.verboseSnapshot(preferIface: "en0", strictInterface: true)
    let hasStrict = snap2.contains("Strict interface") || snap2.contains("Mapping")
    assertTrue(hasStrict, "strict mode shows 'Strict interface' or 'Mapping'")
}

// MARK: - Entry point

#if TESTING
@main
struct TestRunner {
    static func main() {
        print("── Unit tests ──")
        testNormalizeSSID()
        testIPv4ToData()
        testIsWiFiInterface()
        testIsTunnelInterface()
        testGetSSID()
        testVerboseSnapshot()

        print("")
        if _totalFail > 0 {
            print("\(_totalRun) checks, \(_totalFail) FAILED")
            exit(1)
        } else {
            print("\(_totalRun) checks, all passed")
        }
    }
}
#endif
