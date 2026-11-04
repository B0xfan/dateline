// The 7 day free trial and buyer keys (approved mockup trial-mockups.html, John 2026-11-03).
// When the trial ends the calendar stays to look at; adding, changing and deleting events is off until a key is entered.
// Keys are made on John's Mac by scripts/keys.js and checked here with no internet.
import SwiftUI
import CryptoKit
import AppKit

// shortcut: the trial start and key sit in the app's settings, so deleting those restarts the trial; the code is public anyway (stops normal buyers, as planned).
@MainActor final class License: ObservableObject {
    static let shared = License()
    // Raw Ed25519 public keys (base64) from `node scripts/keys.js init`. A new one is added, never swapped, so sold keys keep working.
    nonisolated static let publicKeys = ["u+BvQLDQy2Qetmnv32FkcALoKJKB0NoL6hMZJUCF6R8="]
    nonisolated static let revoked: Set<Int> = []  // refunded keys, by number
    nonisolated static let trialDays = 7
    static let buyURL = URL(string: "https://payhip.com/b/P4iIX")!
    static let price = "$29.99"
    static let endedMessage = "Your free trial has ended. Your calendar is still here to look at. Buy Dateline, or enter the key you got by email, to add and change events again."

    enum Status: Equatable { case trial(daysLeft: Int), ended, bought(serial: Int) }

    // Only the real app reads and saves the trial; the test and picture modes never touch the saved settings.
    private let live = !CommandLine.arguments.contains { ["--sample", "--render", "--selftest", "--follow-check", "--timing-ui", "--timing", "--a4-check", "--key-check", "--accounts-check", "--email-check", "--assistant"].contains($0) }
    private(set) var started: Date
    @Published private(set) var serial: Int?
    @Published var test: Status?  // set by --render to draw each state
    @Published var now = Date()  // moved on by the window's clock, so the days left count down while Dateline stays open

    private init() {
        let d = UserDefaults.standard
        if live, let s = d.object(forKey: "trialStarted") as? Date { started = s } else { started = Date() }
        if live, d.object(forKey: "trialStarted") == nil { d.set(started, forKey: "trialStarted") }
        serial = live ? d.string(forKey: "licenseKey").flatMap { keySerial($0) } : nil
    }

    /// Redraws the trial parts only when a clock tick changes the days left or ends the trial.
    func tick(_ d: Date) { if live, test == nil, trialStatus(started: started, now: d, serial: serial) != status { now = d } }

    var status: Status { test ?? (live ? trialStatus(started: started, now: now, serial: serial) : .bought(serial: 0)) }
    var canEdit: Bool { if case .ended = status { return false }; return true }
    var trialEnds: Date { started.addingTimeInterval(Double(Self.trialDays) * 86400) }

    /// Saves the key when it is good; false leaves everything as it was.
    func enter(_ key: String) -> Bool {
        guard let s = keySerial(key) else { return false }
        if live { UserDefaults.standard.set(key.filter { !$0.isWhitespace }, forKey: "licenseKey") }
        serial = s; test = nil
        return true
    }

    func buy() { NSWorkspace.shared.open(Self.buyURL) }
}

/// Pure, for the self-test: 7 days from the first open, counted in whole days left (the last day says 1).
func trialStatus(started: Date, now: Date, serial: Int?) -> License.Status {
    if let serial { return .bought(serial: serial) }
    let left = started.addingTimeInterval(Double(License.trialDays) * 86400).timeIntervalSince(now)
    return left > 0 ? .trial(daysLeft: min(Int((left / 86400).rounded(.up)), License.trialDays)) : .ended  // never more than 7, even with the clock set back
}

/// The key's number when it is a good Dateline key: DLK-K<6 digits>.<86-char base64url Ed25519 signature of "K<6 digits>">.
nonisolated func keySerial(_ key: String, publicKeys: [String] = License.publicKeys, revoked: Set<Int> = License.revoked) -> Int? {
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

private func lockIcon() -> some View { Image(systemName: "lock").font(.ui(11, weight: .semibold)) }

/// The card at the bottom of the sidebar: days left during the trial (orange on the last 2), "Trial ended" after. Gone once bought.
struct TrialCard: View {
    @ObservedObject var lic = License.shared
    var body: some View {
        switch lic.status {
        case .bought: EmptyView()
        case .trial(let left):
            card(late: left <= 2) {
                if left == 1 {
                    Text("Last day of your trial").font(.ui(12, weight: .semibold)).foregroundStyle(Palette.family)
                    Text("Your calendar stays, but you can't add or change events after today.").font(.ui(12)).foregroundStyle(Palette.text2)
                } else {
                    (Text("Free trial").fontWeight(.semibold).foregroundColor(left <= 2 ? Palette.family : Palette.text) + Text(" · \(left) days left"))
                        .font(.ui(12)).foregroundStyle(Palette.text2)
                }
            }
        case .ended: card(late: false) { Text("Trial ended").font(.ui(12, weight: .semibold)) }
        }
    }
    func card<V: View>(late: Bool, @ViewBuilder _ text: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            text().lineLimit(3)
            Button("Buy Dateline") { License.shared.buy() }.buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.win))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(late ? Palette.family : Palette.line))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

