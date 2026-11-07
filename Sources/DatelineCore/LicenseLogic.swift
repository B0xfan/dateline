// The 7 day free trial and buyer keys (approved mockup trial-mockups.html, John 2026-11-03).
// When the trial ends the calendar stays to look at; adding, changing and deleting events is off until a key is entered.
// Keys are made on John's Mac by scripts/keys.js and checked here with no internet.
import SwiftUI
import CryptoKit

// shortcut: the trial start and key sit in the app's settings, so deleting those restarts the trial; the code is public anyway (stops normal buyers, as planned).
@MainActor public final class License: ObservableObject {
    public static let shared = License()
    // Raw Ed25519 public keys (base64) from `node scripts/keys.js init`. A new one is added, never swapped, so sold keys keep working.
    public nonisolated static let publicKeys = ["u+BvQLDQy2Qetmnv32FkcALoKJKB0NoL6hMZJUCF6R8="]
    public nonisolated static let revoked: Set<Int> = []  // refunded keys, by number
    public nonisolated static let trialDays = 7
    public static let buyURL = URL(string: "https://payhip.com/b/P4iIX")!
    public static let price = "$29.99"
    public static let endedMessage = "Your free trial has ended. Your calendar is still here to look at. Buy Dateline, or enter the key you got by email, to add and change events again."

    public enum Status: Equatable { case trial(daysLeft: Int), ended, bought(serial: Int) }

    // Only the real app reads and saves the trial; the test and picture modes never touch the saved settings.
    private let live = !CommandLine.arguments.contains { ["--sample", "--render", "--selftest", "--follow-check", "--timing-ui", "--timing", "--a4-check", "--key-check", "--accounts-check", "--email-check", "--assistant"].contains($0) }
    public private(set) var started: Date
    @Published public private(set) var serial: Int?
    @Published public var test: Status?  // set by --render to draw each state
    @Published public var now = Date()  // moved on by the window's clock, so the days left count down while Dateline stays open

    private init() {
        let d = UserDefaults.standard
        if live, let s = d.object(forKey: "trialStarted") as? Date { started = s } else { started = Date() }
        if live, d.object(forKey: "trialStarted") == nil { d.set(started, forKey: "trialStarted") }
        serial = live ? d.string(forKey: "licenseKey").flatMap { keySerial($0) } : nil
        guard live else { return }
        cloud.synchronize()
        syncCloudKey()
        cloudWatch = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main) { _ in
            Task { @MainActor in License.shared.syncCloudKey() }
        }
    }

    // The bought key travels through the person's own iCloud (John 2026-11-07): typed once on the Mac, the iPhone unlocks by itself.
    // The phone never asks for a key (Apple rule 3.1.1). Test and picture modes never reach this (`live`).
    private let cloud = NSUbiquitousKeyValueStore.default
    private static let cloudKey = "license.v1"
    private var cloudWatch: Any?

    /// Takes a good key from iCloud when this device has none, and shares this device's good key when iCloud has none.
    public func syncCloudKey() {
        guard live else { return }
        let d = UserDefaults.standard
        switch pickKey(local: d.string(forKey: "licenseKey"), cloud: cloud.string(forKey: Self.cloudKey)) {
        case .adopt(let k): d.set(k, forKey: "licenseKey"); serial = keySerial(k)
        case .share(let k): cloud.set(k, forKey: Self.cloudKey)
        case .none: break
        }
    }

    /// Redraws the trial parts only when a clock tick changes the days left or ends the trial.
    public func tick(_ d: Date) { if live, test == nil, trialStatus(started: started, now: d, serial: serial) != status { now = d } }

    public var status: Status { test ?? (live ? trialStatus(started: started, now: now, serial: serial) : .bought(serial: 0)) }
    public var canEdit: Bool { if case .ended = status { return false }; return true }
    public var trialEnds: Date { started.addingTimeInterval(Double(Self.trialDays) * 86400) }

    /// Saves the key when it is good; false leaves everything as it was.
    public func enter(_ key: String) -> Bool {
        guard let s = keySerial(key) else { return false }
        if live { UserDefaults.standard.set(key.filter { !$0.isWhitespace }, forKey: "licenseKey") }
        serial = s; test = nil
        syncCloudKey()
        return true
    }

    #if os(macOS)
    public func buy() { NSWorkspace.shared.open(Self.buyURL) }
    #endif
}

/// Pure, for the self-test: 7 days from the first open, counted in whole days left (the last day says 1).
public func trialStatus(started: Date, now: Date, serial: Int?) -> License.Status {
    if let serial { return .bought(serial: serial) }
    let left = started.addingTimeInterval(Double(License.trialDays) * 86400).timeIntervalSince(now)
    return left > 0 ? .trial(daysLeft: min(Int((left / 86400).rounded(.up)), License.trialDays)) : .ended  // never more than 7, even with the clock set back
}

public enum KeyMove: Equatable { case adopt(String), share(String), none }

