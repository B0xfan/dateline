// Settings and Trial and unlock (approved mockups). The unlock works with the Mac's buyer keys; buying through Apple comes with the App Store step.
import SwiftUI
import DatelineCore

struct SettingsView: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @ObservedObject private var license = License.shared
    @State private var sync = true  // shortcut: shows the step 2 switch; it saves and syncs nothing until the iCloud sync is built

    var body: some View {
        let accounts = Dictionary(grouping: store.calendars, by: \.account).map { (name: $0.key, count: $0.value.count) }.sorted { $0.name < $1.name }
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(.title.bold()).padding(.horizontal, 16).padding(.top, 52)
            List {
                Section("Accounts") {
                    ForEach(accounts, id: \.name) { a in
                        line(a.name.hasPrefix("Google") ? "globe" : a.name.hasPrefix("iCloud") ? "icloud.fill" : "calendar",
                             a.name.hasPrefix("Google") ? Palette.personal : a.name.hasPrefix("iCloud") ? Palette.work : Palette.tags[7],
                             a.name, "\(a.count) calendar\(a.count == 1 ? "" : "s")")
                    }
                    line(nil, .clear, "Add an account", "")
                }
                Section("Calendar") {
                    line("square.stack.fill", Palette.family, "Calendar sets", "\(store.sets.count)")
                    line("paintbrush.fill", Palette.tags[5], "Look", Look.appearance == "Match Mac" ? "Auto" : Look.appearance)
                    line("bell.fill", Palette.tags[3], "Alert sounds", Alerts.soundName("events"))
                    line("car.fill", Palette.tags[7], "Places and drive times", WorkWeek.leave ? "On" : "Off")
                }
                Section {
                    Toggle("Emoji, colors, tags, notes, sets", isOn: $sync).listRowBackground(T.bg2)
                } header: { Text("Sync with your Mac") } footer: { Text("Through your own iCloud. No Dateline server.") }
                Section("Dateline") {
                    Button { app.showUnlock = true } label: { line(nil, .clear, statusName, statusDetail) }.buttonStyle(.plain).listRowBackground(T.bg2)
                }
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 90) }
        }
        .background(T.bg)
    }

    private var statusName: String {
        switch license.status {
        case .bought: return "Unlocked"
        case .trial(let n): return "Free trial, \(n) day\(n == 1 ? "" : "s") left"
        case .ended: return "Free trial ended"
        }
    }
    private var statusDetail: String { if case .bought(let s) = license.status, s > 0 { return "Mac key" }; return "" }

    private func line(_ icon: String?, _ color: Color, _ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            if let icon { Image(systemName: icon).font(.footnote.weight(.semibold)).foregroundStyle(.white).frame(width: 28, height: 28).background(color, in: RoundedRectangle(cornerRadius: 7)) }
            Text(title).foregroundStyle(T.text)
            Spacer()
            Text(value).foregroundStyle(T.text2)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(T.text2.opacity(0.6))
        }
        .font(.callout).frame(minHeight: 32).contentShape(Rectangle())
        .listRowBackground(T.bg2)
    }
}

struct UnlockView: View {
    @EnvironmentObject var app: PhoneState
    @ObservedObject private var license = License.shared
    @Environment(\.dismiss) private var dismiss
    @State private var askKey = false
    @State private var key = ""
    @State private var note: String?

    var body: some View {
        let status = license.status
        let bought: Bool = { if case .bought = status { return true }; return false }()
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(T.text2).frame(width: 44, height: 44).background(T.bg2, in: Circle())
                }
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 16).padding(.top, 8)
            VStack(spacing: 0) {
                Text(dateText(app.today, "EEE").uppercased()).font(.footnote.bold()).kerning(1)
                Text(dateText(app.today, "d")).font(.system(size: 44, weight: .bold))
            }
            .foregroundStyle(.white).frame(width: 96, height: 96)
            .background(LinearGradient(colors: [Color(red: 1, green: 0.42, blue: 0.35), Color(red: 0.85, green: 0.23, blue: 0.19)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: Color(red: 0.85, green: 0.23, blue: 0.19).opacity(0.35), radius: 10, y: 6)
            .padding(.top, 10).accessibilityHidden(true)
            Text(headline(status)).font(.title.bold()).multilineTextAlignment(.center).padding(.top, 18).padding(.horizontal, 16)
            Text(message(status)).font(.callout).foregroundStyle(T.text2).multilineTextAlignment(.center).padding(.top, 6).padding(.horizontal, 32)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(["One payment, no subscription", "Every future update", "Works with your Mac's extras"], id: \.self) { s in
                    HStack(spacing: 10) { Image(systemName: "checkmark").font(.callout.bold()).foregroundStyle(Palette.personal); Text(s) }
                }
            }
            .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 40).padding(.top, 24)
            Spacer()
            if bought {
                Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity, minHeight: 54) }
                    .font(.headline).foregroundStyle(.white).background(T.tint, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 16).padding(.bottom, 24)
            } else {
                VStack(spacing: 0) {
                    Button { note = Self.storeLater } label: { Text("Unlock Dateline").frame(maxWidth: .infinity, minHeight: 54) }
                        .font(.headline).foregroundStyle(.white).background(T.tint, in: RoundedRectangle(cornerRadius: 14))
                    Text("Paid through the App Store. Price shown by Apple.").font(.footnote).foregroundStyle(T.text2).padding(.top, 6)
                    Button { askKey = true } label: { Text("I bought Dateline for Mac").frame(maxWidth: .infinity, minHeight: 50) }
                        .font(.callout.weight(.semibold)).foregroundStyle(T.tint).background(T.bg2, in: RoundedRectangle(cornerRadius: 14)).padding(.top, 14)
                    HStack(spacing: 24) {
                        Button("Restore purchase") { note = Self.storeLater }.frame(minHeight: 44)
                        Button("Not now") { dismiss() }.frame(minHeight: 44)
                    }
                    .font(.subheadline).foregroundStyle(T.tint).padding(.top, 12)
                }
                .buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 24)
            }
        }
        .background(T.bg)
        .alert("Enter your Mac key", isPresented: $askKey) {
            TextField("DLK-K…", text: $key).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) { key = "" }
            Button("Unlock") {
                note = license.enter(key) ? "Dateline is unlocked. Thank you!" : "That key doesn't look right. Paste the whole key from your email."
                key = ""
            }
        } message: { Text("It's in the email you got when you bought Dateline.") }
        .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) { Button("OK") {} }
    }

    static let storeLater = "Buying inside the app comes with the App Store version. Until then, unlock it with the key from your Mac purchase."

    private func headline(_ s: License.Status) -> String {
        switch s {
        case .trial(let n): return "\(n) day\(n == 1 ? "" : "s") left in your trial"
        case .ended: return "Your free trial has ended"
        case .bought: return "Dateline is unlocked"
        }
    }

    private func message(_ s: License.Status) -> String {
        switch s {
        case .trial: return "Everything works during the \(License.trialDays) free days. After that, unlock Dateline to keep adding and changing events."
        case .ended: return "Your calendar is still here to look at. Unlock Dateline to add and change events again."
        case .bought: return "Thank you for buying Dateline."
        }
    }
}
