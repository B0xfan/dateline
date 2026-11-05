// Settings and Trial and unlock (approved mockups). The unlock works with the Mac's buyer keys; buying through Apple comes with the App Store step.
import SwiftUI
import DatelineCore

struct SettingsView: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @ObservedObject private var license = License.shared
    @AppStorage("syncExtras") private var sync = true  // step 2: Store.syncOn reads it; the Mac has no switch, so it syncs always

    var body: some View {
        NavigationStack(path: $app.settingsPath) {
            List {
                Section {
                    Button { app.showUnlock = true } label: { line(nil, .clear, statusName, statusDetail.isEmpty ? "Unlock" : statusDetail) }.buttonStyle(.plain)
                } header: { Text("Dateline") }
                Section {
                    link("accounts", "person.crop.circle.fill", Palette.work, "Accounts", "\(Set(store.calendars.map(\.account)).count)")
                    link("sets", "square.stack.fill", Palette.family, "Calendar sets", "\(store.sets.count)")
                    link("look", "paintbrush.fill", Palette.tags[5], "Look", Look.appearance == "Match Mac" ? "Auto" : Look.appearance)
                    link("week", "calendar", Palette.tags[7], "Week", weekSummary)
                    link("alerts", "bell.fill", Palette.tags[3], "Alerts", Alerts.soundName("events"))
                    link("weather", "cloud.sun.fill", Palette.personal, "Time & weather", WeatherPrefs.fahrenheit ? "°F" : "°C")
                } header: { Text("Same as the Mac's settings tabs") }
                Section {
                    Toggle("Emoji, colors, tags, notes, sets", isOn: $sync)
                        .onChange(of: sync) { _, on in if on { store.syncNow() } }
                } header: { Text("Sync with your Mac") } footer: {
                    Text((store.sync.problem.map { $0 + "\n\n" } ?? "") + "Through your own iCloud. Look and °F or °C you change here change on the Mac too.\n\nMac only, not on the phone: menu bar icon, Quick add shortcut key, Assistant for AI apps, A4 tasks, Check for Updates.")
                }
                Section("About") {
                    let info = Bundle.main.infoDictionary ?? [:]
                    LabeledContent("Version", value: "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))")  // the TestFlight build number
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: String.self) { page in
                Group {
                    switch page {
                    case "accounts": AccountsPage()
                    case "sets": SetsPage()
                    case "look": LookPage()
                    case "week": WeekPage()
                    case "alerts": AlertsPage()
                    case "weather": WeatherPage()
                    default: AccountCalendars(account: page)
                    }
                }
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 90) }
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 90) }
        }
    }

    private var weekSummary: String {
        let all = (0..<7).map { (WorkWeek.firstWeekday - 1 + $0) % 7 + 1 }, at = all.indices.filter { WorkWeek.days.contains(all[$0]) }
        guard let a = at.first, let b = at.last else { return "No days" }
        let names = at.map { cal.shortWeekdaySymbols[all[$0] - 1] }
        return at.count > 2 && b - a + 1 == at.count ? names[0] + "–" + names.last! : names.joined(separator: ", ")  // Mon–Fri, but Mon, Wed, Fri spelled out
    }

    private var statusName: String {
        switch license.status {
        case .bought: return "Unlocked"
        case .trial(let n): return "Free trial, \(n) day\(n == 1 ? "" : "s") left"
        case .ended: return "Free trial ended"
        }
    }
    private var statusDetail: String { if case .bought(let s) = license.status, s > 0 { return "Mac key" }; return "" }

    private func link(_ page: String, _ icon: String, _ color: Color, _ title: String, _ value: String) -> some View {
        NavigationLink(value: page) { line(icon, color, title, value, opens: false) }
    }
}

// One settings row: a colored icon, the name, its value and (for a button) an arrow.
func line(_ icon: String?, _ color: Color, _ title: String, _ value: String, opens: Bool = true) -> some View {
    HStack(spacing: 12) {
        if let icon { Image(systemName: icon).font(.footnote.weight(.semibold)).foregroundStyle(.white).frame(width: 28, height: 28).background(color, in: RoundedRectangle(cornerRadius: 7)) }
        Text(title).foregroundStyle(T.text)
        Spacer()
        Text(value).foregroundStyle(T.text2)
        if opens { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(T.text2.opacity(0.6)) }
    }
    .font(.callout).frame(minHeight: 32).contentShape(Rectangle())
}

