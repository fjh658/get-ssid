# get-ssid — Read Wi‑Fi SSID on macOS *without* Location (TCC)

**English** | [中文](./README_zh.md)

> 🧩 **Goal**: Print the current Wi‑Fi SSID on macOS 11+ (incl. “macOS 26”) **without** CoreLocation/CoreWLAN or Location‑gated CLIs.

---

## Overview ✨

On modern macOS, many SSID sources are gated by **Location** permission (TCC). With Location **off**, tools will hide or refuse the SSID. **get‑ssid** avoids those APIs and instead **infers** the SSID by correlating the current network environment with the **system known‑networks** database.

**Highlights**  
- No CoreLocation, no CoreWLAN, no external commands.  
- Uses SystemConfiguration (DHCP/Router) + known‑networks plist; optional channel from IORegistry for tie‑breaking.  
- Requires root to read the system plist → run with **`sudo`** or install once as **setuid**.

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

- **macOS ≥ 11** (incl. “macOS 26”):  
  1) Read system‑scope `/Library/Preferences/com.apple.wifi.known-networks.plist`.  
  2) Capture current environment from **SystemConfiguration**:  
     - DHCP **ServerIdentifier** (strong)  
     - IPv4 **Router** in `IPv4NetworkSignature` (medium)  
     - Optional **channel** via **IORegistry** (bonus)  
  3) Score candidates; break ties by **most recent association timestamp**; return SSID.
- **macOS ≤ 10**: Fallback to IORegistry keys (`IO80211SSID_STR` / `SSID_STR`) when available.

---

## Build ⚙️

> Requires Xcode Command Line Tools; source file: `get_ssid.swift`

```bash
# x86_64 slice (min 10.13)
xcrun swiftc -parse-as-library -O   -target x86_64-apple-macos10.13   -o /tmp/get-ssid-x86_64 get_ssid.swift

# arm64 slice (min 11.0)
xcrun swiftc -parse-as-library -O   -target arm64-apple-macos11.0   -o /tmp/get-ssid-arm64 get_ssid.swift

# merge into a universal binary
lipo -create -output ./get-ssid   /tmp/get-ssid-x86_64 /tmp/get-ssid-arm64

# If Gatekeeper quarantines the file (optional)
xattr -dr com.apple.quarantine ./get-ssid
```

---

## Install & Privileges 📦

Reading the system plist **requires root**. Pick **one**:

### Option A — Run with `sudo` each time *(simple, recommended)*
```bash
sudo ./get-ssid en0
# MyWiFi-5G
```

### Option B — Grant setuid once *(advanced; use with care)*
> ⚠️ Increases attack surface. Keep the binary minimal, audited, immutable, and in a fixed path.

**Minimal (as requested):**
```bash
sudo chown root ./get-ssid && sudo chmod +s ./get-ssid
./get-ssid en0
# MyWiFi-5G
```

**Preferred (install to /usr/local/bin):**
```bash
sudo install -m 0755 get-ssid /usr/local/bin/get-ssid
sudo chown root:wheel /usr/local/bin/get-ssid
sudo chmod u+s /usr/local/bin/get-ssid

get-ssid en0
# MyWiFi-5G
```

---

## Usage 🚀

```bash
# Default: use the primary data interface (Global/IPv4)
sudo ./get-ssid
# MyWiFi-5G

# Strictly bind to a specific interface (e.g., en0)
sudo ./get-ssid en0
# MyWiFi-5G

# Help / Version
./get-ssid --help
./get-ssid --version
```

**Behavior**  
- Passing a *wired* interface prints `Unknown (not associated)` and exits `0` (not an error).  
- Non‑existent interface → exit `3`.  
- Usage error → exit `2`.

**Exit codes**
| Code | Meaning                               |
|-----:|----------------------------------------|
| 0    | Success (incl. “Unknown …”)           |
| 2    | Usage error                            |
| 3    | Interface not found (when explicit)    |

---

## Security & Privacy 🔐

- Open the system plist with **`O_NOFOLLOW`** and verify ownership; **drop effective privileges** immediately after reading.  
- Never parse untrusted paths; prefer hardcoded absolute paths.  
- Consider sandboxing when distributing.

---

## Limitations ⚠️

- If the network was **never saved** to system known‑networks, or DHCP/Router signals are ambiguous, inference may fail.  
- Apple may change plist formats/fields in future releases.

---

## License 📝

MIT — keep copyright and license.

---

## Acknowledgements 🙏

- Apple SystemConfiguration, IOKit, and the macOS Wi‑Fi stack.  
- Community research on Wi‑Fi diagnostics & known‑networks internals.
