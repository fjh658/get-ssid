//
// get_ssid.swift
//
// Build (universal macOS binary):
//   # x86_64 slice (min 10.13)
//   xcrun swiftc -parse-as-library -O \
//     -target x86_64-apple-macos10.13 \
//     -o /tmp/get-ssid-x86_64 get_ssid.swift
//
//   # arm64 slice (min 11.0)
//   xcrun swiftc -parse-as-library -O \
//     -target arm64-apple-macos11.0 \
//     -o /tmp/get-ssid-arm64 get_ssid.swift
//
//   # merge into universal
//   lipo -create -output ./get-ssid \
//     /tmp/get-ssid-x86_64 /tmp/get-ssid-arm64
//
// Optional (to read the system plist without sudo; binaries only):
//   sudo chown root $(which get-ssid) && sudo chmod +s $(which get-ssid)
//
// -----------------------------------------------------------------------------
// Tool: get-ssid
// Version: 1.0.0
//
// PURPOSE
//   Print the current Wi-Fi SSID on macOS without requiring Location/TCC.
//   • No CoreLocation, no CoreWLAN, no external commands.
//
// HOW IT WORKS
//   • macOS ≥ 11 (Big Sur and later, incl. 15/26):
//       - Reads /Library/Preferences/com.apple.wifi.known-networks.plist
//         (system scope; typically needs root or a setuid binary).
//       - Correlates the current network environment from SystemConfiguration:
//           ▸ DHCP ServerIdentifier (strong; exact match)
//           ▸ Router IPv4 in IPv4NetworkSignature (medium)
//           ▸ Optional channel from IOKit/IORegistry (bonus)
//       - Picks the highest-score candidate; ties broken by most recent timestamp.
//   • macOS ≤ 10:
//       - Falls back to IORegistry keys (IO80211SSID_STR / IO80211SSID / SSID_STR).
//         (On modern macOS these values may be redacted.)
//
// INTERFACE SELECTION & STRICTNESS
//   • No iface argument → use the primary data interface (Global/IPv4).
//   • Explicit iface argument (e.g. `get-ssid en4`) → strict mode:
//       - Bind the environment to the Service of that iface only.
//       - If that iface is not Wi-Fi or has no active IPv4/DHCP state,
//         return “Unknown (not associated)” rather than falling back to the primary iface.
//       - If the iface name does not exist, print an error to stderr and exit 3.
//   • This design makes the CLI predictable and script-friendly.
//
// WIRED INTERFACES
//   • If you pass a wired interface (e.g., Ethernet) that exists, the tool prints
//     “Unknown (not associated)” and exits 0. This is not a usage error—the iface
//     simply isn’t Wi-Fi.
//
// EXIT CODES
//   0: success (including “Unknown (not associated)”)
//   2: usage error
//   3: interface not found (when iface explicitly provided)
//
// SECURITY
//   • The system plist is opened with O_NOFOLLOW and ownership checks.
//   • Effective privileges are dropped immediately after reading the file.
//
// -----------------------------------------------------------------------------

import Foundation
import SystemConfiguration
import IOKit
import Darwin

// MARK: - Resolver

public final class WiFiSSIDResolver {

    // MARK: Public API

    /// Resolve current SSID without Location/TCC.
    /// - Parameters:
    ///   - preferIface: preferred BSD name (default "en0").
    ///   - strictInterface: when true, bind environment to the given iface’s Service only;
    ///                      when false, use the primary data interface.
    /// - Returns: SSID string, or nil if not resolvable.
    public static func getSSID(preferIface: String = "en0",
                               strictInterface: Bool = false) -> String? {
        if osMajor() >= 11 {
            if strictInterface && !isWiFiInterface(preferIface) {
                // Explicit non-Wi-Fi iface → treat as not associated (no fallback).
                return nil
            }
            if let s = inferSSIDFromKnownNetworks(preferIface: preferIface,
                                                  lockToIface: strictInterface),
               !s.isEmpty { return s }

            if strictInterface {
                // In strict mode, avoid global IORegistry search; limit to iface node.
                if let s = ssidFromIORegistry_ifaceOnly(iface: preferIface), !s.isEmpty { return s }
                return nil
            }

            // Non-strict: allow legacy IORegistry fallback.
            if let s = ssidFromIORegistry(iface: preferIface), !s.isEmpty { return s }
            return nil
        } else {
            // Older systems: IORegistry path.
            return ssidFromIORegistry(iface: preferIface)
        }
    }

