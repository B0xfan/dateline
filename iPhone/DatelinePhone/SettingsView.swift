// Settings and Trial and unlock (approved mockups). The unlock is bought through Apple here; a Mac buyer key arrives through iCloud.
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
                    link("week", "calendar", Palette.tags[7], "Week", Self.weekSummary)
                    link("alerts", "bell.fill", Palette.tags[3], "Alerts", Alerts.soundName("events"))
                    link("weather", "cloud.sun.fill", Palette.personal, "Time & weather", WeatherPrefs.fahrenheit ? "°F" : "°C")
                } header: { Text("Same as the Mac's settings tabs") }
                // Approved mockup "Your Mac" (John 2026-11-19): what shows depends on whether the Mac app has been opened.
                if let mac = MacSeen.last {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "laptopcomputer").font(.footnote.weight(.semibold)).foregroundStyle(.white).frame(width: 28, height: 28).background(.gray, in: RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Dateline is on your Mac").foregroundStyle(T.text)
                                Text("Last opened " + openedText(mac)).font(.footnote).foregroundStyle(T.text2)
                            }
                        }.font(.callout)
                        Toggle(isOn: $sync) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keep in step with the Mac")
                                Text("Emoji, colors, tags, notes and calendar sets").font(.footnote).foregroundStyle(T.text2)
                            }
                        }.onChange(of: sync) { _, on in if on { store.syncNow() } }
                    } header: { Text("Your Mac") } footer: {
                        Text((store.sync.problem.map { $0 + "\n\n" } ?? "") + "Changes go through your own iCloud. Look and °F or °C change on both.")
                    }
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Dateline for Mac is included").foregroundStyle(T.text)
                            Text("Your purchase here unlocks the Mac app too. It adds a menu bar calendar, a quick add shortcut key and A4 tasks.").font(.footnote).foregroundStyle(T.text2)
                        }.font(.callout).padding(.vertical, 2)
                        // Nothing else tells an iPhone or iPad buyer the Mac app exists (John 2026-11-09).
                        Link(destination: URL(string: "https://dateline.app")!) { line("laptopcomputer", .gray, "Download for Mac", "dateline.app") }
                    } header: { Text("Your Mac") } footer: { Text("The Mac app comes from the website, not the App Store.") }
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
                    case "subscribe": SubscribePage()
                    case let id where isSub(id): SubDetail(id: id)
                    default: AccountCalendars(account: page)
                    }
                }
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 90) }
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 90) }
        }
    }

    /// "today at 6:41 AM", "yesterday at 9:02 PM", "Nov 12, 2026 at 8:15 AM".
    private func openedText(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true
        let s = f.string(from: d)
        return Calendar.current.isDateInToday(d) || Calendar.current.isDateInYesterday(d) ? s.prefix(1).lowercased() + s.dropFirst() : s
    }

    static var weekSummary: String {
        let all = (0..<7).map { (WorkWeek.firstWeekday - 1 + $0) % 7 + 1 }, at = all.indices.filter { WorkWeek.days.contains(all[$0]) }
        guard let a = at.first, let b = at.last else { return "No days" }
        let names = at.map { cal.shortWeekdaySymbols[all[$0] - 1] }
        return at.count > 2 && b - a + 1 == at.count ? names[0] + "–" + names.last! : names.joined(separator: ", ")  // Mon–Fri, but Mon, Wed, Fri spelled out
    }

    private var statusName: String {
        switch license.status {
        case .bought: return "Unlocked"
        case .trial(let n): return "Free trial, \(n) day\(n == 1 ? "" : "s") left"
        case .ended: return license.trialNotStarted ? "Free trial not started" : "Free trial ended"
        }
    }
    private var statusDetail: String { if case .bought(let s) = license.status, s > 0 { return "Unlocked" }; return "" }

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
                NavigationLink(value: "subscribe") { Text("Subscribe to a calendar…").foregroundStyle(T.tint) }
            } footer: { Text("A calendar from a web address (a school, a team, holidays), kept on this \(thisDevice). You can't change its events.") }
            Section {
                Button("Add an account in \(thisDevice) Settings…") { openURL(UIApplication.openSettingsURLString) }
            } footer: { Text("On the \(thisDevice), accounts live in Settings › Apps › Calendar › Calendar Accounts. Dateline shows every calendar added there.") }
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
                if isSub(c.id) {  // a subscribed calendar opens its own page: show, rename, color, update, remove
                    NavigationLink(value: c.id) {
                        HStack(spacing: 10) {
                            Circle().fill(c.color).frame(width: 12, height: 12); Text(c.title)
                            Spacer()
                            Text(store.hidden.contains(c.id) ? "Hidden" : store.sub(c.id)?.problem != nil ? "Not updating" : "").foregroundStyle(T.text2)
                        }
                    }
                } else { Toggle(isOn: Binding(get: { !store.hidden.contains(c.id) }, set: { if $0 { store.hidden.remove(c.id) } else { store.hidden.insert(c.id) } })) {
                    HStack(spacing: 10) { Circle().fill(c.color).frame(width: 12, height: 12); Text(c.title) }
                } }
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
                    // The whole row opens the set (John 2026-11-19); showing it is a button inside.
                    Button { editing = s } label: {
                        HStack(spacing: 0) {
                            pick(s.name, "\(s.calendars.count) calendar\(s.calendars.count == 1 ? "" : "s")", on: active?.id == s.id)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(T.text2.opacity(0.6)).frame(width: 44, height: 44)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityHint("Opens the set to show, rename, change or delete it")
                }
            } header: { Text("Showing now") } footer: { Text("Tap a set to show it, rename it, pick its calendars, or delete it. Sets are shared with your Mac.") }
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
                if !isNew, store.activeSet?.id != draft.id, let saved = store.sets.first(where: { $0.id == draft.id }) {
                    Section { Button("Show only this set's calendars") { store.use(saved); dismiss() } }
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
            } footer: { Text("Text size here follows the \(thisDevice)'s own Text Size setting, so the Mac's Text size choice is not repeated here.") }
            Section {
                // Two hours of a day at the chosen hour height, so Font, How packed and Hour height all show (John 2026-11-19: the one-line preview was too small).
                let h = Look.hourHeight
                ZStack(alignment: .topLeading) {
                    ForEach(0..<3) { i in
                        HStack(alignment: .center, spacing: 8) {
                            Text(["10 AM", "11 AM", "Noon"][i]).font(.caption).foregroundStyle(T.text2).frame(width: 48, alignment: .leading)
                            Rectangle().fill(T.text2.opacity(0.2)).frame(height: 1)
                        }.offset(y: CGFloat(i) * h - 7)
                    }
                    previewEvent("Client call", "10 to 11 AM · Zoom", Palette.work).frame(height: h - 2).offset(x: 56, y: 0)
                    previewEvent("Lunch with Sam", "11:30 AM to 12 PM", Palette.tags[2]).frame(height: h / 2 - 2).offset(x: 56, y: h * 1.5)
                }
                .padding(.trailing, 56).frame(height: h * 2 + 8, alignment: .top).padding(.vertical, 8)
                .accessibilityElement(children: .combine).accessibilityLabel("Preview: Client call 10 to 11 AM, Lunch with Sam 11:30 AM")
            } header: { Text("Preview") } footer: { Text("Shared with the Mac: change it here or there, both follow.") }
        }
        .navigationTitle("Look")
    }

    private func bind(_ v: String, _ set: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: { v }, set: { set($0); tick += 1; app.lookChanged(); store.syncNow() })
    }

    /// One event in the preview, drawn like the calendar's own event blocks.
    private func previewEvent(_ title: String, _ time: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).fontWeight(.semibold).lineLimit(1)
            Text(time).foregroundStyle(T.text2).lineLimit(1)
        }
        .font(.system(.subheadline, design: Look.design)).foregroundStyle(T.text)
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4 * Look.packFactor)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(c.opacity(0.18))
        .overlay(alignment: .leading) { Rectangle().fill(c).frame(width: 4) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct WeekPage: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.scenePhase) private var phase
    @State private var tick = 0
    @State private var leaveOff = false  // iOS has banners off for Dateline
    var body: some View {
        let _ = tick
        let order = (0..<7).map { (WorkWeek.firstWeekday - 1 + $0) % 7 + 1 }
        List {
            Section {
                Picker("Opens on", selection: Binding(get: { PhoneState.openOn }, set: { PhoneState.openOn = $0; changed() })) {
                    Text("Where I left it").tag("")
                    ForEach(PhoneState.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                Picker("Week starts on", selection: Binding(get: { WorkWeek.start }, set: { WorkWeek.start = $0; changed() })) {
                    ForEach(WorkWeek.starts, id: \.self) { Text($0 == "Match Mac" ? "Match " + thisDevice : $0) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Working days")
                    // Approved iPad board, option A (John 2026-11-19): seven equal buttons with short names, so the two S and T days never mix up; off days are outlines.
                    HStack(spacing: app.wide ? 8 : 6) {
                        ForEach(order, id: \.self) { wd in
                            let on = WorkWeek.days.contains(wd)
                            Button { if on { WorkWeek.days.remove(wd) } else { WorkWeek.days.insert(wd) }; changed() } label: {
                                Text(cal.shortWeekdaySymbols[wd - 1]).font((app.wide ? Font.body : .callout).weight(on ? .semibold : .medium))
                                    .lineLimit(1).minimumScaleFactor(0.7)
                                    .foregroundStyle(on ? .white : T.text2).frame(maxWidth: .infinity, minHeight: app.wide ? 48 : 40)
                                    .background(on ? T.tint : T.bg, in: RoundedRectangle(cornerRadius: app.wide ? 12 : 10))
                                    .overlay { RoundedRectangle(cornerRadius: app.wide ? 12 : 10).strokeBorder(on ? T.tint : T.line, lineWidth: 1.5) }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(cal.weekdaySymbols[wd - 1]).accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    Text(SettingsView.weekSummary).font(.footnote).foregroundStyle(T.text2)
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
                Toggle("Alert me when it's time to leave", isOn: Binding(get: { WorkWeek.leave }, set: { WorkWeek.leave = $0; changed(); app.planTravel() }))
                Button { app.tab = .places } label: { line(nil, .clear, "Places and drive times", "") }.buttonStyle(.plain)
                if leaveOff && WorkWeek.leave { Button("Open notification settings…") { openURL(UIApplication.openNotificationSettingsURLString) } }
            } header: { Text("Leave alerts") } footer: {
                Text(leaveOff && WorkWeek.leave ? "Notifications are off for Dateline, so leave alerts can't show. Turn on Alerts in notification settings." : "Uses the \(thisDevice)'s location for the drive time, the same places as the Mac.")
            }
            .task(id: phase) { if !app.sample, phase == .active { leaveOff = await DateBadge.isBlocked(nil) } }  // again on coming back from iOS Settings
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
    @EnvironmentObject var app: PhoneState
    @Environment(\.scenePhase) private var phase
    @State private var badge = DateBadge.on
    @State private var blocked = false  // iOS has badges off for Dateline
    var body: some View {
        List {
            Section {
                Toggle("Today's date on the icon", isOn: $badge)
                    .onChange(of: badge) { if app.sample { return }; DateBadge.on = badge; Task { blocked = !(await DateBadge.update(ask: true)) } }
            } footer: {
                Text(blocked && badge ? "Badges are off for Dateline. Turn on Badges in notification settings to see the date." : "The number on Dateline's icon is today's date, as in the \(thisDevice)'s own Calendar. It changes at midnight.")
            }
            .task(id: phase) { if badge, !app.sample, phase == .active { blocked = await DateBadge.isBlocked() } }  // again on coming back from iOS Settings; the app itself re-plans
            Section {
                line(nil, .clear, "Event alerts", thisDevice + " Calendar", opens: false)
                line(nil, .clear, "Mac sounds", Alerts.kinds.prefix(2).map { Alerts.soundName($0.0) }.joined(separator: ", "), opens: false)
            } footer: { Text("Each event's alert time comes with the event, so the \(thisDevice) rings for it like any calendar alert. Sounds and banners follow the \(thisDevice)'s own settings.") }
            Section {
                Button("Open notification settings…") { openURL(UIApplication.openNotificationSettingsURLString) }
            } footer: { Text("The Mac's full screen alert and its sound choices stay on the Mac.") }
        }
        .navigationTitle("Alerts")
    }
}

// Approved mockup "Time & weather" (John 2026-11-19): the town and Add a city both open one city search.
struct WeatherPage: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @State private var tick = 0
    @State private var searching: CitySearch.Purpose?
    @State private var naming: Zone?  // the city whose nickname box is open
    @State private var nick = ""
    var body: some View {
        let _ = tick
        List {
            Section {
                Toggle("Show the weather on days and events", isOn: Binding(get: { WeatherPrefs.on }, set: { WeatherPrefs.on = $0; changed() }))
                HStack {
                    Text("Temperature")
                    Spacer()
                    Picker("Temperature", selection: Binding(get: { WeatherPrefs.fahrenheit }, set: { WeatherPrefs.fahrenheit = $0; changed(); store.syncNow() })) {
                        Text("°F").tag(true); Text("°C").tag(false)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Button { searching = .town } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Weather town").foregroundStyle(T.text)
                            Text("The weather on each day comes from here").font(.footnote).foregroundStyle(T.text2)
                        }
                        Spacer()
                        Text(WeatherPrefs.town.isEmpty ? "Where I am" : WeatherPrefs.town).foregroundStyle(T.tint).lineLimit(1)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(T.text2).accessibilityHidden(true)
                    }
                }
            } header: { Text("Weather") } footer: { Text("Events with a place show the weather at that place. Weather data by Open-Meteo.com") }
            Section {
                ForEach(Zones.list) { z in
                    Button { nick = z.nick; naming = z } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(z.nick.isEmpty ? z.city : z.nick).foregroundStyle(T.text)  // the nickname shows in place of the city, as on the Mac
                                Text(z.nick.isEmpty ? String(z.place.dropFirst(z.city.count + 2)) : z.place)  // "London" over "United Kingdom"; "Mom" over "Chicago, United States"
                                    .font(.footnote).foregroundStyle(T.text2).lineLimit(1)
                            }
                            Spacer()
                            Text(zoneTime(app.today, z.tz)).foregroundStyle(T.text2)
                        }
                    }
                }
                .onDelete { Zones.list.remove(atOffsets: $0); changed() }
                .onMove { Zones.list.move(fromOffsets: $0, toOffset: $1); changed() }
                if Zones.list.count < Zones.most {
                    Button { searching = .zone } label: { Label("Add a city", systemImage: "plus.circle.fill").fontWeight(.medium) }
                }
            } header: { Text("Other time zones") } footer: { Text("Up to \(Zones.most) cities.") }
        }
        .navigationTitle("Time & weather")
        .toolbar { if Zones.list.count > 1 { EditButton() } }
        .sheet(item: $searching) { CitySearch(purpose: $0) { changed() } }
        .alert(naming.map { "Nickname for \($0.city)" } ?? "", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField(naming?.city ?? "", text: $nick)
            Button("Save") { setNick(nick) }
            Button("Remove the city", role: .destructive) { if let z = naming { Zones.list.removeAll { $0.id == z.id }; changed() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func changed() { tick += 1; app.reload() }

    private func setNick(_ v: String) {
        guard let z = naming, let i = Zones.list.firstIndex(where: { $0.id == z.id }) else { return }
        Zones.list[i].nick = v.trimmingCharacters(in: .whitespaces); changed()
    }
}

/// One search for both the weather town and a new time zone city: matches as you type, each with its time now.
struct CitySearch: View {
    enum Purpose: String, Identifiable { case town, zone; var id: String { rawValue } }
    let purpose: Purpose
    let done: () -> Void
    @EnvironmentObject var app: PhoneState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool
    @State private var text = ""
    @State private var found: [Town] = []
    @State private var note: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(T.text2).accessibilityHidden(true)
                        TextField("City", text: $text).focused($typing).submitLabel(.search).autocorrectionDisabled()
                            .onSubmit { if let m = found.first { pick(m) } else { Task { await lookUp() } } }
                        if busy { ProgressView() }
                    }
                }
                if purpose == .town, !WeatherPrefs.town.isEmpty {
                    Section { Button("Where I am") { WeatherPrefs.town = ""; WeatherPrefs.townGeo = nil; finish() } }
                }
                if !found.isEmpty {
                    Section("Matches") {
                        ForEach(found) { t in
                            Button { pick(t) } label: {
                                HStack {
                                    let parts = t.label.components(separatedBy: ", ")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(parts[0]).foregroundStyle(T.text)
                                        if parts.count > 1 { Text(parts.dropFirst().joined(separator: ", ")).font(.footnote).foregroundStyle(T.text2) }
                                    }
                                    Spacer()
                                    if let tz = t.tz { Text(zoneTime(app.today, tz)).foregroundStyle(T.text2) }
                                }
                            }
                        }
                    }
                } else if let note { Section { Text(note).foregroundStyle(T.text2) } }
            }
            .navigationTitle(purpose == .town ? "Weather town" : "Add a city")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { typing = true }
            .task(id: text) {
                let t = text.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, !WeatherStore.sample else { found = []; note = nil; return }  // the pictures never reach the network
                try? await Task.sleep(for: .milliseconds(300))  // wait for a pause in the typing
                guard !Task.isCancelled else { return }
                let list = await searchTowns(t)
                guard !Task.isCancelled else { return }  // the text changed while this search ran
                found = purpose == .zone ? list.filter { $0.tz != nil } : list
                note = found.isEmpty ? "No city called \u{201C}\(t)\u{201D} found. Try another spelling." : nil
            }
        }
    }

    private func pick(_ t: Town) {
        switch purpose {
        case .town: WeatherPrefs.town = t.label; WeatherPrefs.townGeo = t.geo
        case .zone:
            guard let tz = t.tz, Zones.list.count < Zones.most else { return }
            let parts = t.label.components(separatedBy: ", ")  // "London, England, United Kingdom" is kept as "London, United Kingdom"
            Zones.list.append(Zone(tz: tz, place: parts.count > 2 ? [parts[0], parts.last!].joined(separator: ", ") : t.label))
        }
        finish()
    }

    /// Return with no match yet: Apple Maps, as before, for a time zone; a weather town needs a pick from the list.
    private func lookUp() async {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard purpose == .zone, !q.isEmpty, !busy else { return }
        busy = true; defer { busy = false }
        if let z = await findZone(q), Zones.list.count < Zones.most { Zones.list.append(z); finish() }
        else { note = "No time zone found for \u{201C}\(q)\u{201D}. Try the city's full name." }
    }

    private func finish() { done(); dismiss() }
}

private func zoneTime(_ d: Date, _ tz: String) -> String {
    let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; f.timeZone = TimeZone(identifier: tz); return f.string(from: d)
}

struct UnlockView: View {
    @EnvironmentObject var app: PhoneState
    @ObservedObject private var license = License.shared
    @Environment(\.dismiss) private var dismiss
    @State private var note: String?
    @State private var busy = false

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
                    if license.trialNotStarted {
                        Button(action: startTrial) { Text("Start \(License.trialDays)-day free trial").frame(maxWidth: .infinity, minHeight: 54) }
                            .font(.headline).foregroundStyle(.white).background(T.tint, in: RoundedRectangle(cornerRadius: 14)).disabled(busy).opacity(busy ? 0.6 : 1)
                        Button(action: buy) { Text("Unlock now for \(price)").frame(minHeight: 44) }.font(.subheadline.weight(.semibold)).foregroundStyle(T.tint).disabled(busy).padding(.top, 6)
                    } else {
                        Button(action: buy) { Text("Unlock Dateline").frame(maxWidth: .infinity, minHeight: 54) }
                            .font(.headline).foregroundStyle(.white).background(T.tint, in: RoundedRectangle(cornerRadius: 14)).disabled(busy).opacity(busy ? 0.6 : 1)
                        Text("Paid through the App Store. Price shown by Apple.").font(.footnote).foregroundStyle(T.text2).padding(.top, 6)
                    }
                    Text("Already bought Dateline? It unlocks by itself on an \(thisDevice) signed in to the same Apple Account.").font(.footnote).foregroundStyle(T.text2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).padding(.top, 14)  // wraps, never cut off
                    HStack(spacing: 24) {
                        Button("Restore purchase", action: restore).frame(minHeight: 44).disabled(busy)
                        Button("Not now") { dismiss() }.frame(minHeight: 44)
                    }
                    .font(.subheadline).foregroundStyle(T.tint).padding(.top, 12)
                }
                .buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 24)
            }
        }
        .background(T.bg)
        .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) { Button("OK") {} }
        .task { await license.loadPrice() }
    }

    private func buy() {
        busy = true
        Task {
            switch await license.buyInApp() {
            case .bought: note = "Dateline is unlocked. Thank you!"
            case .pending: note = "Your purchase is waiting for approval. Dateline unlocks by itself once it goes through."
            case .cancelled: break
            case .failed(let m): note = m
            }
            busy = false
        }
    }

    // shortcut: the US price shows until the App Store answers; fine offline on first open, the button itself always charges Apple's local price.
    private var price: String { license.unlockPrice ?? License.price }

    private func startTrial() {
        busy = true
        Task {
            switch await license.startTrial() {
            case .bought: if license.canEdit { dismiss() }  // a reinstall can bring back a trial that already ended; the sheet then shows that
            case .pending: note = "Your trial is waiting for approval. It starts by itself once it goes through."
            case .cancelled: break
            case .failed(let m): note = m
            }
            busy = false
        }
    }

    private func restore() {
        busy = true
        Task {
            await license.restore()
            if case .bought = license.status { note = "Dateline is unlocked. Thank you!" } else { note = "No purchase found for this Apple Account. Bought Dateline for Mac? Enter your key on the Mac once and this \(thisDevice) unlocks by itself." }
            busy = false
        }
    }

    private func headline(_ s: License.Status) -> String {
        switch s {
        case .trial(let n): return "\(n) day\(n == 1 ? "" : "s") left in your trial"
        case .ended: return license.trialNotStarted ? "Try Dateline free for \(License.trialDays) days" : "Your free trial has ended"
        case .bought: return "Dateline is unlocked"
        }
    }

    private func message(_ s: License.Status) -> String {
        switch s {
        case .trial: return "Everything works during the \(License.trialDays) free days. After that, unlock Dateline to keep adding and changing events."
        case .ended where license.trialNotStarted:
            return "Everything works for \(License.trialDays) days, free. After that, your calendar stays here to look at, and adding and changing events needs a one-time unlock for \(price). No subscription."
        case .ended: return "Your calendar is still here to look at. Unlock Dateline to add and change events again."
        case .bought: return "Thank you for buying Dateline."
        }
    }
}

