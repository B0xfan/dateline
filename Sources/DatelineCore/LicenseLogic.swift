// The 7 day free trial and buyer keys (approved mockup trial-mockups.html, John 2026-11-03).
// When the trial ends the calendar stays to look at; adding, changing and deleting events is off until a key is entered.
// Keys are made on John's Mac by scripts/keys.js and checked here with no internet.
import SwiftUI
import CryptoKit
import Security
import StoreKit

// shortcut: the trial start and key sit in the app's settings, so deleting those restarts the trial; the code is public anyway (stops normal buyers, as planned).
@MainActor public final class License: ObservableObject {
    public static let shared = License()
    // Raw Ed25519 public keys (base64) from `node scripts/keys.js init`. A new one is added, never swapped, so sold keys keep working.
    public nonisolated static let publicKeys = ["u+BvQLDQy2Qetmnv32FkcALoKJKB0NoL6hMZJUCF6R8="]
    public nonisolated static let revoked: Set<Int> = []  // refunded keys, by number
    public nonisolated static let revokedPurchases: Set<String> = []  // App Store unlocks shut off by hand (a shared record), by originalTransactionId
    public nonisolated static let trialDays = 7
    public static let buyURL = URL(string: "https://payhip.com/b/P4iIX")!
    public static let price = "$29.99"
    public static let endedMessage = "Your free trial has ended. Your calendar is still here to look at. Buy Dateline, or enter the key you got by email, to add and change events again."

    public enum Status: Equatable { case trial(daysLeft: Int), ended, bought(serial: Int) }

    // Only the real app reads and saves the trial; the test and picture modes never touch the saved settings.
    private let live = !CommandLine.arguments.contains { ["--sample", "--render", "--selftest", "--follow-check", "--timing-ui", "--timing", "--a4-check", "--key-check", "--accounts-check", "--email-check", "--assistant"].contains($0) }
    public private(set) var started: Date
    @Published public private(set) var serial: Int?
    @Published public private(set) var purchased = false  // the App Store unlock: owned on this iPhone, or Apple's signed record of it reached this device through iCloud
    private var storeOwned = false  // the iPhone's App Store says this Apple Account owns the unlock
    @Published public private(set) var unlockPrice: String?  // the unlock's price as Apple shows it in this country (iPhone only); nil until the App Store answers
    public nonisolated static let productID = "com.johnhesch.dateline.unlock"  // App Store Connect in-app purchase 6831993222, non-consumable, $29.99
    @Published public var test: Status?  // set by --render to draw each state
    @Published public var now = Date()  // moved on by the window's clock, so the days left count down while Dateline stays open
    /// False on an iPhone until the free "7-day Trial" item is taken from Apple (App Review 3.1.1); editing stays off until then. Always true on the Mac.
    @Published public var trialBegun = true
    public var trialNotStarted: Bool { !trialBegun && status == .ended }

    private init() {
        let d = UserDefaults.standard
        if live, let s = d.object(forKey: "trialStarted") as? Date { started = s } else { started = Date() }
        #if os(iOS)
        // The phone's trial starts only from the "Start 7-day free trial" button, never by itself.
        if live, d.object(forKey: "trialStarted") == nil { started = .distantPast; trialBegun = false }
        #else
        if live, d.object(forKey: "trialStarted") == nil { d.set(started, forKey: "trialStarted") }
        #endif
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
    private static let cloudPurchase = "purchase.v1"
    private static let cloudRefund = "purchase.refund.v1"  // Apple's signed record of a refund: locks every device holding that purchase
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
        // The App Store unlock travels the same way: Apple's signed record, checked on every device before it counts.
        // A refund record in iCloud wins over the purchase it names, so no device shares the old record back.
        let refund = cloud.string(forKey: Self.cloudRefund)
        if let r = d.string(forKey: "purchase"), purchaseRefunded(r, by: refund) { d.removeObject(forKey: "purchase") }
        if let c = cloud.string(forKey: Self.cloudPurchase), purchaseRefunded(c, by: refund) { cloud.removeObject(forKey: Self.cloudPurchase) }
        var seen: [String: Int?] = [:]  // each record's certificate check runs once per sync
        let check: (String) -> Int? = { s in if let v = seen[s] { return v }; let v = purchaseValid(s) ? 0 : nil; seen[s] = v; return v }
        switch pickKey(local: d.string(forKey: "purchase"), cloud: cloud.string(forKey: Self.cloudPurchase), check: check) {
        case .adopt(let r): d.set(r, forKey: "purchase")
        case .share(let r): cloud.set(r, forKey: Self.cloudPurchase)
        case .none: break
        }
        purchased = storeOwned || d.string(forKey: "purchase").flatMap(check) != nil
    }