    // MARK: Common utils

    @inline(__always) private static func osMajor() -> Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    /// Use a single port that does not trigger availability warnings.
    @inline(__always) private static func ioPort() -> mach_port_t {
        mach_port_t(MACH_PORT_NULL)
    }

    @inline(__always) private static func normalizeSSID(_ s: String) -> String {
        s.replacingOccurrences(of: "’", with: "'")
         .replacingOccurrences(of: "‘", with: "'")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ipv4ToData(_ dotted: String) -> Data? {
        var a = in_addr()
        if inet_aton(dotted, &a) == 1 {
            var n = a.s_addr // network byte order
            return Data(bytes: &n, count: MemoryLayout<in_addr_t>.size)
        }
        return nil
    }

    // MARK: SystemConfiguration (Network environment)

    private struct NetEnv {
        var iface: String
        var serviceID: String?
        var routerIPv4: String?
        var dhcpServerIPv4: String?
    }

    private static func scCopyDict(_ store: SCDynamicStore, _ key: String) -> [String: Any]? {
        SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }

    /// Enumerate dynamic store keys to find the ServiceID for a given iface.
    /// Looks for `State:/Network/Service/<SID>/IPv4` whose `InterfaceName == iface`.
    private static func findServiceID(for iface: String,
                                      store: SCDynamicStore) -> String? {
        let pattern = "State:/Network/Service/.*/IPv4" as CFString
        guard let keys = SCDynamicStoreCopyKeyList(store, pattern) as? [String] else { return nil }
        for key in keys {
            if let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let name = dict["InterfaceName"] as? String, name == iface {
                if let r1 = key.range(of: "Service/"),
                   let r2 = key.range(of: "/IPv4"),
                   r1.upperBound < r2.lowerBound {
                    return String(key[r1.upperBound..<r2.lowerBound])
                }
            }
        }
        return nil
    }

    /// Read current network environment. When `lockToIface` is true, bind to the
    /// Service associated with `preferIface`; otherwise use the global primary.
    private static func readDynamicEnv(preferIface: String,
                                       lockToIface: Bool) -> NetEnv {
        var env = NetEnv(iface: preferIface, serviceID: nil, routerIPv4: nil, dhcpServerIPv4: nil)
        guard let store = SCDynamicStoreCreate(kCFAllocatorDefault, "ssid-env" as CFString, nil, nil) else {
            return env
        }

        if lockToIface {
            if let sid = findServiceID(for: preferIface, store: store) {
                env.iface = preferIface
                env.serviceID = sid
            } else {
                // No active Service for this iface → leave env empty; inference will fail gracefully.
                return env
            }
        } else {
            if let g = scCopyDict(store, "State:/Network/Global/IPv4") {
                if let pi = g["PrimaryInterface"] as? String { env.iface = pi }
                env.serviceID = g["PrimaryService"] as? String
                if let r = g["Router"] as? String { env.routerIPv4 = r }
            }
        }

        guard let sid = env.serviceID else { return env }

        func parseDHCP(_ dict: [String: Any]) -> String? {
            if let s = dict["ServerIdentifier"] as? String { return s }
            if let d = dict["ServerIdentifier"] as? Data, d.count == 4 {
                let b = [UInt8](d); return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
            }
            return nil
        }

        if let d = scCopyDict(store, "State:/Network/Service/\(sid)/DHCP"),
           let ip = parseDHCP(d) {
            env.dhcpServerIPv4 = ip
        } else if let d = scCopyDict(store, "State:/Network/Service/\(sid)/DHCPv4"),
                  let ip = parseDHCP(d) {
            env.dhcpServerIPv4 = ip
        }

        if env.routerIPv4 == nil,
           let v4 = scCopyDict(store, "State:/Network/Service/\(sid)/IPv4") {
            env.routerIPv4 = v4["Router"] as? String
        }

        return env
    }

    // Convenience overload kept for compatibility (non-strict).
    private static func readDynamicEnv(preferIface: String) -> NetEnv {
        readDynamicEnv(preferIface: preferIface, lockToIface: false)
    }

    // MARK: Detect Wi-Fi vs. non-Wi-Fi

    /// Determine whether a BSD interface is Wi-Fi using SystemConfiguration.
    private static func isWiFiInterface(_ iface: String) -> Bool {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return false }
        for intf in all {
            if let name = SCNetworkInterfaceGetBSDName(intf) as String?, name == iface {
                if let t = SCNetworkInterfaceGetInterfaceType(intf) as String? {
                    return t == (kSCNetworkInterfaceTypeIEEE80211 as String)
                }
            }
        }
        return false
    }

