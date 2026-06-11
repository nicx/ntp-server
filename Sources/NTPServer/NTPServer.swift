import Foundation
import Network
import CNTPSync

final class NTPServer {
    enum State {
        case stopped
        case running
        case error(String)
    }

    private(set) var state: State = .stopped
    var onStateChange: (() -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.ntpserver.queue")

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: - Lifecycle

    func start(port: UInt16) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            setState(.error("ungültiger Port"))
            return
        }
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: nwPort)

            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:            self?.setState(.running)
                case .failed(let err):  self?.setState(.error(self?.describe(err) ?? "\(err)"))
                case .cancelled:        self?.setState(.stopped)
                default:                break
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener = l
            l.start(queue: queue)
        } catch {
            setState(.error(describe(error)))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        if case .error = state { /* Fehlermeldung stehen lassen */ } else { setState(.stopped) }
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receiveMessage { [weak self] data, _, _, _ in
            let recvDate = Date()
            guard let self = self, let data = data, !data.isEmpty else {
                conn.cancel()
                return
            }
            let response = self.makeResponse(request: [UInt8](data), recvDate: recvDate)
            conn.send(content: Data(response), completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }

    // MARK: - State helper

    private func setState(_ s: State) {
        state = s
        onStateChange?()
    }

    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == 13 {
            return "Keine Berechtigung (Port <1024 braucht Root)"
        }
        if ns.domain == NSPOSIXErrorDomain && ns.code == 48 {
            return "Port bereits belegt"
        }
        return error.localizedDescription
    }

    // MARK: - NTP packet (RFC 5905, vereinfacht)

    private let ntpUnixDelta: UInt64 = 2_208_988_800  // Sekunden zwischen 1900 und 1970

    private func ntpTimestamp(_ date: Date) -> (UInt32, UInt32) {
        let interval = date.timeIntervalSince1970
        let seconds = UInt64(interval) + ntpUnixDelta
        let fraction = (interval - floor(interval)) * 4_294_967_296.0
        return (UInt32(seconds & 0xFFFF_FFFF), UInt32(fraction))
    }

    private func writeUInt32(_ buf: inout [UInt8], _ offset: Int, _ value: UInt32) {
        buf[offset]     = UInt8((value >> 24) & 0xFF)
        buf[offset + 1] = UInt8((value >> 16) & 0xFF)
        buf[offset + 2] = UInt8((value >> 8) & 0xFF)
        buf[offset + 3] = UInt8(value & 0xFF)
    }

    private func makeResponse(request: [UInt8], recvDate: Date) -> [UInt8] {
        var resp = [UInt8](repeating: 0, count: 48)

        // Sync-Status der Systemuhr: ehrlich Stratum/LI ableiten, statt blind
        // "synchronisiert" zu behaupten. Unsynchronisiert -> LI=3 (Alarm),
        // Stratum 16, refid 0; brave Clients verwerfen die Zeit dann.
        let synced = ntpserver_clock_synced()
        let li: UInt8 = synced ? 0 : 3          // 0 = ok, 3 = nicht synchronisiert
        let stratum: UInt8 = synced ? 2 : 16    // 2 = sekundärer Server (folgt OS-Uhr)

        let clientVN: UInt8 = request.count > 0 ? (request[0] >> 3) & 0x7 : 4
        resp[0] = (li << 6) | (clientVN << 3) | 4            // LI, VN=Client, Mode=4 (Server)
        resp[1] = stratum
        resp[2] = request.count > 2 ? request[2] : 4         // Poll
        resp[3] = UInt8(bitPattern: -20)                     // Precision ~ 1µs

        // Reference ID: synchron -> "LOCL" (Zeit aus lokaler OS-Uhr),
        // sonst 0 (passend zu LI=Alarm / Stratum 16).
        if synced {
            let refid = Array("LOCL".utf8)
            resp[12] = refid[0]; resp[13] = refid[1]; resp[14] = refid[2]; resp[15] = refid[3]
        }

        // Reference Timestamp (nur sinnvoll, wenn synchron)
        if synced {
            let (refSec, refFrac) = ntpTimestamp(recvDate)
            writeUInt32(&resp, 16, refSec); writeUInt32(&resp, 20, refFrac)
        }

        // Originate Timestamp = Transmit-Timestamp des Clients (Bytes 40..47 der Anfrage)
        if request.count >= 48 {
            for i in 0..<8 { resp[24 + i] = request[40 + i] }
        }

        // Receive Timestamp
        let (rSec, rFrac) = ntpTimestamp(recvDate)
        writeUInt32(&resp, 32, rSec); writeUInt32(&resp, 36, rFrac)

        // Transmit Timestamp (so spät wie möglich)
        let (tSec, tFrac) = ntpTimestamp(Date())
        writeUInt32(&resp, 40, tSec); writeUInt32(&resp, 44, tFrac)

        return resp
    }
}
