import Darwin
import Foundation
import Network

struct DiscoveredBulb: Identifiable, Hashable, Sendable {
    let ip: String
    let mac: String
    /// Reverse-DNS name, once looked up (nil if there isn't one).
    var name: String?
    var id: String { mac }
}

struct DiscoveryResult: Sendable {
    var bulbs: [DiscoveredBulb] = []
    /// Every broadcast was refused (EHOSTUNREACH etc.): Local Network access isn't granted yet.
    var blocked = false
}

enum LocalNetworkAccess: Sendable { case unknown, denied }

/// BSD-socket helpers. Network.framework has no broadcast support, so discovery lives here.
enum Net {
    static let port: UInt16 = 38899
    static let pushPort: UInt16 = 38900

    /// pywizlight's discovery message. The MAC/IP are placeholders: register=false means
    /// the bulb doesn't use them, it just replies to the sender with its MAC.
    static let discoveryMessage =
        #"{"method":"registration","params":{"phoneMac":"AAAAAAAAAAAA","register":false,"phoneIp":"1.2.3.4","id":"1"}}"#

    static func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    #if os(macOS)
    // Discovery is Mac-only: on iOS, broadcasting needs the multicast entitlement.

    /// Like pywizlight: broadcast registration to every IPv4 broadcast address once a second,
    /// collecting replies for `seconds`. Blocking; call off the main thread.
    ///
    /// Without Local Network access every send fails (EHOSTUNREACH) and, unlike a Network.framework
    /// connection, doesn't reliably bring up the permission prompt; that case returns at once with
    /// `blocked` set (see `requestLocalNetworkAccess`).
    static func discover(seconds: Double = 5,
                         onFound: @Sendable (DiscoveredBulb) -> Void = { _ in }) -> DiscoveryResult {
        let targets = broadcastAddresses()
        guard !targets.isEmpty else { return DiscoveryResult() }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return DiscoveryResult() }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let msg = Array(discoveryMessage.utf8)
        var buf = [UInt8](repeating: 0, count: 4096)
        let cap = buf.count
        var found: [String: DiscoveredBulb] = [:]
        let deadline = Date().addingTimeInterval(seconds)
        var nextSend = Date.distantPast

        while Date() < deadline {
            if Date() >= nextSend {
                var sent = 0
                var refused = 0
                for target in targets {
                    let dst = sockaddrIn(target, port: port)
                    let n = withUnsafePointer(to: dst) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    if n >= 0 { sent += 1 } else if [EHOSTUNREACH, EPERM, EACCES].contains(errno) { refused += 1 }
                }
                if sent == 0 && refused == targets.count && found.isEmpty {
                    return DiscoveryResult(blocked: true)
                }
                nextSend = Date().addingTimeInterval(1)
            }
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, cap, 0, $0, &len) }
            }
            guard n > 0,
                  let obj = json(Data(buf[0..<n])),
                  let result = obj["result"] as? [String: Any],
                  let mac = result["mac"] as? String
            else { continue }
            if found[mac] == nil {
                let bulb = DiscoveredBulb(ip: string(from.sin_addr), mac: mac)
                found[mac] = bulb
                onFound(bulb)
            }
        }
        return DiscoveryResult(bulbs: found.values.sorted { $0.ip.compare($1.ip, options: .numeric) == .orderedAscending })
    }

    /// Brings up the Local Network permission prompt if it hasn't been answered, by sending one
    /// unicast datagram (the harmless discovery message) through Network.framework to a host on
    /// each local subnet; the BSD-socket broadcasts used for discovery don't reliably trigger it.
    /// On macOS 15 and later, also reports whether access has been denied.
    @MainActor
    static func requestLocalNetworkAccess() async -> LocalNetworkAccess {
        let message = Data(discoveryMessage.utf8)
        let connections = localProbeTargets().compactMap { IPv4Address($0) }.map {
            NWConnection(host: .ipv4($0), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        }
        for c in connections {
            c.start(queue: .global())
            c.send(content: message, completion: .idempotent)
        }
        try? await Task.sleep(for: .seconds(1))
        var access = LocalNetworkAccess.unknown
        if #available(macOS 15.0, *) {
            if connections.contains(where: { $0.currentPath?.unsatisfiedReason == .localNetworkDenied }) {
                access = .denied
            }
        }
        connections.forEach { $0.cancel() }
        return access
    }

    /// The first host address (network + 1, or + 2 if that's us) of each local IPv4 subnet.
    static func localProbeTargets() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [String] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            let flags = Int32(bitPattern: ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = ifa.ifa_netmask
            else { continue }
            let own = UInt32(bigEndian: addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr })
            let m = UInt32(bigEndian: mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr })
            let network = own & m
            var host = network + 1
            if host == own { host += 1 }
            guard host & ~m != ~m else { continue } // not the broadcast address (tiny subnets)
            let target = in_addr(s_addr: host.bigEndian)
            let s = string(target)
            if !out.contains(s) { out.append(s) }
        }
        return out
    }

    /// Broadcast address of every up, non-loopback, broadcast-capable IPv4 interface.
    static func broadcastAddresses() -> [in_addr] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var seen = Set<UInt32>()
        var out: [in_addr] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            let flags = Int32(bitPattern: ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let dst = ifa.ifa_dstaddr // holds the broadcast address when IFF_BROADCAST is set
            else { continue }
            let bcast = dst.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if seen.insert(bcast.s_addr).inserted { out.append(bcast) }
        }
        return out
    }
    #endif

    static func isIPv4(_ s: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, s, &addr) == 1
    }

    /// Reverse DNS for an IPv4 address (nil if it has no name). Blocking; call off the main thread.
    static func reverseName(_ ip: String) -> String? {
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return nil }
        let sin = sockaddrIn(addr, port: 0)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let hostLen = socklen_t(host.count)
        let rc = withUnsafePointer(to: sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, hostLen, nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0 else { return nil }
        let name = String(cString: host)
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    /// The IPv4 address for `host`: itself if it already is one, otherwise a DNS lookup. Blocking;
    /// call off the main thread.
    static func resolveIPv4(_ host: String) -> String? {
        var addr = in_addr()
        if inet_pton(AF_INET, host, &addr) == 1 { return host }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        guard let sa = first.pointee.ai_addr else { return nil }
        return string(sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr })
    }

    /// Local IPv4 address the OS would use to reach `ip` (pywizlight's trick: connect a UDP
    /// socket, which sends nothing, then read its local address).
    static func sourceIP(toward ip: String) -> String? {
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let dst = sockaddrIn(addr, port: port)
        let ok = withUnsafePointer(to: dst) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &local) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return got == 0 ? string(local.sin_addr) : nil
    }

    private static func sockaddrIn(_ addr: in_addr, port: UInt16) -> sockaddr_in {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        sin.sin_addr = addr
        return sin
    }

    private static func string(_ addr: in_addr) -> String {
        var a = addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let len = socklen_t(buf.count)
        inet_ntop(AF_INET, &a, &buf, len)
        return String(cString: buf)
    }
}