    // MARK: IOKit / IORegistry (channel + SSID fallback)

    private static func ioFindServiceForBSDName(_ iface: String) -> io_registry_entry_t {
        guard let match = IOServiceMatching("IOService") as NSMutableDictionary? else { return 0 }
        match.setValue(["BSD Name": iface], forKey: "IOPropertyMatch")
        var it: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(ioPort(), match, &it)
        guard kr == KERN_SUCCESS, it != 0 else { return 0 }
        defer { IOObjectRelease(it) }
        return IOIteratorNext(it) // first
    }

    private static func copyProps(_ entry: io_registry_entry_t) -> NSDictionary? {
        var propsRef: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let p = propsRef?.takeRetainedValue() {
            return p as NSDictionary
        }
        return nil
    }

    private static func valueForKeys(in dict: NSDictionary, keys: [String]) -> Any? {
        for k in keys { if let v = dict[k] { return v } }
        return nil
    }

    private static func findPropOnEntryOrParents(_ entry: io_registry_entry_t, keys: [String]) -> Any? {
        var current: io_registry_entry_t = entry
        IOObjectRetain(current)
        while current != 0 {
            if let d = copyProps(current), let v = valueForKeys(in: d, keys: keys) {
                IOObjectRelease(current); return v
            }
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            if kr != KERN_SUCCESS || parent == 0 { break }
            current = parent
        }
        return nil
    }

    private static func findPropAnywhere(keys: [String]) -> Any? {
        var iter: io_iterator_t = 0
        let kr = IORegistryCreateIterator(ioPort(), kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iter)
        guard kr == KERN_SUCCESS, iter != 0 else { return nil }
        defer { IOObjectRelease(iter) }
        while true {
            let e = IOIteratorNext(iter); if e == 0 { break }
            if let d = copyProps(e), let v = valueForKeys(in: d, keys: keys) {
                IOObjectRelease(e); return v
            }
            IOObjectRelease(e)
        }
        return nil
    }

    private static func currentWiFiChannel(_ iface: String) -> Int? {
        let keys = ["IO80211Channel", "Channel"]
        let svc = ioFindServiceForBSDName(iface)
        if svc != 0 {
            defer { IOObjectRelease(svc) }
            if let v = findPropOnEntryOrParents(svc, keys: keys) {
                if let n = v as? NSNumber { return n.intValue }
                if let s = v as? String, let n = Int(s) { return n }
            }
        }
        if let v = findPropAnywhere(keys: keys) {
            if let n = v as? NSNumber { return n.intValue }
            if let s = v as? String, let n = Int(s) { return n }
        }
        return nil
    }

    /// IORegistry lookup limited to the iface node and its parents.
    private static func ssidFromIORegistry_ifaceOnly(iface: String) -> String? {
        let keys = ["IO80211SSID_STR", "IO80211SSID", "SSID_STR"]
        let svc = ioFindServiceForBSDName(iface)
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        if let v = findPropOnEntryOrParents(svc, keys: keys) {
            if let s = v as? String, !s.isEmpty, s != "<SSID Redacted>" { return normalizeSSID(s) }
            if let d = v as? Data, !d.isEmpty,
               let s = String(data: d, encoding: .utf8), !s.isEmpty, s != "<SSID Redacted>" {
                return normalizeSSID(s)
            }
        }
        return nil
    }