/// Pure, for the self-test: which way the bought key moves between this device and iCloud. Two different good keys both stay.
public nonisolated func pickKey(local: String?, cloud: String?, check: (String) -> Int? = { keySerial($0) }) -> KeyMove {
    if let l = local, check(l) != nil { return cloud.flatMap(check) == nil ? .share(l) : .none }
    if let c = cloud, check(c) != nil { return .adopt(c) }
    return .none
}

/// The key's number when it is a good Dateline key: DLK-K<6 digits>.<86-char base64url Ed25519 signature of "K<6 digits>">.
public nonisolated func keySerial(_ key: String, publicKeys: [String] = License.publicKeys, revoked: Set<Int> = License.revoked) -> Int? {
    let k = key.filter { !$0.isWhitespace }
    guard k.hasPrefix("DLK-K"), k.count == 98, let dot = k.firstIndex(of: "."), k.distance(from: k.startIndex, to: dot) == 11 else { return nil }
    let num = String(k[k.index(k.startIndex, offsetBy: 5)..<dot])
    var sig = String(k[k.index(after: dot)...]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    sig += "=="
    guard num.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(num), let s = Data(base64Encoded: sig), s.count == 64 else { return nil }
    let payload = Data("K\(num)".utf8)
    let good = publicKeys.contains { raw in
        guard let d = Data(base64Encoded: raw), let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: d) else { return false }
        return pk.isValidSignature(s, for: payload)
    }
    return good && !revoked.contains(n) ? n : nil
}

// MARK: screens

public func licenseSelftest(_ expect: (Bool, String) -> Void) {
    let priv = Curve25519.Signing.PrivateKey(), pub = priv.publicKey.rawRepresentation.base64EncodedString()
    func make(_ n: Int, _ k: Curve25519.Signing.PrivateKey = priv) -> String {
        let p = "K" + String(format: "%06d", n)
        let s = try! k.signature(for: Data(p.utf8)).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "DLK-\(p).\(s)"
    }
    let good = make(586300)
    expect(good.count == 98, "keys: 98 characters, under Payhip's 100")
    expect(keySerial(good, publicKeys: [pub], revoked: []) == 586300, "keys: a good key gives its number")
    expect(keySerial(" " + good.prefix(50) + "\n" + good.dropFirst(50), publicKeys: [pub], revoked: []) == 586300, "keys: spaces and line breaks from an email are ignored")
    expect(keySerial(good, publicKeys: [pub], revoked: [586300]) == nil, "keys: a refunded key is refused")
    expect(keySerial(make(586300, Curve25519.Signing.PrivateKey()), publicKeys: [pub], revoked: []) == nil, "keys: a key signed by someone else is refused")
    expect(keySerial(good.replacingOccurrences(of: "K586300", with: "K586301"), publicKeys: [pub], revoked: []) == nil, "keys: a changed number is refused")
    expect(keySerial("RVPK" + good.dropFirst(3), publicKeys: [pub], revoked: []) == nil && keySerial("", publicKeys: [pub], revoked: []) == nil, "keys: other shapes are refused")
    let check = { keySerial($0, publicKeys: [pub], revoked: [586301]) }, refunded = make(586301)
    expect(pickKey(local: nil, cloud: good, check: check) == .adopt(good), "iCloud key: a phone with no key takes the Mac's good key")
    expect(pickKey(local: good, cloud: nil, check: check) == .share(good), "iCloud key: a good key on this device goes to iCloud when it has none")
    expect(pickKey(local: good, cloud: good, check: check) == .none && pickKey(local: nil, cloud: nil, check: check) == .none, "iCloud key: nothing moves when both match or neither has one")
    expect(pickKey(local: nil, cloud: refunded, check: check) == .none && pickKey(local: nil, cloud: "junk", check: check) == .none, "iCloud key: a refunded or broken key in iCloud never unlocks")
    expect(pickKey(local: good, cloud: refunded, check: check) == .share(good) && pickKey(local: good, cloud: make(586302), check: check) == .none, "iCloud key: a good key replaces a refunded one, never another good one")
    let start = Date(timeIntervalSince1970: 1_800_000_000), day = 86400.0
    expect(trialStatus(started: start, now: start, serial: nil) == .trial(daysLeft: 7), "trial: 7 days left on the first day")
    expect(trialStatus(started: start, now: start + 2.5 * day, serial: nil) == .trial(daysLeft: 5), "trial: 5 days left half way through day 3")
    expect(trialStatus(started: start, now: start + 6.9 * day, serial: nil) == .trial(daysLeft: 1), "trial: the last day says 1")
    expect(trialStatus(started: start, now: start + 7 * day, serial: nil) == .ended, "trial: ended after 7 days")
    expect(trialStatus(started: start, now: start - 30 * day, serial: nil) == .trial(daysLeft: 7), "trial: setting the clock back never adds days")
    expect(trialStatus(started: start, now: start + 30 * day, serial: 586300) == .bought(serial: 586300), "trial: a key ends it for good")
}

