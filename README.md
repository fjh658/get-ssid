# get-ssid — Read Wi‑Fi SSID on macOS *without* Location (TCC)

**English** | [中文](./README_zh.md)

> 🧩 **Goal**: Print the current Wi‑Fi SSID on macOS 11+ (incl. “macOS 26”) **without** Location permission (TCC), and without Location‑gated CLIs.

---

## Overview ✨

On modern macOS, many SSID sources are gated by **Location** permission (TCC). With Location **off**, tools will hide or refuse the SSID. **get‑ssid** first tries non-Location CoreWLAN/IORegistry paths, then (if needed) infers the SSID by correlating the current network environment with the **system known‑networks** database.

**Highlights**  
- No CoreLocation, no external commands.  
- Uses CoreWLAN (live/profile), IORegistry, and SystemConfiguration (DHCP/Router).  
- known‑networks plist is a last resort and may require `sudo` if unreadable.

---

## Why the usual tools fail 🔎

### 1) `airport` (legacy Apple80211 tool)
```bash
/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -i

zsh: no such file or directory: /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport
```
- ❌ **Key issue**: The legacy path/binary is removed or relocated on modern macOS; even where an `airport` wrapper exists, SSID disclosure is typically gated by Location/TCC.

### 2) `networksetup -getairportnetwork en0`
```bash
/usr/sbin/networksetup -getairportnetwork en0
You are not associated with an AirPort network.
```
- ❌ **Key issue**: With Location off, the underlying API refuses to disclose association/SSID and returns a generic *not associated*, even when you are connected.

### 3) `wdutil info` (Wi‑Fi diagnostics)
```bash
sudo wdutil info
…
WIFI
  Interface Name : en0
  Power          : On
  Op Mode        : STA
  SSID           : <redacted>
  BSSID          : <redacted>
```
- ❌ **Key issue**: Diagnostic tooling **redacts** SSID without Location consent.

### 4) `system_profiler SPAirPortDataType -json`
```bash
/usr/sbin/system_profiler SPAirPortDataType -detailLevel basic -json
{
  "SPAirPortDataType" : [
    {
      "spairport_airport_interfaces" : [
        {
          "_name" : "en0",
          …
          "spairport_current_network_information" : {
            "_name" : "<redacted>"
```
- ❌ **Key issue**: `system_profiler` respects privacy defaults and **redacts** the SSID when Location is off.

---

## How it works 🧠

- **Default path (current macOS):**  
  1) CoreWLAN live association (`CWInterface.ssid()`) when available.  
  2) CoreWLAN profile fallback (`networkProfiles`).  
  3) Interface-scoped IORegistry SSID keys (`IO80211SSID_STR` / `IO80211SSID` / `SSID_STR`).  
  4) Last resort: correlate SystemConfiguration (DHCP/Router) with `/Library/Preferences/com.apple.wifi.known-networks.plist`.
- **known-networks stage only:** score candidates and break ties by **most recent association timestamp**.
- **When CoreWLAN is unavailable:** direct fallback to interface-scoped IORegistry lookup.
- Priority policy: keep default execution on non-privileged paths; use known-networks only as a compatibility fallback when needed.

---

## Build ⚙️

> Requires Xcode Command Line Tools; source file: `get_ssid.swift`

```bash
# Recommended: build universal binary via Makefile
make universal

# Run tests (unit + integration)
make test
```

---

## 🍺 Homebrew Tap Install

Homebrew install uses the prebuilt package in `dist/` and does not compile on the end-user machine.

Tap this repository locally:

```bash
brew tap fjh658/get-ssid /path/to/get-ssid
brew install get-ssid
```

Install from GitHub tap:

```bash
brew tap fjh658/get-ssid https://github.com/fjh658/get-ssid.git
brew install get-ssid
```

Refresh prebuilt package before release:

```bash
make package
```

`make package` also refreshes `Formula/get-ssid.rb` from `Formula/get-ssid.rb.tmpl`, injecting the current version (from `get_ssid.swift`) and tarball `sha256`.

---

## Install & Privileges 📦

For Homebrew installs, run `get-ssid` directly.
As long as current macOS API behavior remains unchanged, `sudo` is not required.

Only when you explicitly need known‑networks fallback and the system plist is unreadable to the current user, retry once with `sudo`:

```bash
get-ssid en0
# If fallback is needed:
sudo get-ssid en0
```

---

## Usage 🚀

```bash
# Default: use the active Wi-Fi service
get-ssid
# MyWiFi-5G

# Strictly bind to a specific interface (e.g., en0)
get-ssid en0
# MyWiFi-5G

# Help / Version
get-ssid --help
get-ssid --version
```

**Behavior**  
- Explicit non‑Wi‑Fi interface in strict mode exits `2` with `error: interface '<iface>' is not a Wi-Fi interface (strict mode)`.  
- A Wi‑Fi interface that is not associated prints `Unknown (not associated)` and exits `0` (not an error).  
- Non‑existent interface → exit `3`.  
- Usage error → exit `2`.

**Exit codes**
| Code | Meaning                               |
|-----:|----------------------------------------|
| 0    | Success (incl. “Unknown …”)           |
| 1    | Internal safety failure                |
| 2    | Usage error                            |
| 3    | Interface not found (when explicit)    |

---

## Security & Privacy 🔐

- Open the system plist with **`O_NOFOLLOW`** and verify ownership; **drop effective privileges** immediately after reading.  
- Never parse untrusted paths; prefer hardcoded absolute paths.  
- Consider sandboxing when distributing.

---

## Limitations ⚠️

- These limits apply only when `networkProfiles`/IORegistry did not yield an SSID and the tool falls back to known‑networks correlation.  
- In that fallback stage, if the network was **never saved** to system known‑networks, or DHCP/Router signals are ambiguous, inference may fail.  
- Apple may change plist formats/fields in future releases, which would affect this fallback path.

---

## License 📝

MIT — keep copyright and license.

---

## Acknowledgements 🙏

- Apple SystemConfiguration, IOKit, and the macOS Wi‑Fi stack.  
- Community research on Wi‑Fi diagnostics & known‑networks internals.