    /// IORegistry lookup that also allows a global plane scan as a last resort.
    private static func ssidFromIORegistry(iface: String) -> String? {
        if let s = ssidFromIORegistry_ifaceOnly(iface: iface) { return s }
        let keys = ["IO80211SSID_STR", "IO80211SSID", "SSID_STR"]
        if let v = findPropAnywhere(keys: keys) {
            if let s = v as? String, !s.isEmpty, s != "<SSID Redacted>" { return normalizeSSID(s) }
            if let d = v as? Data, !d.isEmpty,
               let s = String(data: d, encoding: .utf8), !s.isEmpty, s != "<SSID Redacted>" {
                return normalizeSSID(s)
            }
        }
        return nil
    }

    // MARK: Known-networks inference (macOS ≥ 11)

    /// Read /Library/Preferences/com.apple.wifi.known-networks.plist safely.
    private static func secureReadKnownNetworks() -> Data? {
        let path = "/Library/Preferences/com.apple.wifi.known-networks.plist"
        let O_CLOEXEC = Int32(0x01000000), O_NOFOLLOW = Int32(0x00000100)
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { return nil }
        defer { close(fd) }

        var st = stat()
        if fstat(fd, &st) != 0 { return nil }
        if (st.st_mode & S_IFMT) != S_IFREG || st.st_uid != 0 { return nil }

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n == 0 { break }
            if n < 0 { return nil }
            out.append(buf, count: n)
        }
        // Drop effective privileges ASAP.
        _ = setgid(getgid()); _ = setuid(getuid())
        return out
    }

    /// Inference pipeline using known-networks plist and current environment.
    private static func inferSSIDFromKnownNetworks(preferIface: String,
                                                   lockToIface: Bool) -> String? {
        let env = readDynamicEnv(preferIface: preferIface, lockToIface: lockToIface)
        let iface = env.iface
        let curChannel = currentWiFiChannel(iface)
        let dhcpPacked = env.dhcpServerIPv4.flatMap(ipv4ToData)
        let routerIP = env.routerIPv4

        guard let data = secureReadKnownNetworks() else { return nil }
        var fmt = PropertyListSerialization.PropertyListFormat.binary
        guard let any = try? PropertyListSerialization.propertyList(from: data, options: [], format: &fmt),
              let dict = any as? [String: Any] else { return nil }

        struct Cand { let score: Double; let ts: Date; let ssid: String }
        var cands: [Cand] = []

        for (k, vAny) in dict {
            guard k.hasPrefix("wifi.network.ssid."), let v = vAny as? [String: Any] else { continue }

            var base: Double = 0.0
            var bestBSS: [String: Any]? = nil

            // A) DHCP ServerIdentifier exact match (strong)
            if let target = dhcpPacked, let bssList = v["BSSList"] as? [[String: Any]] {
                for b in bssList {
                    if let raw = b["DHCPServerID"] as? Data, raw == target {
                        base = 0.85; bestBSS = b; break
                    }
                }
            }

            // B) Router IPv4 in IPv4NetworkSignature (medium)
            if base == 0.0, let rip = routerIP, !rip.isEmpty {
                if let top = v["IPv4NetworkSignature"] as? String,
                   top.contains("IPv4.Router=\(rip)") {
                    base = 0.70
                }
                if base == 0.0, let bssList = v["BSSList"] as? [[String: Any]] {
                    for b in bssList {
                        if let s = b["IPv4NetworkSignature"] as? String,
                           s.contains("IPv4.Router=\(rip)") {
                            base = 0.72; bestBSS = b; break
                        }
                    }
                }
            }

            if base > 0.0 {
                // Channel bonus
                if let ch = curChannel, let b = bestBSS, let bch = b["Channel"] as? Int, bch == ch {
                    base += 0.05
                }
                let final = min(base, 1.0)

                // Timestamp tie-break (LastAssociatedAt / UpdatedAt)
                var ts = Date(timeIntervalSince1970: 0)
                if let b = bestBSS, let lad = b["LastAssociatedAt"] as? Date {
                    ts = lad
                } else if let bssList = v["BSSList"] as? [[String: Any]] {
                    for b in bssList {
                        if let lad = b["LastAssociatedAt"] as? Date, lad > ts { ts = lad }
                    }
                }
                if ts == Date(timeIntervalSince1970: 0), let upd = v["UpdatedAt"] as? Date {
                    ts = upd
                }

                // Decode SSID
                var ssid = ""
                if let s = v["SSID"] as? String {
                    ssid = s
                } else if let d = v["SSID"] as? Data {
                    ssid = String(data: d, encoding: .utf8) ?? d.map { String(format:"%02x", $0) }.joined()
                }
                ssid = normalizeSSID(ssid)

                cands.append(Cand(score: final, ts: ts, ssid: ssid))
            }
        }

        guard !cands.isEmpty else { return nil }
        cands.sort { ($0.score, $0.ts) > ($1.score, $1.ts) }
        return cands.first?.ssid
    }
}

