import Foundation
import Network
import ContextCapture

public final class IPCClient {
    private let socketPath: String
    private var framed: LineFramedConnection?
    private var conn: NWUnixConnection?
    public var onEvent: ((BrainEvent) -> Void)?
    public var onClose: ((Error?) -> Void)?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func connect() {
        let nw = NWUnixConnection(path: socketPath)
        self.conn = nw
        let framed = LineFramedConnection(nw)
        framed.onLine = { [weak self] line in
            self?.dispatch(line)
        }
        framed.onClose = { [weak self] err in
            self?.onClose?(err)
        }
        self.framed = framed
        nw.start()
    }

    public func sendGenerate(_ req: BrainRequest) throws {
        guard let framed = framed else { throw IPCClientError.notConnected }
        try framed.send(GenerateMessage(req: req))
    }

    public func sendFeedback(_ feedback: FeedbackMessage) throws {
        guard let framed = framed else { throw IPCClientError.notConnected }
        try framed.send(feedback)
    }

    public func close() {
        // Drop the consumer's onClose handler before cancelling the connection.
        // Otherwise NWConnection's `.cancelled` state fires our onClose on a
        // later main-queue tick, and the consumer (AppDelegate) treats an
        // explicit close as if the brain had crashed — flickering the HUD into
        // `.reconnecting` after we've already moved on (e.g., during restart).
        onClose = nil
        framed?.close()
        framed = nil
    }

    private func dispatch(_ line: Data) {
        do {
            let ev = try JSONDecoder().decode(BrainEvent.self, from: line)
            onEvent?(ev)
        } catch {
            // Skip malformed events (defensive — brain shouldn't emit them).
            NSLog("[ipc] decode error: \(error)")
        }
    }
}

public enum IPCClientError: Error, CustomStringConvertible {
    case notConnected
    public var description: String {
        switch self {
        case .notConnected: return "IPCClient.connect() has not been called"
        }
    }
}

struct GenerateMessage: Encodable {
    let type: String = "generate"
    let req: BrainRequest

    enum CodingKeys: String, CodingKey {
        case type
        case reqId, app, windowTitle, intent, axTree
        case screenshotBase64, spokenIntent, transcriberName
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(req.reqId, forKey: .reqId)
        try c.encode(req.app, forKey: .app)
        try c.encode(req.windowTitle, forKey: .windowTitle)
        try c.encode(req.intent, forKey: .intent)
        try c.encode(req.axTree, forKey: .axTree)
        // Optional fields: only encode when present so legacy brain builds
        // (which strict-decode JSON) don't see unexpected nulls.
        if let s = req.screenshotBase64 { try c.encode(s, forKey: .screenshotBase64) }
        if let s = req.spokenIntent { try c.encode(s, forKey: .spokenIntent) }
        if let s = req.transcriberName { try c.encode(s, forKey: .transcriberName) }
    }
}

final class NWUnixConnection: Connection {
    private let connection: NWConnection
    var onReceive: ((Data) -> Void)?
    var onClose:   ((Error?) -> Void)?

    init(path: String) {
        let endpoint = NWEndpoint.unix(path: path)
        // Note: `using: .tcp` is correct for a Unix-domain stream socket.
        // Network.framework reuses its TCP parameters object for any reliable
        // byte-stream transport — there is no Unix-specific NWParameters constant.
        // The `endpoint` (kind: .unix) is what selects AF_UNIX; the parameters
        // only describe stream framing.
        self.connection = NWConnection(to: endpoint, using: .tcp)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.startReceive()
            case .failed(let err):
                self?.onClose?(err)
            case .cancelled:
                self?.onClose?(nil)
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        connection.cancel()
    }

    private func startReceive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, err in
            if let data = data, !data.isEmpty {
                self?.onReceive?(data)
            }
            if let err = err {
                self?.onClose?(err)
                return
            }
            if isComplete {
                self?.onClose?(nil)
                return
            }
            self?.startReceive()
        }
    }
}