/// The strip above the calendar once the trial has ended.
struct TrialEndedStrip: View {
    @ObservedObject var lic = License.shared
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        if case .ended = lic.status {
            HStack(spacing: 14) {
                lockIcon().foregroundStyle(Palette.accent)
                (Text("Your free trial has ended.").fontWeight(.semibold).foregroundColor(Palette.text) + Text(" You can still see your calendar. Buy Dateline to add and change events again."))
                    .foregroundStyle(Palette.text2).lineLimit(2)
                Spacer(minLength: 0)
                Button("Enter key") { openLicense(openSettings) }
                Button("Buy · \(License.price)") { lic.buy() }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 9).fill(Palette.accentSoft))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line))
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
        }
    }
}

@MainActor func openLicense(_ openSettings: OpenSettingsAction) { UserDefaults.standard.set("license", forKey: "settingsTab"); openSettings() }

/// Settings, License: the trial or the bought state, Buy, and the box for the key.
struct LicenseSettings: View {
    @ObservedObject var lic = License.shared
    @State private var key = ""
    @State private var wrong = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch lic.status {
            case .bought(let n):
                head("checkmark", Palette.personal, "Dateline is yours. Thank you!", n > 0 ? "Key #\(n)" : "")
                Text("Lost the key? It's in the email from Payhip. A new Mac uses the same key.").font(.ui(12)).foregroundStyle(Palette.text3)
            case .trial(let left):
                head("clock", Palette.accent, "Free trial: \(left) \(left == 1 ? "day" : "days") left",
                     "Started \(dateText(lic.started, "MMM d")). Ends \(dateText(lic.trialEnds, "MMM d")). After that your calendar stays, but adding and changing events is off until you enter a key.")
                buyAndKey
            case .ended:
                head("lock", Palette.accent, "Your free trial has ended", "Your calendar is still here to look at. Buy Dateline, or enter your key, to add and change events again.")
                buyAndKey
            }
        }
        .font(.ui(13))
        .padding(.horizontal, 24).padding(.vertical, 20).frame(width: 620, alignment: .leading)
    }

    func head(_ icon: String, _ color: Color, _ title: String, _ sub: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.ui(17, weight: .semibold)).foregroundStyle(color)
                .frame(width: 38, height: 38).background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(15, weight: .semibold))
                if !sub.isEmpty { Text(sub).font(.ui(12)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    @ViewBuilder var buyAndKey: some View {
        HStack(spacing: 10) {
            Button("Buy Dateline · \(License.price)") { lic.buy() }.buttonStyle(.borderedProminent)
            Text("15 days to ask for a refund").foregroundStyle(Palette.text3)
        }
        Text("ALREADY BOUGHT IT?").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3)
        HStack(spacing: 8) {
            TextField("Paste your key here", text: $key).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                .onSubmit(unlock).onChange(of: key) { _, _ in wrong = false }
            Button("Unlock", action: unlock).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if wrong { Text("That key doesn't look right. Check the email from Payhip and paste the whole key.").font(.ui(11.5)).foregroundStyle(Palette.now) }
    }

    func unlock() { wrong = !lic.enter(key); if !wrong { key = "" } }
}

// MARK: self-test

func licenseSelftest(_ expect: (Bool, String) -> Void) {
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
    let start = Date(timeIntervalSince1970: 1_800_000_000), day = 86400.0
    expect(trialStatus(started: start, now: start, serial: nil) == .trial(daysLeft: 7), "trial: 7 days left on the first day")
    expect(trialStatus(started: start, now: start + 2.5 * day, serial: nil) == .trial(daysLeft: 5), "trial: 5 days left half way through day 3")
    expect(trialStatus(started: start, now: start + 6.9 * day, serial: nil) == .trial(daysLeft: 1), "trial: the last day says 1")
    expect(trialStatus(started: start, now: start + 7 * day, serial: nil) == .ended, "trial: ended after 7 days")
    expect(trialStatus(started: start, now: start - 30 * day, serial: nil) == .trial(daysLeft: 7), "trial: setting the clock back never adds days")
    expect(trialStatus(started: start, now: start + 30 * day, serial: 586300) == .bought(serial: 586300), "trial: a key ends it for good")
}