// The shared settings are plain saved values, not watched: each page redraws itself (`tick`) after a change.
// Look, sounds and °F/°C are in SyncSettings.keys, so syncNow sends them to the Mac; the other choices stay on this phone.

private func openURL(_ s: String) { if let u = URL(string: s) { UIApplication.shared.open(u) } }

struct AccountsPage: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let accounts = Dictionary(grouping: store.calendars, by: \.account).map { (name: $0.key, cals: $0.value) }.sorted { $0.name < $1.name }
        List {
            Section {
                ForEach(accounts, id: \.name) { a in
                    NavigationLink(value: a.name) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name).foregroundStyle(T.text)
                            Text("\(a.cals.count) calendar\(a.cals.count == 1 ? "" : "s") · \(a.cals.filter { !store.hidden.contains($0.id) }.count) shown").font(.footnote).foregroundStyle(T.text2)
                        }
                    }
                }
            } footer: { Text("Tap an account to show or hide each of its calendars.") }
            Section {
                Button("Add an account in iPhone Settings…") { openURL(UIApplication.openSettingsURLString) }
            } footer: { Text("On the iPhone, accounts live in Settings › Apps › Calendar › Calendar Accounts. Dateline shows every calendar added there.") }
        }
        .navigationTitle("Accounts")
    }
}

struct AccountCalendars: View {
    @EnvironmentObject var store: Store
    let account: String
    var body: some View {
        List {
            ForEach(store.calendars.filter { $0.account == account }) { c in
                Toggle(isOn: Binding(get: { !store.hidden.contains(c.id) }, set: { if $0 { store.hidden.remove(c.id) } else { store.hidden.insert(c.id) } })) {
                    HStack(spacing: 10) { Circle().fill(c.color).frame(width: 12, height: 12); Text(c.title) }
                }
            }
        }
        .navigationTitle(account)
    }
}

struct SetsPage: View {
    @EnvironmentObject var store: Store
    @State private var editing: CalSet?
    var body: some View {
        let active = store.activeSet
        List {
            Section {
                Button { store.use(nil) } label: { pick("Everything", "\(store.calendars.count) calendars", on: active == nil && store.hidden.isEmpty) }.buttonStyle(.plain)
                ForEach(store.sets) { s in
                    HStack {
                        Button { store.use(s) } label: { pick(s.name, "\(s.calendars.count) calendar\(s.calendars.count == 1 ? "" : "s")", on: active?.id == s.id) }.buttonStyle(.plain)
                        Button { editing = s } label: { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(T.text2.opacity(0.6)).frame(width: 44, height: 44) }
                            .buttonStyle(.plain).accessibilityLabel("Edit \(s.name)")
                    }
                }
            } header: { Text("Showing now") } footer: { Text("Tap a set to show only its calendars. Tap › to rename it, pick its calendars, or delete it. Sets are shared with your Mac.") }
        }
        .navigationTitle("Calendar sets")
        .toolbar { Button("New set") { editing = CalSet(name: "New set", calendars: store.calendars.filter { !store.hidden.contains($0.id) }.map(\.id)) } }
        .sheet(item: $editing) { SetEditor(draft: $0) }
    }

    private func pick(_ name: String, _ detail: String, on: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark").font(.callout.weight(.semibold)).foregroundStyle(T.tint).opacity(on ? 1 : 0).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) { Text(name).foregroundStyle(T.text); Text(detail).font(.footnote).foregroundStyle(T.text2) }
            Spacer()
        }
        .frame(minHeight: 44).contentShape(Rectangle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct SetEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var draft: CalSet
    var body: some View {
        let isNew = !store.sets.contains { $0.id == draft.id }
        NavigationStack {
            Form {
                Section("Name") { TextField("Name", text: $draft.name) }
                Section("Calendars in this set") {
                    ForEach(store.calendars) { c in
                        Toggle(isOn: Binding(get: { draft.calendars.contains(c.id) }, set: { on in
                            if on { draft.calendars.append(c.id) } else { draft.calendars.removeAll { $0 == c.id } }
                        })) {
                            HStack(spacing: 10) { Circle().fill(c.color).frame(width: 12, height: 12); Text(c.title); Text(c.account).font(.footnote).foregroundStyle(T.text2) }
                        }
                    }
                }
                if !isNew {
                    Section { Button("Delete this set", role: .destructive) { store.deleteSet(draft.id); dismiss() } }
                }
            }
            .navigationTitle(isNew ? "New set" : "Edit set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
                        if let i = store.sets.firstIndex(where: { $0.id == draft.id }) { store.sets[i] = draft } else { store.sets.append(draft) }
                        dismiss()
                    }.disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.calendars.isEmpty)
                }
            }
        }
    }
}

