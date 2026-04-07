import Darwin
import Foundation
import Network
import Virtualization

// ADBBridge forwards host 127.0.0.1:<hostPort> → guest adbd.
//
// Per-connection strategy:
//   1. Try vsock (VZVirtioSocketDevice, port 5555) — direct, no NAT
//   2. Fall back to TCP (192.168.64.2:5555) via VZ NAT
//
// adb-ready fires as soon as the host listener is bound — ADB clients
// can connect and will wait while adbd finishes booting inside the guest.

actor ADBBridge {
    private let hostPort: Int
    private let vsockPort: UInt32 = 5555
    private let guestIP: String
    private let guestTCPPort: Int

    private let socketDevice: VZVirtioSocketDevice?
    private var listener: NWListener?

    init(hostPort: Int = 5555,
         guestIP: String = "192.168.64.2",
         guestTCPPort: Int = 5555,
         socketDevice: VZVirtioSocketDevice?) {
        self.hostPort = hostPort
        self.guestIP = guestIP
        self.guestTCPPort = guestTCPPort
        self.socketDevice = socketDevice
    }

    func start() async {
        do {
            try startForwarding()
        } catch {
            fputs("nunu-vm: ADB forwarding failed: \(error)\n", stderr)
            return
        }
        fputs("nunu-vm: ADB bridge listening on 127.0.0.1:\(hostPort)\n", stderr)

        // Wait for adbd to actually be reachable before signalling ready
        await waitAndSignalReady()

        let status = #"{"event":"adb-ready","address":"127.0.0.1:\#(hostPort)"}"#
        print(status); fflush(stdout)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Host listener

    private func startForwarding() throws {
        let port = NWEndpoint.Port(rawValue: UInt16(hostPort))!
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

        let l = try NWListener(using: params)
        self.listener = l

        l.newConnectionHandler = { [weak self] inbound in
            guard let self else { return }
            inbound.start(queue: .global())
            Task { await self.bridge(inbound: inbound) }
        }
        l.start(queue: .global())
    }

    // MARK: - Per-connection bridge

    private func bridge(inbound: NWConnection) async {
        // Try vsock first (direct, no NAT race), fall back to TCP
        if socketDevice != nil, let conn = await tryConnectVsock() {
            fputs("nunu-vm: adb bridge: vsock connected\n", stderr)
            await pipe(inbound: inbound, vsock: conn)
        } else {
            fputs("nunu-vm: adb bridge: vsock unavailable, trying TCP...\n", stderr)
            await bridgeTCP(inbound: inbound)
        }
    }

    // MARK: - Vsock path

    private func tryConnectVsock() async -> VZVirtioSocketConnection? {
        guard let socketDevice else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                socketDevice.connect(toPort: self.vsockPort) { result in
                    switch result {
                    case .success(let conn): cont.resume(returning: conn)
                    case .failure: cont.resume(returning: nil)
                    }
                }
            }
        }
    }

    private func pipe(inbound: NWConnection, vsock: VZVirtioSocketConnection) async {
        let fd = vsock.fileDescriptor
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.pipeNWToFd(from: inbound, fd: fd) }
            group.addTask { await self.pipeFdToNW(fd: fd, to: inbound) }
            await group.waitForAll()
        }
        inbound.cancel()
        Darwin.close(fd)
    }

    // MARK: - TCP path

    private func bridgeTCP(inbound: NWConnection) async {
        // Single attempt — if adbd isn't ready, fail fast so `adb connect` retries
        guard let out = await tryConnectTCP() else {
            fputs("nunu-vm: adb TCP: adbd not ready\n", stderr)
            inbound.cancel()
            return
        }

        fputs("nunu-vm: adb bridge: TCP connected\n", stderr)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.pipeNW(from: inbound, to: out) }
            group.addTask { await self.pipeNW(from: out, to: inbound) }
            await group.waitForAll()
        }
        inbound.cancel()
        out.cancel()
    }

    private func tryConnectTCP() async -> NWConnection? {
        let host = NWEndpoint.Host(guestIP)
        let port = NWEndpoint.Port(rawValue: UInt16(guestTCPPort))!
        let conn = NWConnection(host: host, port: port, using: .tcp)

        return await withCheckedContinuation { cont in
            var resumed = false
            let lock = NSLock()
            func finish(_ result: NWConnection?) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                if result == nil { conn.cancel() }
                cont.resume(returning: result)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:              finish(conn)
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(nil) }
        }
    }

    // Wait for adbd to come up, then notify. Called once at bridge start.
    // Probes vsock first (Cuttlefish adbd listens on vsock 5555), then TCP fallback.
    func waitAndSignalReady() async {
        fputs("nunu-vm: waiting for adbd (vsock:\(vsockPort) or \(guestIP):\(guestTCPPort))...\n", stderr)
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            // Try vsock first — Cuttlefish adbd prefers vsock over TCP
            if socketDevice != nil, let conn = await tryConnectVsock() {
                conn.fileDescriptor  // just touch it to confirm it's open
                Darwin.close(conn.fileDescriptor)
                fputs("nunu-vm: adbd is up (vsock)\n", stderr)
                return
            }
            if let conn = await tryConnectTCP() {
                conn.cancel()
                fputs("nunu-vm: adbd is up (TCP)\n", stderr)
                return
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        fputs("nunu-vm: warning: adbd never came up\n", stderr)
    }

    // MARK: - NWConnection pipes

    private func pipeNW(from source: NWConnection, to dest: NWConnection) async {
        while true {
            guard let data = await recvNW(from: source), !data.isEmpty else { break }
            await sendNW(data: data, to: dest)
        }
    }

    private func recvNW(from conn: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data, !data.isEmpty { cont.resume(returning: data) }
                else { cont.resume(returning: nil) }
            }
        }
    }

    private func sendNW(data: Data, to conn: NWConnection) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: data, completion: .contentProcessed { _ in cont.resume() })
        }
    }

    // MARK: - Vsock fd I/O

    private func pipeNWToFd(from nw: NWConnection, fd: Int32) async {
        while true {
            guard let data = await recvNW(from: nw), !data.isEmpty else { break }
            guard await writeFd(fd, data: data) else { break }
        }
        Darwin.shutdown(fd, SHUT_WR)
    }

    private func pipeFdToNW(fd: Int32, to nw: NWConnection) async {
        while true {
            guard let data = await readFd(fd) else { break }
            await sendNW(data: data, to: nw)
        }
    }

    private func readFd(_ fd: Int32) async -> Data? {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                var buf = [UInt8](repeating: 0, count: 65536)
                let n = Darwin.read(fd, &buf, buf.count)
                cont.resume(returning: n > 0 ? Data(buf[..<n]) : nil)
            }
        }
    }

    private func writeFd(_ fd: Int32, data: Data) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let ok = data.withUnsafeBytes { ptr -> Bool in
                    guard let base = ptr.baseAddress else { return false }
                    var rem = data.count; var off = 0
                    while rem > 0 {
                        let n = Darwin.write(fd, base.advanced(by: off), rem)
                        guard n > 0 else { return false }
                        off += n; rem -= n
                    }
                    return true
                }
                cont.resume(returning: ok)
            }
        }
    }
}
