# Plan: Add Test Coverage

## Background

get-ssid is a single-file Swift CLI project with zero test coverage. Two layers of tests are needed:
- **Unit tests**: cover pure-function logic inside `WiFiSSIDResolver`
- **Shell script**: cover CLI behavior (black-box integration tests)

Key challenge: the source uses the `@main` attribute, which cannot coexist with a test entry point in the same compilation unit.

## Approach

### 1. Source changes — `get_ssid.swift`

Use conditional compilation `#if !TESTING` to skip `@main`, allowing the test binary to define its own entry point.

Only promote pure functions that unit tests call directly from `private` to `internal`:

| Symbol | Before | After | Reason |
|--------|--------|-------|--------|
| `@main` | unconditional | `#if !TESTING` | resolve test entry-point conflict |
| `normalizeSSID` | `private` | `internal` | pure function, worth unit testing |
| `ipv4ToData` | `private` | `internal` | pure function, worth unit testing |
| `isTunnelInterface` | `private` | `internal` | pure function, worth unit testing |

**Left untouched**: `NetEnv`, `parseArgs`, `toolName`, `version`, `Mode`, `interfaceExists`, etc. remain `private` — CLI behavior is covered by shell integration tests; no need to widen visibility for that.

### 2. Unit tests — `tests/get_ssid_tests.swift`

Does not depend on the XCTest framework (the Swift overlay for XCTest has compatibility issues when compiling with bare `swiftc`). Uses a lightweight custom assertion harness instead.

Build command:
```
xcrun swiftc -parse-as-library -DTESTING \
  -target arm64-apple-macos11.0 \
  get_ssid.swift tests/get_ssid_tests.swift \
  -o /tmp/get-ssid-tests
/tmp/get-ssid-tests
```

Test cases:
- `normalizeSSID`: smart-quote replacement, whitespace trimming, empty string, combined
- `ipv4ToData`: valid IPs (192.168.1.1, 127.0.0.1, 0.0.0.0, 255.255.255.255), invalid IPs
- `isWiFiInterface`: lo0 (not Wi-Fi), nonexistent interface
- `isTunnelInterface`: utun0/utun6 (yes), en0/lo0/empty (no)
- `getSSID()`: default params and strict mode (live-environment integration — verify no crash, returns nil or non-empty)
- `verboseSnapshot()`: output contains `diagnostics`, `Service Order`, `Active Wi-Fi`; strict mode contains `Strict interface` or `Mapping`

### 3. Shell integration tests — `tests/test_cli.sh`

After building the normal binary, verify CLI behavior black-box:

| Test | Expected |
|------|----------|
| `--help` / `-h` | exit 0, stdout contains `USAGE:` |
| `--version` / `-V` | exit 0, stdout contains version number pattern |
| no arguments | exit 0, stdout non-empty |
| `-v` verbose | exit 0, stderr contains `diagnostics` |
| `--no-color -v` | exit 0, stderr has no ANSI escape codes |
| nonexistent interface | exit 3 |
| `lo0` (non-Wi-Fi) | exit 2 |
| unknown option | exit 2 |
| extra positional args | exit 2 |
| `-- en0` separator | exit 0 |

### 4. Makefile integration

Add a `make test` target that runs sequentially:
1. Compile the `-DTESTING` test binary and run it
2. Build the normal universal binary
3. Run shell integration tests

### File manifest

| File | Action |
|------|--------|
| `get_ssid.swift` | modify: conditional-compile `@main`, promote 3 pure functions |
| `tests/get_ssid_tests.swift` | new: unit tests |
| `tests/test_cli.sh` | new: shell integration tests |
| `Makefile` | modify: add `test` target |
| `README.md` / `README_zh.md` | modify: add `make test` to Build section |

### Verification

```bash
make test
```

Expected: all unit tests PASS + all shell tests PASS.