struct LookPage: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @State private var tick = 0
    var body: some View {
        let _ = tick  // redraws after a change without rebuilding the list (which would jump to the top)
        List {
            Section("Appearance") {
                Picker("Appearance", selection: bind(Look.appearance) { Look.appearance = $0 }) {
                    ForEach(Look.appearances, id: \.self) { Text($0 == "Match Mac" ? "Auto" : $0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            Section {
                Picker("Font", selection: bind(Look.font) { Look.font = $0 }) { ForEach(Look.fonts, id: \.self) { Text($0) } }
                Picker("How packed", selection: bind(Look.pack) { Look.pack = $0 }) { ForEach(Look.packs, id: \.self) { Text($0) } }
                Picker("Hour height", selection: bind(Look.hour) { Look.hour = $0 }) { ForEach(Look.hours, id: \.self) { Text($0) } }
            } footer: { Text("Text size on the phone follows the iPhone's own Text Size setting, so the Mac's Text size choice is not repeated here.") }
            Section {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.work).frame(width: 4, height: 20 * Look.packFactor + 8)
                    Text("Client call").fontWeight(.semibold); Text("10 AM").foregroundStyle(T.text2)
                }
                .font(.system(size: 15, design: Look.design)).padding(.vertical, 4 * Look.packFactor)
            } header: { Text("Preview") } footer: { Text("Shared with the Mac: change it here or there, both follow.") }
        }
        .navigationTitle("Look")
    }

    private func bind(_ v: String, _ set: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: { v }, set: { set($0); tick += 1; app.lookChanged(); store.syncNow() })
    }
}