    /// Keeps Apple's signed record of the unlock and shares it with the buyer's other devices.
    func recordPurchase(_ jws: String) {
        storeOwned = true
        UserDefaults.standard.set(jws, forKey: "purchase"); cloud.removeObject(forKey: Self.cloudRefund)
        syncCloudKey()
    }

    /// A refunded App Store unlock: Apple's signed refund record goes to iCloud, so the Mac locks again too.
    func dropPurchase(_ refund: String) {
        storeOwned = false
        UserDefaults.standard.removeObject(forKey: "purchase"); cloud.set(refund, forKey: Self.cloudRefund)
        syncCloudKey()
    }

    /// Redraws the trial parts only when a clock tick changes the days left or ends the trial.
    public func tick(_ d: Date) { if live, test == nil, trialStatus(started: started, now: d, serial: owned) != status { now = d } }

    public var status: Status { test ?? (live ? trialStatus(started: started, now: now, serial: owned) : .bought(serial: 0)) }
    private var owned: Int? { serial ?? (purchased ? 0 : nil) }  // 0: bought through the App Store, no key number
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

#if os(iOS)
// Buying through Apple on the iPhone (App Review 3.1.1). One $29.99 unlock; Apple's signed record goes to iCloud and unlocks the Mac too.
extension License {
    public enum BuyResult: Equatable { case bought, pending, cancelled, failed(String) }

    /// Watches Apple's purchase list for the life of the app: new, restored and refunded unlocks. Test and picture modes never reach the store.
    public func watchStore() {
        guard live else { return }
        Task { for await r in StoreKit.Transaction.updates { await take(r) } }
        Task { await refreshStore() }
    }

    public nonisolated static let trialID = "com.johnhesch.dateline.trial"  // App Store Connect free non-consumable "7-day Trial" (App Review 3.1.1)
    /// The trial began when Apple recorded the free trial item; the earliest record wins, so deleting the app never restarts it.
    private func beginTrial(_ at: Date) {
        guard let s = trialStart(saved: trialBegun ? started : nil, store: at) else { return }
        started = s; trialBegun = true; UserDefaults.standard.set(s, forKey: "trialStarted"); now = Date()
    }

    /// Start 7-day free trial: takes the free trial item from Apple. True once the trial runs.
    public func startTrial() async -> BuyResult {
        do {
            guard let p = try await Product.products(for: [Self.trialID]).first else { return .failed("The App Store didn't answer. Try again in a moment.") }
            switch try await p.purchase() {
            case .success(let r): await take(r); return trialBegun ? .bought : .failed("Apple couldn't confirm the trial. Try again in a moment.")
            case .pending: return .pending
            default: return .cancelled
            }
        } catch { return .failed(error.localizedDescription) }
    }

    private func take(_ r: VerificationResult<StoreKit.Transaction>) async {
        if case .verified(let t) = r, t.productID == Self.trialID { beginTrial(t.originalPurchaseDate); await t.finish(); return }
        guard case .verified(let t) = r, t.productID == Self.productID else { return }
        if t.revocationDate != nil { dropPurchase(r.jwsRepresentation) } else { recordPurchase(r.jwsRepresentation) }
        await t.finish()
    }

    // The latest transaction, refunded ones included, so a refund made while Dateline was closed still locks it.
    private func refreshStore() async {
        if let r = await StoreKit.Transaction.latest(for: Self.trialID) { await take(r) }
        if let r = await StoreKit.Transaction.latest(for: Self.productID) { await take(r) }
        if unlockPrice == nil { unlockPrice = try? await Product.products(for: [Self.productID]).first?.displayPrice }
    }

    public func buyInApp() async -> BuyResult {
        do {
            guard let p = try await Product.products(for: [Self.productID]).first else { return .failed("The App Store didn't answer. Try again in a moment.") }
            switch try await p.purchase() {
            case .success(let r): await take(r); return storeOwned ? .bought : .failed("Apple couldn't confirm the purchase. Try Restore purchase.")
            case .pending: return .pending
            default: return .cancelled
            }
        } catch { return .failed(error.localizedDescription) }
    }