// Subscribe by web address or from the ready-made list, as in the Mac's Subscribe window (phase 7). Kept on this iPhone, read only.
// The Mac's "Alert me for these events" is left out: the phone sends no alerts of its own yet.
struct SubscribePage: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var address = ""
    @State private var name = ""
    @State private var color = 3
    @State private var hours = 24
    @State private var checking = false
    @State private var found: (String, [ICalEvent])?
    @State private var checked = ""  // the address `found` belongs to
    @State private var problem: String?

    var body: some View {
        List {
            Section { Picker("", selection: $tab) { Text("Web address").tag(0); Text("Ready-made").tag(1) }.pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
            if tab == 0 { web } else { ready }
        }
        .navigationTitle("Subscribe")
        .toolbar { if tab == 0 { Button("Subscribe", action: add).fontWeight(.semibold).disabled(found == nil || checking) } }
        .task(id: address) {
            guard address != checked || found == nil else { return }
            found = nil; problem = nil
            guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { checking = false; return }
            guard let u = subAddress(address) else { checking = false; problem = "That isn't a web address. It should start with webcal:// or https://."; return }
            checking = true
            try? await Task.sleep(nanoseconds: 600_000_000)  // wait for typing to stop
            guard !Task.isCancelled else { return }
            if store.subs.contains(where: { subAddress($0.url) == u }) { checking = false; problem = "You're already subscribed to this calendar."; return }
            let r = await downloadCalendar(u)
            guard !Task.isCancelled else { return }
            checking = false
            switch r {
            case .success(let v):
                found = v; checked = address
                if name.isEmpty { name = calendarName(v.0) ?? u.host ?? "Subscribed" }
            case .failure(let f): problem = f.message
            }
        }
    }

    @ViewBuilder private var web: some View {
        Section {
            TextField("webcal:// or https:// address", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            PasteButton(payloadType: String.self) { if let s = $0.first { address = s } }.labelStyle(.titleAndIcon)
        } header: { Text("Web address") } footer: {
            if checking { Text("Checking the address…") }
            else if let problem { Text(problem).foregroundStyle(T.late) }
            else if let events = found?.1 {
                let next = upcoming(events)
                Text("Found it: \(events.count) event\(events.count == 1 ? "" : "s")" + (next.first.map { ", the next one " + when($0.start) } ?? ", none coming up") + ".")
            }
        }
        if let events = found?.1, case let next = upcoming(events), !next.isEmpty {
            Section("Coming up in this calendar") {
                ForEach(next) { it in
                    HStack(spacing: 10) {
                        Circle().fill(Palette.tags[color]).frame(width: 8, height: 8)
                        Text(dateText(it.start, "EEE MMM d")).foregroundStyle(T.text2).monospacedDigit()
                        Text(it.title + (it.allDay ? "" : ", " + timeText(it.start))).lineLimit(1)
                    }.font(.subheadline)
                }
            }
        }
        Section {
            TextField("Name", text: $name)
            SubColors(pick: $color)
            Picker("Update", selection: $hours) { Text("Every hour").tag(1); Text("Every day").tag(24); Text("Every week").tag(168) }
        } footer: { Text("You can't change these events; they come from the address. The last copy stays if the address stops working.") }
    }

    @ViewBuilder private var ready: some View {
        ForEach(["Holidays", "Sky", "Sports"], id: \.self) { g in
            Section(g) {
                ForEach(readyMade.filter { $0.group == g }) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) { Text(r.name); Text(r.about).font(.footnote).foregroundStyle(T.text2) }
                        Spacer()
                        if added(r) { Label("Added", systemImage: "checkmark").labelStyle(.iconOnly).foregroundStyle(Palette.tags[2]).accessibilityLabel("Added") }
                        else { Button("Add") { store.subscribe(Sub(url: r.url, kind: r.kind, name: r.name, color: r.color, hours: 168)) }.buttonStyle(.bordered) }
                    }
                }
            }
        }
    }

    private func added(_ r: ReadyMade) -> Bool { store.subs.contains { r.kind != nil ? $0.kind == r.kind : $0.url == r.url } }

    private func upcoming(_ events: [ICalEvent]) -> [Item] {
        let now = sampleToday ?? Date()
        return Array(subItems(Sub(url: "", name: "", color: color), events, from: now, to: now.addingTimeInterval(400 * 86400)).sorted { $0.start < $1.start }.prefix(3))
    }

    private func when(_ d: Date) -> String {
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: sampleToday ?? Date()), to: cal.startOfDay(for: d)).day ?? 99
        return n == 0 ? "today" : n == 1 ? "tomorrow" : n < 7 ? "on " + dateText(d, "EEEE") : "on " + dateText(d, "MMMM d")
    }

    private func add() {
        guard let (text, events) = found else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        store.subscribe(Sub(url: address.trimmingCharacters(in: .whitespacesAndNewlines), name: n.isEmpty ? "Subscribed" : n, color: color, hours: hours), text: text, events: events)
        dismiss()
    }
}

