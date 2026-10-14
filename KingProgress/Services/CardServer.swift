import Foundation
import Network

/// The socket other apps on this Mac put cards in: newline-delimited JSON
/// over a Unix domain socket that only this user can open. The protocol is
/// in docs/cards.md.
///
/// Every connection is one client. The ids of its cards are its own, and
/// its cards leave when it does: nobody would be left to answer their
/// buttons.
@MainActor
final class CardServer {
    /// A line may carry a logo or two, not a film. A client that sends more
    /// without a newline is not speaking the protocol and is let go.
    static let maxLine = 4 * 1024 * 1024

    /// `~/Library/Application Support/KingProgress/cards.sock`, unless
    /// `KINGPROGRESS_CARDS_SOCKET` says otherwise - so a development build
    /// can run next to the installed one without taking its clients.
    nonisolated static var defaultPath: String {
        if let path = ProcessInfo.processInfo.environment["KINGPROGRESS_CARDS_SOCKET"], !path.isEmpty {
            return path
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("KingProgress/cards.sock").path
    }

    let path: String
    private let cards: ExternalCards
    private var listener: NWListener?
    private var clients: [Int: Client] = [:]
    private var nextClient = 1
    private let verbose = ProcessInfo.processInfo.environment["KINGPROGRESS_VERBOSE"] == "1"

    private final class Client {
        let id: Int
        let connection: NWConnection
        var buffer = Data()
        /// How much of the buffer is known to hold no newline.
        var scanned = 0
        var app: String?
        var language = CardLanguage.en

        init(id: Int, connection: NWConnection) {
            self.id = id
            self.connection = connection
        }

        var name: String { app.map { "\(id) (\($0))" } ?? "\(id)" }
    }

    init(cards: ExternalCards, path: String = CardServer.defaultPath) {
        self.cards = cards
        self.path = path
        cards.onEvent = { [weak self] event, client in self?.send(event, to: client) }
    }

    func start() {
        guard listener == nil else {
            return
        }

        // Another copy of KingProgress already serves the socket - a second
        // build, say. Leave it alone rather than take its clients away.
        if Self.answers(path: path) {
            log("the card socket is already served by another copy of KingProgress: \(path)")
            return
        }

        // Nobody answers, so whatever file is there was left behind by a copy
        // that did not get to clean up.
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(path)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            log("could not open the card socket: \(error)")
            return
        }

        let path = path
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    // Only this user may hand us cards.
                    chmod(path, 0o600)
                    self?.log("listening for cards on \(path)")
                case .failed(let error):
                    self?.log("the card socket failed: \(error)")
                    self?.stop()
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    /// Closes the socket and lets every client go, which takes their cards
    /// off screen.
    func stop() {
        guard let listener else {
            return
        }
        listener.stateUpdateHandler = nil
        listener.cancel()
        self.listener = nil
        for id in Array(clients.keys) {
            drop(id)
        }
        unlink(path)
        log("stopped listening for cards")
    }

    // MARK: - Clients

    private func accept(_ connection: NWConnection) {
        let id = nextClient
        nextClient += 1
        clients[id] = Client(id: id, connection: connection)

        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled:
                    self?.drop(id)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        detail("client \(id) connected")
        receive(id)
    }

    private func receive(_ id: Int) {
        clients[id]?.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, let client = self.clients[id] else {
                    return
                }
                if let data {
                    client.buffer.append(data)
                }
                self.readLines(from: client)

                if client.buffer.count > Self.maxLine {
                    self.log("client \(client.name) sent more than \(Self.maxLine / 1024 / 1024) MB without a newline - letting it go")
                    self.drop(client.id)
                } else if isComplete || error != nil {
                    self.drop(client.id)
                } else {
                    self.receive(id)
                }
            }
        }
    }

    /// Handles every complete line in the buffer and keeps the rest for
    /// later, searching only the part that has not been searched yet: a
    /// 4 MB logo arrives in many pieces.
    private func readLines(from client: Client) {
        var start = 0
        var from = client.scanned

        while let newline = client.buffer[from...].firstIndex(of: 0x0a) {
            handle(client.buffer[start..<newline], from: client)
            start = newline + 1
            from = start
        }

        if start > 0 {
            client.buffer = Data(client.buffer[start...])
        }
        client.scanned = client.buffer.count
    }

    private func handle(_ line: Data, from client: Client) {
        guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0d }) else {
            return
        }
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = message["type"] as? String
        else {
            detail("client \(client.name) sent a line that is not a JSON message - ignored")
            return
        }

        switch type {
        case "hello":
            client.app = message["app"] as? String
            if let language = message["language"] as? String {
                client.language = CardLanguage(code: language)
            }
            detail("client \(client.name) said hello")

        case "show":
            guard let json = message["card"] as? [String: Any],
                  let card = ExternalCard(json: json, client: client.id, language: client.language)
            else {
                detail("client \(client.name) sent a card without an id or a title - ignored")
                return
            }
            cards.show(card)

        case "remove":
            guard let id = message["id"] as? String else { return }
            cards.remove(cardID: id, client: client.id)

        default:
            detail("client \(client.name) sent an unknown message type \(type) - ignored")
        }
    }

    private func send(_ event: CardEvent, to id: Int) {
        guard let client = clients[id],
              var data = try? JSONSerialization.data(withJSONObject: event.message, options: [.sortedKeys, .withoutEscapingSlashes])
        else {
            return
        }
        data.append(0x0a)
        client.connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func drop(_ id: Int) {
        guard let client = clients.removeValue(forKey: id) else {
            return
        }
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
        detail("client \(client.name) disconnected")
        cards.removeAll(client: id)
    }

    // MARK: - Helpers

    /// Whether something already accepts connections on the socket path.
    private static func answers(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return false
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[kingprogress] \(message)\n".utf8))
    }

    /// The comings and goings of clients, for `KINGPROGRESS_VERBOSE`.
    private func detail(_ message: String) {
        if verbose {
            log(message)
        }
    }
}
