// get_ssid.swift — print current Wi-Fi SSID on macOS without Location (TCC)
// Version: 1.0.2
//
// This single-file tool prints the current Wi-Fi SSID on macOS **without**
// requiring CoreLocation permissions. It uses CoreWLAN if available, and
// otherwise falls back to IORegistry and the known-networks database as a last resort.
//
// ─────────────────────────────────────────────────────────────────────────────
// HOW IT WORKS (macOS ≥ 11)
// ─────────────────────────────────────────────────────────────────────────────
// 1) CoreWLAN live: if associated, return CWInterface.ssid()
// 2) CoreWLAN profiles: if associated and ssid() is redacted, use CWConfiguration.networkProfiles
// 3) IORegistry (iface-only): limited lookup of IO80211SSID_STR (may be redacted)
// 4) Known-networks plist (system scope) as a last resort if readable (may require root)
//
// For macOS ≤ 10, we fall back to IORegistry keys (IO80211SSID_STR / SSID_STR),
// which may be redacted on modern systems.
//
// ─────────────────────────────────────────────────────────────────────────────
// INTERFACE SELECTION (VPN-aware)
// ─────────────────────────────────────────────────────────────────────────────
// • No iface given → we prefer the *active Wi-Fi* service (IEEE80211 + IPv4 up).
//   If the global primary interface is a VPN/tunnel (utun*), we skip it and
//   still select the Wi-Fi service so the tool behaves like users expect.
// • Explicit iface given (e.g. `get-ssid utun6`) → strict mode: we bind to that
//   service only. If it’s a tunnel, we map it to the active Wi-Fi service.
//   A non-Wi-Fi iface is treated as a usage error (exit 2).
//
// ─────────────────────────────────────────────────────────────────────────────
// CLI
// ─────────────────────────────────────────────────────────────────────────────
//   get-ssid [options] [iface]
//
//   -h, --help       Show help
//   -V, --version    Show version
//   -v, --verbose    Print colored diagnostics to stderr (groups, names, order)
//   --no-color       Disable ANSI colors (or set NO_COLOR=1)
//
// Exit codes:
//   0  success (including “Unknown (not associated)”)
//   1  internal safety failure (e.g., privilege drop failed)
//   2  usage error
//   3  interface not found (when iface explicitly provided)
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
//   OR
//
//   make universal
//
// SECURITY NOTES
//   • The plist is opened with O_NOFOLLOW and owner checks.
//   • Effective privileges are dropped (setgid/setuid) immediately after read.
//    NOTE: reading this file normally requires root; if unreadable, this fallback is skipped.
//
// ─────────────────────────────────────────────────────────────────────────────

import Foundation
import SystemConfiguration
import IOKit
import Darwin
#if canImport(CoreWLAN)
import CoreWLAN
#endif

// MARK: - ANSI colors for -v

@inline(__always) private func isTTY(_ fd: Int32) -> Bool { return isatty(fd) != 0 }
fileprivate struct Ansi {
    static var enabled: Bool {
        if getenv("NO_COLOR") != nil { return false }
        return isTTY(STDERR_FILENO)
    }
    @inline(__always) static func wrap(_ s: String, _ code: String) -> String {
        enabled ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s
    }
    static func bold(_ s: String)   -> String { wrap(s, "1") }
    static func dim(_ s: String)    -> String { wrap(s, "2") }
    static func green(_ s: String)  -> String { wrap(s, "32") }
    static func yellow(_ s: String) -> String { wrap(s, "33") }
    static func blue(_ s: String)   -> String { wrap(s, "34") }
    static func magenta(_ s: String)-> String { wrap(s, "35") }
    static func cyan(_ s: String)   -> String { wrap(s, "36") }
}

// MARK: - Resolver

public final class WiFiSSIDResolver {

    // MARK: Public API

