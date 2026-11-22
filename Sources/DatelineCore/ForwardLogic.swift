// Forward an email to make an event (A6, approved design 2026-11-21, John): emails forwarded to add@dateline.app from
// up to 3 of the buyer's own addresses wait on dateline.app (at most a day) until this Dateline picks them up.
// An address counts once the buyer sends one email from it with its code in the subject (John chose this free route;
// dateline.app never emails anyone first). The server side is website-mockup/site-open/forward.js in A4.
// The buyer is a random secret made on the first Add and shared through their own iCloud, so Mac and iPhone see the same list.
import Foundation
import Combine
import Security

@MainActor public final class Forward: ObservableObject {
    public static let shared = Forward()
    public nonisolated static let address = "add@dateline.app"
    public nonisolated static let maxAddresses = 3
    static let server = URL(string: "https://dateline.app/api/fwd")!

    public struct Sender: Codable, Equatable, Identifiable, Sendable {
        public var address: String, confirmed: Bool, code: String?
        public var id: String { address }
        public init(address: String, confirmed: Bool, code: String? = nil) { self.address = address; self.confirmed = confirmed; self.code = code }
    }
    public struct Waiting: Codable, Sendable {
        public var id: Int; public var from: String; public var eml: String  // eml: the email (text only), base64
        public init(id: Int, from: String, eml: String) { self.id = id; self.from = from; self.eml = eml }
        /// Saves the email as fwd-<id>.eml in `folder` (a hidden name first, so a folder scan never reads half of it), for the Mac
        /// and the iPhone alike. True once it is safely there, or unreadable so there is nothing to keep: the server may then delete it.
        public func save(in folder: URL) -> Bool {
            let name = "fwd-\(id).eml", dest = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dest.path) { return true }  // picked up before, the server's delete didn't arrive
            guard let data = Data(base64Encoded: eml, options: .ignoreUnknownCharacters) else { return true }  // a wrapped base64 still reads
            let tmp = folder.appendingPathComponent("." + name + ".tmp")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: tmp); try FileManager.default.moveItem(at: tmp, to: dest); return true
            } catch { try? FileManager.default.removeItem(at: tmp); return false }
        }
    }
    struct Reply: Codable { var addresses: [Sender]; var mail: [Waiting] }

    @Published public var senders: [Sender] = []
    @Published public var problem: String?
    @Published public private(set) var working = false
    /// Set by the app: keeps the picked-up emails where it reads them and returns the ids kept safely; only those are deleted on the server.
    public var deliver: (([Waiting]) -> [Int])?

    // Tests and picture runs (any "--" argument) never touch the saved secret or the server.
    private let live = !CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
    private let cloud = NSUbiquitousKeyValueStore.default
    private static let key = "forwardToken", cloudKey = "forward.v1"
    private var token: String? { UserDefaults.standard.string(forKey: Self.key) }

    private init() {
        guard live else { return }
        adoptCloud()
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main) { _ in
            Task { @MainActor in Forward.shared.adoptCloud(); await Forward.shared.refresh() }
        }
    }

    /// iCloud's secret wins, so two devices that both made one end up on the same list.
    func adoptCloud() {
        let d = UserDefaults.standard
        if let c = cloud.string(forKey: Self.cloudKey), c != d.string(forKey: Self.key) { d.set(c, forKey: Self.key) }
        else if let t = token, cloud.string(forKey: Self.cloudKey) == nil { cloud.set(t, forKey: Self.cloudKey) }
    }

    /// Picks up waiting emails and the address list. Nothing goes to the server until the buyer has added an address.
    public func refresh() async {
        guard live, token != nil, !working else { return }
        guard let r = await call(nil) else { return }
        senders = r.addresses
        if !r.mail.isEmpty, let deliver {
            let kept = deliver(r.mail)
            if !kept.isEmpty, let r2 = await call(["done": kept]) { senders = r2.addresses }
        }
    }

    /// False (with `problem` set) when the server said no: not an email address, 3 already, or another Dateline has it.
    @discardableResult public func add(_ address: String) async -> Bool {
        guard live else { return false }
        if token == nil {
            var b = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, b.count, &b) == errSecSuccess else { problem = "Dateline couldn't set this up. Try again."; return false }
            let t = Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            UserDefaults.standard.set(t, forKey: Self.key); cloud.set(t, forKey: Self.cloudKey)
        }
        guard let r = await call(["add": address]) else { return false }
        senders = r.addresses
        return true
    }

    public func remove(_ address: String) async {
        guard live, let r = await call(["remove": address]) else { return }
        senders = r.addresses
    }

    /// The confirming email, ready to send from the buyer's own mail app.
    public nonisolated static func confirmLink(_ s: Sender) -> URL? {
        guard let code = s.code else { return nil }
        var c = URLComponents(); c.scheme = "mailto"; c.path = address
        c.queryItems = [URLQueryItem(name: "subject", value: "Dateline \(code)"),
                        URLQueryItem(name: "body", value: "Send this email from \(s.address) to confirm it for Dateline.")]
        return c.url
    }

    private func call(_ body: [String: Any]?) async -> Reply? {
        guard let token else { return nil }
        working = true; defer { working = false }
        var q = URLRequest(url: Self.server, timeoutInterval: 20)
        q.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body { q.httpMethod = "POST"; q.httpBody = try? JSONSerialization.data(withJSONObject: body); q.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: q)
            if (resp as? HTTPURLResponse)?.statusCode == 200, let r = try? JSONDecoder().decode(Reply.self, from: data) { problem = nil; return r }
            problem = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "Dateline's server didn't answer as expected. Try again later."
        } catch { problem = "Dateline couldn't reach its server. Check the internet connection." }
        return nil
    }
}

/// The text the Settings list shows under an address.
public func forwardStatus(_ s: Forward.Sender) -> String {
    s.confirmed ? "Confirmed" : "Send one email from this address to \(Forward.address) with “Dateline \(s.code ?? "")” as the subject to finish"
}