    /// Restore purchase: asks Apple again (it may ask for the Apple Account password), then iCloud.
    public func restore() async { try? await AppStore.sync(); await refreshStore(); syncCloudKey() }
}
#endif

/// True when `jws` is Apple's signed record of the Dateline unlock: for this app and product, not refunded, and signed by a key Apple's certificates vouch for.
/// The Mac has no App Store purchase of its own (Developer ID), so this is how a purchase made on the iPhone counts there.
// shortcut: free TestFlight purchases (environment "Sandbox") count too, on purpose for now; require "Production" before the App Store launch.
public nonisolated func purchaseValid(_ jws: String, leafKey: ([Data], Date) -> P256.Signing.PublicKey? = appleLeafKey, revoked: Set<String> = License.revokedPurchases) -> Bool {
    guard let p = purchaseRecord(jws, leafKey: leafKey), p["revocationDate"] == nil else { return false }
    return !revoked.contains(p["originalTransactionId"] as? String ?? "")
}

/// True when `refund` is Apple's signed refund record for the same purchase as `jws`.
public nonisolated func purchaseRefunded(_ jws: String, by refund: String?, leafKey: ([Data], Date) -> P256.Signing.PublicKey? = appleLeafKey) -> Bool {
    guard let refund, let r = purchaseRecord(refund, leafKey: leafKey), r["revocationDate"] != nil, let id = r["originalTransactionId"] as? String,
          let p = purchaseRecord(jws, leafKey: leafKey) else { return false }
    return p["originalTransactionId"] as? String == id
}

/// The contents of Apple's signed record of the Dateline unlock (refunded or not), when it is for this app and product and Apple's certificates vouch for its signature.
public nonisolated func purchaseRecord(_ jws: String, leafKey: ([Data], Date) -> P256.Signing.PublicKey? = appleLeafKey) -> [String: Any]? {
    let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, let hd = b64url(parts[0]), let pd = b64url(parts[1]), let sd = b64url(parts[2]),
          let h = (try? JSONSerialization.jsonObject(with: hd)) as? [String: Any], h["alg"] as? String == "ES256",
          let x5c = h["x5c"] as? [String], x5c.count == 3, case let certs = x5c.compactMap({ Data(base64Encoded: $0) }), certs.count == 3,
          let p = (try? JSONSerialization.jsonObject(with: pd)) as? [String: Any],
          p["bundleId"] as? String == "com.johnhesch.dateline", p["productId"] as? String == License.productID,
          let signed = p["signedDate"] as? Double,
          let key = leafKey(certs, Date(timeIntervalSince1970: signed / 1000)),
          let sig = try? P256.Signing.ECDSASignature(rawRepresentation: sd),
          key.isValidSignature(sig, for: Data("\(parts[0]).\(parts[1])".utf8)) else { return nil }
    return p
}

nonisolated func b64url<S: StringProtocol>(_ s: S) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    t += String(repeating: "=", count: (4 - t.count % 4) % 4)
    return Data(base64Encoded: t)
}