    /// Resolve the current SSID without Location/TCC.
    /// - Parameters:
    ///   - preferIface: preferred BSD name (default "en0").
    ///   - strictInterface: when true, bind inference to the given iface’s Service only;
    ///                      when false, prefer the active Wi-Fi service.
    /// - Returns: SSID string, or nil if not resolvable.
    public static func getSSID(preferIface: String = "en0",
                               strictInterface: Bool = false) -> String? {
        let env = readDynamicEnv(preferIface: preferIface, lockToIface: strictInterface)
#if canImport(CoreWLAN)
        // Prefer a CoreWLAN interface bound to the chosen BSD name; otherwise default.
        let client = CWWiFiClient.shared()
        let cw = strictInterface
            ? client.interface(withName: env.iface)
            : (client.interface(withName: env.iface) ?? client.interface())
        if let cw = cw {
            // Only operate when actually associated; otherwise return nil to surface
            // "Unknown (not associated)" at the CLI layer.
            if cwIsAssociated(cw) {
                if let ssid = cw.ssid(), !ssid.isEmpty {
                    return normalizeSSID(ssid)
                }
                // Design choice: prefer no-sudo runtime path first.
                // known-networks remains a privileged last resort for forward compatibility.
                if let s = ssidFromProfiles(cw) { return s }
                if let s = ssidFromIORegistry_ifaceOnly(iface: env.iface), !s.isEmpty { return s }
                // Final resort on modern macOS: known-networks inference if readable.
                if let s = inferSSIDFromKnownNetworks(env: env), !s.isEmpty {
                    return s
                }
                return nil
            } else {
                // Not associated: do not infer from profiles or plist.
                return nil
            }
        }
#endif
        // No CoreWLAN available: attempt an iface-only IORegistry lookup (may be redacted).
        return ssidFromIORegistry_ifaceOnly(iface: env.iface)
    }

    // MARK: Common utils

    /// Single IOKit port (avoid availability warnings).
    @inline(__always) private static func ioPort() -> mach_port_t {
        mach_port_t(MACH_PORT_NULL)
    }

