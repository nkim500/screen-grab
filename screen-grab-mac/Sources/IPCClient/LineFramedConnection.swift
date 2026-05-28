import Foundation

/// Abstract bidirectional bytestream. Concrete impl: NWConnection over Unix socket.
public protocol Connection: AnyObject {
    func send(_ data: Data)
    var onReceive: ((Data) -> Void)? { get set }
    var onClose:   ((Error?) -> Void)? { get set }
    func close()
}

/// Adds NDJSON framing on top of any `Connection`. Buffers partial reads, splits
/// on newline, and emits one `Data` per JSON line via `onLine`. Sender adds
/// trailing newlines.
public final class LineFramedConnection {
    private let conn: Connection
    private var buffer = Data()
    public var onLine: ((Data) -> Void)?
    public var onClose: ((Error?) -> Void)?

    public init(_ conn: Connection) {
        self.conn = conn
        conn.onReceive = { [weak self] data in self?.handle(data) }
        conn.onClose = { [weak self] err in self?.onClose?(err) }
    }

    public func send(_ obj: Encodable) throws {
        let data = try JSONEncoder().encode(AnyEncodable(obj))
        var line = data
        line.append(0x0A) // \n
        conn.send(line)
    }

    public func close() {
        conn.close()
    }

    private func handle(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: 0..<nl)
            buffer.removeSubrange(0...nl)
            if !line.isEmpty {
                onLine?(line)
            }
        }
    }
}

private struct AnyEncodable: Encodable {
    let v: Encodable
    init(_ v: Encodable) { self.v = v }
    func encode(to encoder: Encoder) throws { try v.encode(to: encoder) }
}