/// The signing key of an App Store record, when its three certificates lead to Apple Root CA - G3 (checked offline, at the record's date)
/// and carry Apple's App Store markers (leaf 1.2.840.113635.100.6.11.1, middle 1.2.840.113635.100.6.2.1), as Apple's own server library checks.
// shortcut: no online check that Apple withdrew a certificate; fine for a $29.99 unlock, add OCSP if forged records ever show up.
public nonisolated func appleLeafKey(_ certs: [Data], at date: Date) -> P256.Signing.PublicKey? {
    let oid = { (a: UInt8, b: UInt8) in Data([0x06, 0x0A, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x63, 0x64, 0x06, a, b]) }
    let sec = certs.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    guard sec.count == 3, let root = SecCertificateCreateWithData(nil, appleRootG3 as CFData),
          certs[0].range(of: oid(0x0B, 0x01)) != nil, certs[1].range(of: oid(0x02, 0x01)) != nil else { return nil }
    var trust: SecTrust?
    guard SecTrustCreateWithCertificates(sec as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust,
          SecTrustSetAnchorCertificates(trust, [root] as CFArray) == errSecSuccess, SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
          SecTrustSetVerifyDate(trust, date as CFDate) == errSecSuccess, SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
          SecTrustEvaluateWithError(trust, nil), let k = SecCertificateCopyKey(sec[0]), let raw = SecKeyCopyExternalRepresentation(k, nil) as Data? else { return nil }
    return try? P256.Signing.PublicKey(x963Representation: raw)
}

/// Apple Root CA - G3 (https://www.apple.com/certificateauthority/AppleRootCA-G3.cer, SHA-256 63343ABF...3E9179, the same as in macOS's own root list).
public let appleRootG3 = Data(base64Encoded: "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==")!

/// Pure, for the self-test: 7 days from the first open, counted in whole days left (the last day says 1).
/// When the trial began: the earlier of this device's saved start and Apple's record of the free trial item.
public nonisolated func trialStart(saved: Date?, store: Date?) -> Date? {
    [saved, store].compactMap { $0 }.min()
}

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
    guard num.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(num), let s = b64url(k[k.index(after: dot)...]), s.count == 64 else { return nil }
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
    // App Store records, signed here by a stand-in key in place of Apple's certificates.
    let apple = P256.Signing.PrivateKey(), stand: ([Data], Date) -> P256.Signing.PublicKey? = { _, _ in apple.publicKey }
    func enc(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    func record(_ change: [String: Any] = [:], by k: P256.Signing.PrivateKey? = nil) -> String {
        let c = (["bundleId": "com.johnhesch.dateline", "productId": License.productID, "signedDate": 1.8e12, "environment": "Production", "originalTransactionId": "2000000001"] as [String: Any]).merging(change) { $1 }
        let hp = enc(try! JSONSerialization.data(withJSONObject: ["alg": "ES256", "x5c": ["AA==", "AA==", "AA=="]])) + "." + enc(try! JSONSerialization.data(withJSONObject: c))
        return hp + "." + enc(try! (k ?? apple).signature(for: Data(hp.utf8)).rawRepresentation)
    }
    let rec = record(), parts = rec.split(separator: ".")
    expect(purchaseValid(rec, leafKey: stand), "App Store: Apple's signed record of the unlock counts")
    expect(!purchaseValid(record(by: P256.Signing.PrivateKey()), leafKey: stand), "App Store: a record signed by anyone else is refused")
    expect(!purchaseValid(record(["bundleId": "com.other.app"]), leafKey: stand) && !purchaseValid(record(["productId": "other"]), leafKey: stand), "App Store: another app's or product's record is refused")
    expect(!purchaseValid(record(["revocationDate": 1.9e12]), leafKey: stand), "App Store: a refunded record is refused")
    expect(!purchaseValid("\(parts[0]).\(record(["productId": "x"]).split(separator: ".")[1]).\(parts[2])", leafKey: stand), "App Store: a record changed after signing is refused")
    expect(!purchaseValid(rec) && !purchaseValid("junk", leafKey: stand) && !purchaseValid("", leafKey: stand), "App Store: without Apple's certificates, or broken, it is refused")
    expect(SecCertificateCreateWithData(nil, appleRootG3 as CFData) != nil && appleLeafKey([appleRootG3, appleRootG3, appleRootG3], at: Date()) == nil, "App Store: Apple's root reads; a chain without Apple's App Store markers is refused")
    expect(pickKey(local: nil, cloud: rec, check: { purchaseValid($0, leafKey: stand) ? 0 : nil }) == .adopt(rec), "App Store: the Mac takes a good record from iCloud")
    expect(!purchaseValid(rec, leafKey: stand, revoked: ["2000000001"]), "App Store: a record shut off by hand is refused")
    let refundRec = record(["revocationDate": 1.9e12])
    expect(purchaseRefunded(rec, by: refundRec, leafKey: stand), "App Store: Apple's refund record locks the purchase it names")
    expect(!purchaseRefunded(record(["originalTransactionId": "2000000002"]), by: refundRec, leafKey: stand) && !purchaseRefunded(rec, by: rec, leafKey: stand) && !purchaseRefunded(rec, by: nil, leafKey: stand), "App Store: a later purchase, an unrefunded record or no record locks nothing")
    expect(!purchaseRefunded(rec, by: record(["revocationDate": 1.9e12], by: P256.Signing.PrivateKey()), leafKey: stand), "App Store: a refund record not signed by Apple locks nothing")
    let start = Date(timeIntervalSince1970: 1_800_000_000), day = 86400.0
    expect(trialStatus(started: start, now: start, serial: nil) == .trial(daysLeft: 7), "trial: 7 days left on the first day")
    expect(trialStatus(started: start, now: start + 2.5 * day, serial: nil) == .trial(daysLeft: 5), "trial: 5 days left half way through day 3")
    expect(trialStatus(started: start, now: start + 6.9 * day, serial: nil) == .trial(daysLeft: 1), "trial: the last day says 1")
    expect(trialStatus(started: start, now: start + 7 * day, serial: nil) == .ended, "trial: ended after 7 days")
    expect(trialStatus(started: start, now: start - 30 * day, serial: nil) == .trial(daysLeft: 7), "trial: setting the clock back never adds days")
    expect(trialStatus(started: start, now: start + 30 * day, serial: 586300) == .bought(serial: 586300), "trial: a key ends it for good")
    expect(trialStart(saved: nil, store: start) == start && trialStart(saved: nil, store: nil) == nil, "trial: Apple's free trial record starts it")
    expect(trialStart(saved: start + day, store: start) == start && trialStart(saved: start, store: start + 9 * day) == start, "trial: reinstalling never restarts it (earliest start wins)")
    expect(trialStatus(started: .distantPast, now: start, serial: nil) == .ended && trialStatus(started: .distantPast, now: start, serial: 586300) == .bought(serial: 586300), "trial: not started yet means no editing, unless bought")
}