    @inline(__always) static func normalizeSSID(_ s: String) -> String {
        s.replacingOccurrences(of: "’", with: "'")
         .replacingOccurrences(of: "‘", with: "'")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func ipv4ToData(_ dotted: String) -> Data? {
        var a = in_addr()
        if inet_aton(dotted, &a) == 1 {
            var n = a.s_addr // network byte order
            return Data(bytes: &n, count: MemoryLayout<in_addr_t>.size)
        }
        return nil
    }

    // MARK: SystemConfiguration helpers

    private struct NetEnv {
        var iface: String
        var serviceID: String?
        var routerIPv4: String?
        var dhcpServerIPv4: String?
        // verbose hint: where DHCP server came from
        var dhcpSource: String?  // "store" | "lease" | "router"
    }

    private static func scCopyDict(_ store: SCDynamicStore, _ key: String) -> [String: Any]? {
        SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }

    /// Find ServiceID for a given BSD iface by scanning State:/Network/Service/*/IPv4
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

    /// Utility: is a BSD iface a tunnel? (e.g. utun6)
    @inline(__always) static func isTunnelInterface(_ name: String) -> Bool { name.hasPrefix("utun") }

    /// Check if a BSD iface is Wi-Fi via SCNetworkInterface
    static func isWiFiInterface(_ iface: String) -> Bool {
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

    /// Fast check for Wi-Fi: DynamicStore AirPort node for iface, else fall back
    @inline(__always) private static func isWiFiBSDNameFast(_ iface: String, store: SCDynamicStore) -> Bool {
        if iface.isEmpty { return false }
        let key = "State:/Network/Interface/\(iface)/AirPort" as CFString
        if let _ = SCDynamicStoreCopyValue(store, key) { return true }
        return isWiFiInterface(iface)
    }

    /// Choose active Wi-Fi service (IEEE80211 + IPv4 up). Prefer one with Router,
    /// then by Setup:/Network/Global/IPv4.ServiceOrder.
    private static func findActiveWiFiService(store: SCDynamicStore) -> (iface: String, serviceID: String)? {
        // ServiceOrder index
        var orderIndex: [String: Int] = [:]
        if let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any],
           let order = setup["ServiceOrder"] as? [String] {
            for (i, sid) in order.enumerated() { orderIndex[sid] = i }
        }

        // Honor global primary if it’s Wi-Fi + IPv4 up
        if let g = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
           let pi = g["PrimaryInterface"] as? String,
           let sid = g["PrimaryService"] as? String,
           isWiFiBSDNameFast(pi, store: store),
           let v4 = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(sid)/IPv4" as CFString) as? [String: Any],
           let addrs = v4["Addresses"] as? [String], !addrs.isEmpty {
            return (pi, sid)
        }

        // Scan Service/*/IPv4
        let pattern = "State:/Network/Service/.*/IPv4" as CFString
        guard let keys = SCDynamicStoreCopyKeyList(store, pattern) as? [String] else { return nil }

        struct Cand { let iface: String; let sid: String; let hasRouter: Bool; let ord: Int }
        var cands: [Cand] = []

        for key in keys {
            guard let v4 = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let iface = v4["InterfaceName"] as? String,
                  !isTunnelInterface(iface),
                  isWiFiBSDNameFast(iface, store: store),
                  let addrs = v4["Addresses"] as? [String], !addrs.isEmpty else { continue }

            guard let r1 = key.range(of: "Service/"),
                  let r2 = key.range(of: "/IPv4"),
                  r1.upperBound < r2.lowerBound else { continue }
            let sid = String(key[r1.upperBound..<r2.lowerBound])
            let hasRouter = (v4["Router"] as? String) != nil
            let ord = orderIndex[sid] ?? Int.max
            cands.append(.init(iface: iface, sid: sid, hasRouter: hasRouter, ord: ord))
        }

        cands.sort {
            if $0.hasRouter != $1.hasRouter { return $0.hasRouter && !$1.hasRouter }
            if $0.ord != $1.ord { return $0.ord < $1.ord }
            return $0.iface < $1.iface
        }
        return cands.first.map { ($0.iface, $0.sid) }
    }

    /// Read dynamic environment. If `lockToIface` is false we prefer the active Wi-Fi.
    private static func readDynamicEnv(preferIface: String,
                                       lockToIface: Bool) -> NetEnv {
        var env = NetEnv(iface: preferIface, serviceID: nil, routerIPv4: nil, dhcpServerIPv4: nil, dhcpSource: nil)
        guard let store = SCDynamicStoreCreate(kCFAllocatorDefault, "ssid-env" as CFString, nil, nil) else {
            return env
        }

        if lockToIface {
            if isTunnelInterface(preferIface), let (wifiIface, sid) = findActiveWiFiService(store: store) {
                env.iface = wifiIface; env.serviceID = sid
            } else if let sid = findServiceID(for: preferIface, store: store) {
                env.iface = preferIface; env.serviceID = sid
            } else {
                return env
            }
        } else {
            if let (wifiIface, sid) = findActiveWiFiService(store: store) {
                env.iface = wifiIface; env.serviceID = sid
                if let v4 = scCopyDict(store, "State:/Network/Service/\(sid)/IPv4") {
                    env.routerIPv4 = v4["Router"] as? String
                }
            } else if let g = scCopyDict(store, "State:/Network/Global/IPv4") {
                if let pi = g["PrimaryInterface"] as? String { env.iface = pi }
                env.serviceID = g["PrimaryService"] as? String
                if let r = g["Router"] as? String { env.routerIPv4 = r }
            }
        }

        guard let sid = env.serviceID else { return env }

        /// Parse DHCP server identifier from a DHCP dictionary.
        /// Returns (ip, "store:<key>") so verbose can show the exact source key.
        func parseDHCPEx(_ dict: [String: Any]) -> (String, String)? {
            @inline(__always)
            func ipFromBytes4<B: Collection>(_ b: B) -> String? where B.Element == UInt8 {
                guard b.count >= 4 else { return nil }
                var it = b.makeIterator()
                guard let a = it.next(), let b = it.next(), let c = it.next(), let d = it.next() else { return nil }
                return "\(a).\(b).\(c).\(d)"
            }

            // Common keys seen across macOS versions/configd builds.
            let keys = [
                "ServerIdentifier", "server_identifier",
                "DHCPServerIdentifier", "DHCPServerID",
                "Option_54", "option_54", "Option 54"
            ]

            for k in keys {
                guard let v = dict[k] else { continue }
                if let s = v as? String, !s.isEmpty { return (s, "store:\(k)") }
                if let d = v as? Data, let ip = ipFromBytes4(d) { return (ip, "store:\(k)") }
                if let a = v as? [UInt8], let ip = ipFromBytes4(a) { return (ip, "store:\(k)") }
                if let n = v as? NSNumber {
                    // NSNumber stores raw network-byte-order (big-endian) bytes as a
                    // host-order uint32; .bigEndian swaps back so we can extract octets
                    // MSB-first to reconstruct the dotted-decimal IP.
                    let x = n.uint32Value.bigEndian
                    let b0 = UInt8((x >> 24) & 0xff), b1 = UInt8((x >> 16) & 0xff)
                    let b2 = UInt8((x >>  8) & 0xff), b3 = UInt8(x & 0xff)
                    return ("\(b0).\(b1).\(b2).\(b3)", "store:\(k)")
                }
            }
            return nil
        }
        
        var sawDHCPNode = false

        // Dedicated DHCP nodes
        if let d = scCopyDict(store, "State:/Network/Service/\(sid)/DHCP") {
            sawDHCPNode = true
            if let (ip, src) = parseDHCPEx(d) {
                env.dhcpServerIPv4 = ip
                env.dhcpSource = src         // e.g., "store:Option_54"
            }
        } else if let d = scCopyDict(store, "State:/Network/Service/\(sid)/DHCPv4") {
            sawDHCPNode = true
            if let (ip, src) = parseDHCPEx(d) {
                env.dhcpServerIPv4 = ip
                env.dhcpSource = src
            }
        }

        // IPv4 node with embedded DHCP sub-dictionary (what ipconfig prints)
        if let v4 = scCopyDict(store, "State:/Network/Service/\(sid)/IPv4") {
            if env.routerIPv4 == nil { env.routerIPv4 = v4["Router"] as? String }
            if let dhcp = v4["DHCP"] as? [String: Any] {
                sawDHCPNode = true
                if env.dhcpServerIPv4 == nil, let (ip, src) = parseDHCPEx(dhcp) {
                    env.dhcpServerIPv4 = ip
                    env.dhcpSource = src
                }
            }
        }

        // Fallback A: read from lease files (root)
        if env.dhcpServerIPv4 == nil, let fromLease = dhcpServerFromLeaseFiles(iface: env.iface) {
            env.dhcpServerIPv4 = fromLease
            env.dhcpSource = "lease"
        }

        // Fallback B: DHCP node existed but no explicit server id -> use Router
        if env.dhcpServerIPv4 == nil, sawDHCPNode, let r = env.routerIPv4 {
            env.dhcpServerIPv4 = r
            env.dhcpSource = "router"
        }

        return env
    }
    
    /// Read DHCP server id from /var/db/dhcpclient/leases/<iface*>
    /// Accepts both String and 4-byte Data forms.
    private static func dhcpServerFromLeaseFiles(iface: String) -> String? {
        let dir = "/var/db/dhcpclient/leases"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        for name in names where name.hasPrefix(iface) {
            let path = dir + "/" + name
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { continue }
            var fmt = PropertyListSerialization.PropertyListFormat.binary
            guard let any = try? PropertyListSerialization.propertyList(from: data, options: [], format: &fmt),
                  let dict = any as? [String: Any] else { continue }
            if let s = dict["ServerIdentifier"] as? String { return s }
            if let d = dict["ServerIdentifier"] as? Data, d.count == 4 {
                let b = [UInt8](d); return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
            }
            // try common lowercase alias
            if let s2 = dict["server_identifier"] as? String { return s2 }
            if let d2 = dict["server_identifier"] as? Data, d2.count == 4 {
                let b = [UInt8](d2); return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
            }
        }
        return nil
    }
    
    // MARK: IOKit / IORegistry (channel + fallback)
    
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

    private static func currentWiFiChannel(_ iface: String) -> Int? {
        let keys = ["IO80211Channel", "Channel"]
        let svc = ioFindServiceForBSDName(iface)
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        if let v = findPropOnEntryOrParents(svc, keys: keys) {
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

    // MARK: Known-networks inference (macOS ≥ 11)

    /// Drop to real uid/gid and verify.
    @inline(__always) private static func dropEffectivePrivileges() -> Bool {
        let rgid = getgid()
        let ruid = getuid()
        guard setgid(rgid) == 0 else { return false }
        guard setuid(ruid) == 0 else { return false }
        return getegid() == rgid && geteuid() == ruid
    }

    /// Fail closed if we cannot drop privileges in a setuid/sudo path.
    private static func fatalPrivilegeDropFailure() -> Never {
        fputs("error: failed to drop effective privileges; aborting for safety\n", stderr)
        exit(1)
    }

    /// Safely read /Library/Preferences/com.apple.wifi.known-networks.plist
    private static func secureReadKnownNetworks() -> Data? {
        let path = "/Library/Preferences/com.apple.wifi.known-networks.plist"
        @inline(__always)
        func finish(_ value: Data?) -> Data? {
            if !dropEffectivePrivileges() { fatalPrivilegeDropFailure() }
            return value
        }

        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { return finish(nil) }
        defer { close(fd) }

        var st = stat()
        if fstat(fd, &st) != 0 { return finish(nil) }
        if (st.st_mode & S_IFMT) != S_IFREG || st.st_uid != 0 { return finish(nil) }

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n == 0 { break }
            if n < 0 { return finish(nil) }
            out.append(buf, count: n)
        }
        return finish(out)
    }

    /// Inference using known-networks plist and the current environment.
    private static func inferSSIDFromKnownNetworks(env: NetEnv) -> String? {
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

            // A) DHCP ServerIdentifier exact match
            if let target = dhcpPacked, let bssList = v["BSSList"] as? [[String: Any]] {
                for b in bssList {
                    if let raw = b["DHCPServerID"] as? Data, raw == target {
                        base = 0.85; bestBSS = b; break
                    }
                }
            }

            // B) Router IPv4 in IPv4NetworkSignature
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

                // Timestamp tie-break
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

    // MARK: - Verbose diagnostics

    /// Map ServiceID to (name, device-hint)
    private static func lookupServiceNameDevice(_ sid: String, store: SCDynamicStore) -> (String?, String?) {
        let name = (SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(sid)" as CFString) as? [String: Any])?["UserDefinedName"] as? String
        var dev: String? = nil
        if let iface = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(sid)/Interface" as CFString) as? [String: Any] {
            if let d = iface["DeviceName"] as? String { dev = d }
            else if let hw = iface["Hardware"] as? String { dev = hw }
        }
        return (name, dev)
    }

    private static func sidShort(_ s: String) -> String { s.count > 8 ? String(s.prefix(8)) : s }

    /// Build a human-friendly, colored snapshot of selection logic for `-v`.
    public static func verboseSnapshot(preferIface: String, strictInterface: Bool) -> String {
        var lines: [String] = []
        guard let store = SCDynamicStoreCreate(kCFAllocatorDefault, "ssid-verbose" as CFString, nil, nil) else {
            return "[verbose] SCDynamicStore unavailable"
        }

        lines.append(Ansi.bold("╭─ get-ssid diagnostics"))

        // Primary
        var primaryIface: String? = nil, primaryService: String? = nil
        if let g = scCopyDict(store, "State:/Network/Global/IPv4") {
            primaryIface = g["PrimaryInterface"] as? String
            primaryService = g["PrimaryService"] as? String
        }
        let pi = primaryIface ?? "-", ps = primaryService ?? "-"
        lines.append("├─ Primary: \(Ansi.cyan(pi))  service=\(ps)")

        // Service Order (UI-like: only Setup services, show human name and iface)
        lines.append("├─ Service Order:")
        var orderIndex: [String: Int] = [:]
        if let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any],
           let order = setup["ServiceOrder"] as? [String] {
            for (idx, sid) in order.enumerated() { orderIndex[sid] = idx }
            var n = 1
            for sid in order {
                let (nameOpt, devOpt) = lookupServiceNameDevice(sid, store: store)
                guard let name = nameOpt ?? devOpt else { continue } // UI does not show missing Setup nodes
                var ifn = devOpt ?? "-"
                var up = false
                if let v4 = scCopyDict(store, "State:/Network/Service/\(sid)/IPv4"),
                   let addrs = v4["Addresses"] as? [String], !addrs.isEmpty {
                    if let iname = v4["InterfaceName"] as? String { ifn = iname }
                    up = true
                }
                let status = up ? Ansi.green("up") : Ansi.dim("off")
                let row = String(format: "│  %2d. %@ (%@) %@  [%@]",
                                 n,
                                 Ansi.green(name) as NSString,
                                 Ansi.cyan(ifn) as NSString,
                                 status as NSString,
                                 Ansi.dim(sidShort(sid)) as NSString)
                lines.append(row)
                n += 1
            }
            if n == 1 { lines.append("│  (none)") }
        } else {
            lines.append("│  (none)")
        }

        // IPv4 up interfaces
        lines.append("├─ Interfaces (IPv4 up):")
        let pattern = "State:/Network/Service/.*/IPv4" as CFString
        var any = false
        if let keys = SCDynamicStoreCopyKeyList(store, pattern) as? [String] {
            for key in keys.sorted() {
                guard let v4 = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                      let iface = v4["InterfaceName"] as? String,
                      let addrs = v4["Addresses"] as? [String], !addrs.isEmpty,
                      let r1 = key.range(of: "Service/"),
                      let r2 = key.range(of: "/IPv4"),
                      r1.upperBound < r2.lowerBound else { continue }
                any = true
                let sid = String(key[r1.upperBound..<r2.lowerBound])
                let tag = iface.hasPrefix("utun") ? Ansi.magenta("[VPN]")
                         : (isWiFiBSDNameFast(iface, store: store) ? Ansi.green("[Wi-Fi]") : Ansi.yellow("[wired]"))
                lines.append("│  • \(Ansi.cyan(iface)) \(tag)  sid=\(Ansi.dim(sidShort(sid)))")
            }
        }
        if !any { lines.append("│  (none)") }

        // Chosen Wi-Fi
        let chosen = findActiveWiFiService(store: store)
        if let (aIface, aSid) = chosen {
            var reason = "by ServiceOrder"
            if let v4 = scCopyDict(store, "State:/Network/Service/\(aSid)/IPv4"),
               let _ = v4["Router"] as? String { reason = "has Router" }
            let (nm, _) = lookupServiceNameDevice(aSid, store: store)
            let name = nm ?? "Wi-Fi"
            lines.append("├─ Active Wi-Fi: \(Ansi.green(name)) \(Ansi.cyan("(\(aIface))"))  service=\(Ansi.dim(sidShort(aSid)))  [\(reason)]")
        } else {
            lines.append("├─ Active Wi-Fi: (none)")
        }

        // Mode/Mapping
        if strictInterface {
            if isTunnelInterface(preferIface) {
                if let (aIface, aSid) = chosen {
                    lines.append("├─ Mapping: input \(Ansi.magenta(preferIface)) → \(Ansi.green(aIface))  service=\(Ansi.dim(sidShort(aSid)))")
                } else {
                    lines.append("├─ Mapping: input \(Ansi.magenta(preferIface)); no active Wi-Fi found")
                }
            } else {
                lines.append("├─ Strict interface: \(Ansi.cyan(preferIface))")
            }
        } else {
            lines.append("├─ Mode: non-strict (prefer active Wi-Fi)")
        }

        // Inference environment
        let env = readDynamicEnv(preferIface: preferIface, lockToIface: strictInterface)
        let es = env.serviceID ?? "-", er = env.routerIPv4 ?? "-"
        let ed = env.dhcpServerIPv4 ?? "-"
        let tag = (env.dhcpServerIPv4 == nil) ? "" : Ansi.dim(" (\(env.dhcpSource ?? "store"))")
        lines.append("└─ Env: iface=\(Ansi.cyan(env.iface))  service=\(Ansi.dim(sidShort(es)))  router=\(Ansi.cyan(er))  dhcp=\(Ansi.cyan(ed))\(tag)")

        return lines.joined(separator: "\n")
    }

#if canImport(CoreWLAN)
    // CoreWLAN helpers used by getSSID()
    @inline(__always)
    private static func cwIsAssociated(_ cw: CWInterface) -> Bool {
        if let s = cw.ssid(), !s.isEmpty { return true }
        if let b = cw.bssid(), !b.isEmpty { return true }
        if let ch = cw.wlanChannel(), ch.channelNumber > 0 { return true }
        return false
    }

    /// Best-effort SSID via CoreWLAN profiles when CWInterface.ssid() is redacted.
    @inline(__always)
    private static func ssidFromProfiles(_ cw: CWInterface) -> String? {
        guard let set = cw.configuration()?.networkProfiles else { return nil }
        for case let p as CWNetworkProfile in set {
            if let s = p.ssid, !s.isEmpty { return s }
        }
        return nil
    }
#endif
}

// MARK: - CLI

#if !TESTING
@main
#endif
struct GetSSIDCLI {
    private static let toolName = "get-ssid"
    private static let version  = "1.0.2"

    private enum Mode { case run, help, version }

    static func main() {
        let (iface, mode, ifaceWasExplicit, verbose) = parseArgs()
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
            if ifaceWasExplicit && !iface.hasPrefix("utun") && !WiFiSSIDResolver.isWiFiInterface(iface) {
                fail("interface '\(iface)' is not a Wi-Fi interface (strict mode)")
            }
            if verbose {
                let diag = WiFiSSIDResolver.verboseSnapshot(preferIface: iface, strictInterface: ifaceWasExplicit)
                fputs(diag + "\n", stderr)
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

    private static func parseArgs() -> (iface: String, mode: Mode, explicit: Bool, verbose: Bool) {
        let argv = Array(CommandLine.arguments.dropFirst())
        var iface: String? = nil
        var mode: Mode = .run
        var verbose = false
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
            } else if a == "-v" || a == "--verbose" {
                verbose = true
            } else if a == "--no-color" {
                setenv("NO_COLOR", "1", 1)
            } else if a.hasPrefix("-") {
                fail("unknown option: \(a)")
            } else {
                if iface == nil { iface = a } else { fail("too many positional arguments") }
            }
            i += 1
        }
        let final = iface ?? "en0"
        return (final, mode, iface != nil, verbose)
    }

    private static func printHelp() {
        let s = [
            "\(toolName) — print the current Wi‑Fi SSID without Location/TCC",
            "",
            "USAGE:",
            "  \(toolName) [options] [iface]",
            "",
            "OPTIONS:",
            "  -h, --help       Show this help and exit",
            "  -V, --version    Show version and exit",
            "  -v, --verbose    Print selection diagnostics to stderr",
            "  --no-color       Disable ANSI colors in verbose output",
            "",
            "ARGS:",
            "  iface            BSD interface name (default: en0)",
            "",
            "BEHAVIOR:",
            "  • No Location permission, no external commands.",
            "  • Usually no sudo; elevation is only needed if known-networks",
            "    fallback is required and the plist is not readable.",
            "  • Without an iface, the active Wi‑Fi service is selected.",
            "  • With an explicit iface, strict mode is used (bind to that service).",
            "    If a tunnel (utun*) is provided, it is mapped to the active Wi‑Fi service.",
            "  • Explicit non-Wi‑Fi iface in strict mode exits with code 2.",
            "",
            "EXIT CODES:",
            #"  0  success (including "Unknown (not associated)")"#,
            "  1  internal safety failure (privilege drop failed)",
            "  2  usage error",
            "  3  interface not found (when iface explicitly provided)",
            "",
            "NOTES:",
            "  macOS 11+: CoreWLAN (live) → CoreWLAN profiles → IORegistry (iface) →",
            "             known‑networks correlation (only if the plist is readable).",
            "             The tool never escalates privileges; the plist read is skipped",
            "             when not accessible.",
            "  macOS 10.x: IORegistry (IO80211SSID_STR / IO80211SSID / SSID_STR).",
            "  Not‑associated Wi‑Fi prints \"Unknown (not associated)\"."
        ].joined(separator: "\n")
        print(s)
    }

    @inline(__always) private static func fail(_ s: String) -> Never {
        fputs("error: \(s)\ntry '\(toolName) --help'\n", stderr)
        exit(2)
    }
}