// MARK: - CLI

@main
struct GetSSIDCLI {
    private static let toolName = "get-ssid"
    private static let version  = "1.0.0"

    static func main() {
        let (iface, mode, ifaceWasExplicit) = parseArgs()
        switch mode {
        case .help:
            printHelp()
        case .version:
            print("\(toolName) \(version)")
        case .run:
            if ifaceWasExplicit && !interfaceExists(iface) {
                fputs("error: interface '\(iface)' not found\n", stderr)
                exit(3)
            }
            let ssid = WiFiSSIDResolver.getSSID(preferIface: iface,
                                                strictInterface: ifaceWasExplicit)
                      ?? "Unknown (not associated)"
            print(ssid)
        }
    }

    // Interface existence check via getifaddrs (no external commands).
    private static func interfaceExists(_ name: String) -> Bool {
        var ptr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ptr) == 0, let head = ptr else { return false }
        defer { freeifaddrs(ptr) }
        var p: UnsafeMutablePointer<ifaddrs>? = head
        while let cur = p {
            if let cName = cur.pointee.ifa_name, String(cString: cName) == name {
                return true
            }
            p = cur.pointee.ifa_next
        }
        return false
    }

    // Argument parsing
    private enum Mode { case run, help, version }
    private static func parseArgs() -> (iface: String, mode: Mode, explicit: Bool) {
        let argv = Array(CommandLine.arguments.dropFirst())
        var iface: String? = nil
        var mode: Mode = .run
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "--" {
                let rest = argv.dropFirst(i+1)
                if let first = rest.first, iface == nil { iface = first }
                if rest.count > 1 { fail("too many positional arguments") }
                break
            } else if a == "-h" || a == "--help" {
                mode = .help
            } else if a == "-V" || a == "--version" {
                mode = .version
            } else if a.hasPrefix("-") {
                fail("unknown option: \(a)")
            } else {
                if iface == nil { iface = a } else { fail("too many positional arguments") }
            }
            i += 1
        }
        let final = iface ?? "en0"
        return (final, mode, iface != nil)
    }

    private static func printHelp() {
        print("""
        \(toolName) — print current Wi-Fi SSID without Location permission

        USAGE:
          \(toolName) [options] [iface]

        OPTIONS:
          -h, --help         Show this help and exit
          -V, --version      Show version and exit

        ARGS:
          iface              BSD interface name (default: en0)

        EXIT CODES:
          0  success (including "Unknown (not associated)")
          2  usage error
          3  interface not found (when iface explicitly provided)

        NOTES:
          • macOS ≥ 11: correlates DHCP/Router/Channel with the system known-networks database:
              /Library/Preferences/com.apple.wifi.known-networks.plist
            (reading that file usually requires root or a setuid binary).
          • macOS ≤ 10: falls back to IORegistry (IO80211SSID_STR / IO80211SSID / SSID_STR).
          • Explicit wired interfaces print "Unknown (not associated)"; this is not an error.
          • No CoreLocation / No CoreWLAN / No external commands.
        """)
    }

    @inline(__always) private static func fail(_ s: String) -> Never {
        fputs("error: \(s)\ntry '\(toolName) --help'\n", stderr)
        exit(2)
    }
}
