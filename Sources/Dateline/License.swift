// The 7 day free trial and buyer keys (approved mockup trial-mockups.html, John 2026-11-03).
// When the trial ends the calendar stays to look at; adding, changing and deleting events is off until a key is entered.
// Keys are made on John's Mac by scripts/keys.js and checked here with no internet.
import SwiftUI
import CryptoKit
import AppKit
import DatelineCore

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

@MainActor func openLicense(_ openSettings: OpenSettingsAction) { UserDefaults.standard.set("quick", forKey: "settingsTab"); openSettings() }

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

