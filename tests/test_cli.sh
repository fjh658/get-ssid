#!/usr/bin/env bash
# test_cli.sh — black-box integration tests for the get-ssid CLI binary
#
# Usage:
#   tests/test_cli.sh [/path/to/get-ssid]
#
# If no path is given, defaults to ./get-ssid in the repo root.

set -euo pipefail

BIN="${1:-./get-ssid}"

if [[ ! -x "$BIN" ]]; then
    echo "FATAL: binary not found or not executable: $BIN" >&2
    exit 1
fi

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $1  — $2"; }

# ---------- --help ----------

out=$("$BIN" --help 2>&1) && rc=$? || rc=$?
if [[ $rc -eq 0 ]]; then
    if echo "$out" | grep -q "USAGE:"; then
        pass "--help exits 0 and contains USAGE:"
    else
        fail "--help content" "missing USAGE:"
    fi
else
    fail "--help exit code" "expected 0, got $rc"
fi

# -h alias
out=$("$BIN" -h 2>&1) && rc=$? || rc=$?
if [[ $rc -eq 0 ]] && echo "$out" | grep -q "USAGE:"; then
    pass "-h alias exits 0 and contains USAGE:"
else
    fail "-h alias" "exit=$rc"
fi

# ---------- --version ----------

out=$("$BIN" --version 2>&1) && rc=$? || rc=$?
if [[ $rc -eq 0 ]]; then
    if echo "$out" | grep -qE '[0-9]+\.[0-9]+'; then
        pass "--version exits 0 and contains version number"
    else
        fail "--version content" "no version pattern found in: $out"
    fi
else
    fail "--version exit code" "expected 0, got $rc"
fi

# -V alias
out=$("$BIN" -V 2>&1) && rc=$? || rc=$?
if [[ $rc -eq 0 ]] && echo "$out" | grep -qE '[0-9]+\.[0-9]+'; then
    pass "-V alias exits 0 and contains version number"
else
    fail "-V alias" "exit=$rc"
fi

# ---------- no arguments (default run) ----------

out=$("$BIN" 2>/dev/null) && rc=$? || rc=$?
if [[ $rc -eq 0 ]]; then
    if [[ -n "$out" ]]; then
        pass "no-args exits 0 with non-empty stdout"
    else
        fail "no-args stdout" "stdout is empty"
    fi
else
    fail "no-args exit code" "expected 0, got $rc"
fi

# ---------- -v verbose ----------

out=$("$BIN" -v 2>/tmp/get-ssid-test-stderr) && rc=$? || rc=$?
stderr_out=$(cat /tmp/get-ssid-test-stderr)
rm -f /tmp/get-ssid-test-stderr
if [[ $rc -eq 0 ]]; then
    if echo "$stderr_out" | grep -q "diagnostics"; then
        pass "-v exits 0 and stderr contains 'diagnostics'"
    else
        fail "-v stderr content" "missing 'diagnostics' in stderr"
    fi
else
    fail "-v exit code" "expected 0, got $rc"
fi

# ---------- --no-color ----------

out=$("$BIN" --no-color -v 2>/tmp/get-ssid-test-stderr) && rc=$? || rc=$?
stderr_out=$(cat /tmp/get-ssid-test-stderr)
rm -f /tmp/get-ssid-test-stderr
if [[ $rc -eq 0 ]]; then
    # ANSI escape is ESC[ — use $'\x1b\[' literal (macOS grep lacks -P)
    if echo "$stderr_out" | grep -q $'\x1b\['; then
        fail "--no-color" "stderr still contains ANSI escape codes"
    else
        pass "--no-color exits 0 and stderr has no ANSI escapes"
    fi
else
    fail "--no-color exit code" "expected 0, got $rc"
fi

# ---------- nonexistent interface → exit 3 ----------

"$BIN" "fakeif_nonexistent_xyz" >/dev/null 2>&1 && rc=$? || rc=$?
if [[ $rc -eq 3 ]]; then
    pass "nonexistent interface exits 3"
else
    fail "nonexistent interface exit code" "expected 3, got $rc"
fi

# ---------- non-Wi-Fi interface (lo0) → exit 2 ----------

"$BIN" "lo0" >/dev/null 2>&1 && rc=$? || rc=$?
if [[ $rc -eq 2 ]]; then
    pass "lo0 (non-Wi-Fi) exits 2"
else
    fail "lo0 exit code" "expected 2, got $rc"
fi

# ---------- unknown option → exit 2 ----------

"$BIN" "--bogus-flag" >/dev/null 2>&1 && rc=$? || rc=$?
if [[ $rc -eq 2 ]]; then
    pass "unknown option exits 2"
else
    fail "unknown option exit code" "expected 2, got $rc"
fi

# ---------- too many positional arguments → exit 2 ----------

"$BIN" "en0" "en1" >/dev/null 2>&1 && rc=$? || rc=$?
if [[ $rc -eq 2 ]]; then
    pass "too many positional args exits 2"
else
    fail "too many positional args exit code" "expected 2, got $rc"
fi

# ---------- -- separator with interface name → exit 0 ----------

out=$("$BIN" -- en0 2>/dev/null) && rc=$? || rc=$?
if [[ $rc -eq 0 ]]; then
    pass "'-- en0' exits 0"
else
    fail "'-- en0' exit code" "expected 0, got $rc"
fi

# ---------- summary ----------

TOTAL=$((PASS + FAIL))
echo ""
echo "$TOTAL tests, $FAIL failures"
exit $((FAIL > 0 ? 1 : 0))