struct WeekPage: View {
    @EnvironmentObject var app: PhoneState
    @State private var tick = 0
    var body: some View {
        let _ = tick
        let order = (0..<7).map { (WorkWeek.firstWeekday - 1 + $0) % 7 + 1 }
        List {
            Section {
                Picker("Week starts on", selection: Binding(get: { WorkWeek.start }, set: { WorkWeek.start = $0; changed() })) {
                    ForEach(WorkWeek.starts, id: \.self) { Text($0 == "Match Mac" ? "Match iPhone" : $0) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Working days")
                    HStack(spacing: 6) {
                        ForEach(order, id: \.self) { wd in
                            let on = WorkWeek.days.contains(wd)
                            Button { if on { WorkWeek.days.remove(wd) } else { WorkWeek.days.insert(wd) }; changed() } label: {
                                Text(String(cal.veryShortWeekdaySymbols[wd - 1])).font(.callout.weight(on ? .semibold : .regular))
                                    .foregroundStyle(on ? .white : T.text2).frame(maxWidth: .infinity, minHeight: 40)
                                    .background(on ? T.tint : T.bg, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(cal.weekdaySymbols[wd - 1]).accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }.padding(.vertical, 4)
                HStack {
                    Text("Working hours")
                    Spacer()
                    time(WorkWeek.from, in: 0..<WorkWeek.to) { WorkWeek.from = $0 }
                    Text("to").foregroundStyle(T.text2)
                    time(WorkWeek.to, in: (WorkWeek.from + 30)..<1441) { WorkWeek.to = $0 }
                }
                Toggle("Stripe the hours outside work", isOn: Binding(get: { WorkWeek.stripe }, set: { WorkWeek.stripe = $0; changed() }))
                Toggle("Show sunrise, sunset and the moon", isOn: Binding(get: { WorkWeek.sun }, set: { WorkWeek.sun = $0; changed() }))
            }
            Section {
                Toggle("Alert me when it's time to leave", isOn: Binding(get: { WorkWeek.leave }, set: { WorkWeek.leave = $0; changed() }))
                Button { app.tab = .places } label: { line(nil, .clear, "Places and drive times", "") }.buttonStyle(.plain)
            } header: { Text("Leave alerts") } footer: { Text("Uses the phone's location for the drive time, the same places as the Mac.") }
        }
        .navigationTitle("Week")
    }

    private func changed() { tick += 1; app.reload() }

    private func time(_ v: Int, in range: Range<Int>, _ set: @escaping (Int) -> Void) -> some View {
        Menu {
            ForEach(Array(stride(from: range.lowerBound - range.lowerBound % 30, to: range.upperBound, by: 30)), id: \.self) { m in
                Button(minuteText(m)) { set(m); changed() }
            }
        } label: { Text(minuteText(v)).foregroundStyle(T.tint) }
    }
}

struct AlertsPage: View {
    var body: some View {
        List {
            Section {
                line(nil, .clear, "Event alerts", "iPhone Calendar", opens: false)
                line(nil, .clear, "Mac sounds", Alerts.kinds.prefix(2).map { Alerts.soundName($0.0) }.joined(separator: ", "), opens: false)
            } footer: { Text("Each event's alert time comes with the event, so the iPhone rings for it like any calendar alert. Sounds and banners follow the iPhone's own settings.") }
            Section {
                Button("Open notification settings…") { openURL(UIApplication.openNotificationSettingsURLString) }
            } footer: { Text("The Mac's full screen alert and its sound choices stay on the Mac.") }
        }
        .navigationTitle("Alerts")
    }
}

struct WeatherPage: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @State private var tick = 0
    @State private var city = ""
    @State private var finding = false
    @State private var note: String?
    var body: some View {
        let _ = tick
        List {
            Section {
                Toggle("Show the weather on days and events", isOn: Binding(get: { WeatherPrefs.on }, set: { WeatherPrefs.on = $0; changed() }))
                Picker("Temperature", selection: Binding(get: { WeatherPrefs.fahrenheit }, set: { WeatherPrefs.fahrenheit = $0; changed(); store.syncNow() })) {
                    Text("°F").tag(true); Text("°C").tag(false)
                }.pickerStyle(.segmented)
                if !WeatherPrefs.town.isEmpty {
                    Picker("Town for the days", selection: Binding(get: { WeatherPrefs.townGeo != nil }, set: { on in
                        if !on { WeatherPrefs.town = ""; WeatherPrefs.townGeo = nil }; changed()
                    })) {
                        Text("Where I am").tag(false); Text(WeatherPrefs.town.components(separatedBy: ",").first ?? WeatherPrefs.town).tag(true)
                    }
                } else { line(nil, .clear, "Town for the days", "Where I am", opens: false) }
            } header: { Text("Weather") } footer: { Text("Weather data by Open-Meteo.com") }
            Section {
                ForEach(Zones.list) { z in
                    HStack {
                        Text(z.nick.isEmpty ? z.city : z.nick)
                        Spacer()
                        Text(zoneTime(app.today, z.tz)).foregroundStyle(T.text2)
                    }
                }
                .onDelete { Zones.list.remove(atOffsets: $0); changed() }
                HStack {
                    TextField("Add a city", text: $city).submitLabel(.done).onSubmit(add)
                    if finding { ProgressView() } else if !city.isEmpty { Button("Add", action: add) }
                }
            } header: { Text("Time zones") } footer: { Text(note ?? "Swipe a city left to remove it. The Mac's sidebar card choice stays on the Mac.") }
        }
        .navigationTitle("Time & weather")
    }

    private func changed() { tick += 1; app.reload() }

    private func add() {
        let q = city.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !finding else { return }
        finding = true
        Task {
            let z = await findZone(q)
            finding = false
            if let z { Zones.list.append(z); city = ""; note = nil; changed() } else { note = "No time zone found for \"\(q)\". Try the city's full name." }
        }
    }

    private func zoneTime(_ d: Date, _ tz: String) -> String {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; f.timeZone = TimeZone(identifier: tz); return f.string(from: d)
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
