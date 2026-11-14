import Darwin
import Foundation

struct DiscoveredBulb: Identifiable, Hashable, Sendable {
    let ip: String
    let mac: String
    var id: String { mac }
}

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

    /// Like pywizlight: broadcast registration to every IPv4 broadcast address once a second,
    /// collecting replies for `seconds`. Blocking; call off the main thread.
    static func discover(seconds: Double = 5) -> [DiscoveredBulb] {
        let targets = broadcastAddresses()
        guard !targets.isEmpty else { return [] }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
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
                for target in targets {
                    let dst = sockaddrIn(target, port: port)
                    _ = withUnsafePointer(to: dst) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
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
            found[mac] = DiscoveredBulb(ip: string(from.sin_addr), mac: mac)
        }
        return found.values.sorted { $0.ip.compare($1.ip, options: .numeric) == .orderedAscending }
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