// One subscribed calendar: show or hide, name, color, how often it updates, update now, remove (the Mac's right-click menu).
struct SubDetail: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var name = ""
    @State private var removing = false

    var body: some View {
        if let s = store.sub(id) {
            List {
                Section {
                    Toggle("Show in the calendar", isOn: Binding(get: { !store.hidden.contains(id) }, set: { if $0 { store.hidden.remove(id) } else { store.hidden.insert(id) } }))
                    TextField("Name", text: $name).onSubmit(rename).submitLabel(.done)
                    SubColors(pick: Binding(get: { s.color }, set: { c in store.editSub(id) { $0.color = c } }))
                }
                if s.kind == nil {
                    Section {
                        Picker("Update", selection: Binding(get: { s.hours }, set: { h in store.editSub(id) { $0.hours = h } })) {
                            Text("Every hour").tag(1); Text("Every day").tag(24); Text("Every week").tag(168)
                        }
                        Button("Update now") { store.refreshSub(id) }
                    } footer: {
                        Text(s.problem.map { $0 + " The last events stay until it works again." } ?? s.updated.map { "Updated " + (cal.isDateInToday($0) ? timeText($0) : dateText($0, "MMM d")) + "." } ?? "")
                    }
                    Section { Text(s.url).font(.footnote).foregroundStyle(T.text2).textSelection(.enabled) } header: { Text("Web address") }
                }
                Section { Button("Remove calendar", role: .destructive) { removing = true } }
            }
            .navigationTitle(s.name)
            .onAppear { name = s.name }
            .onDisappear(perform: rename)
            .confirmationDialog("Remove \(s.name)?", isPresented: $removing, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { store.unsubscribe(id); dismiss() }
            } message: { Text("Its events leave Dateline on this \(thisDevice). You can subscribe again later.") }
        }
    }

    private func rename() {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty, store.sub(id)?.name != n { store.editSub(id) { $0.name = n } }
    }
}

struct SubColors: View {
    @Binding var pick: Int
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Palette.tags.indices, id: \.self) { i in
                Button { pick = i } label: {
                    Circle().fill(Palette.tags[i]).frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(Palette.tags[i], lineWidth: 2).padding(-4).opacity(pick == i ? 1 : 0))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.plain).accessibilityLabel(["Red", "Orange", "Green", "Teal", "Blue", "Purple", "Pink", "Gray"][i])
                .accessibilityAddTraits(pick == i ? .isSelected : [])  // the 8 Palette.tags, in order
            }
        }
    }
}
