// Phase 7 (F4, F5, approved mockup): calendars from a web address, and a short list of ready-made ones.
// Read-only and kept by Dateline on this Mac: the address is read every hour, day or week, and the last copy stays when it stops working.
// The iCalendar reading and repeat rules here are pure, covered by --selftest.
import Foundation
import SwiftUI
import AppKit

struct Sub: Codable, Identifiable, Equatable {
    var id = "sub-" + UUID().uuidString
    var url: String  // https address; empty for a calendar worked out here (`kind`)
    var kind: String? = nil  // "moon" or "sun": made on this Mac, no address
    var name: String
    var color: Int  // a place in Palette.tags
    var hours = 24  // how often it updates
    var alerts = false
    var updated: Date? = nil
    var problem: String? = nil  // why the last update failed; the last events stay
}

func isSub(_ calendarID: String) -> Bool { calendarID.hasPrefix("sub-") }

// One VEVENT, as read from the file.
struct ICalEvent: Equatable {
    var uid = "", title = "", place = "", notes = ""
    var start = Date(), end = Date()
    var allDay = false, free = false, cancelled = false
    var tz = TimeZone.current
    var rule: [String: String]? = nil
    var exdates: Set<Date> = []
    var recurrenceID: Date? = nil  // set on a changed copy of one occurrence of a repeating event
}

// MARK: reading the file

func parseICS(_ text: String) -> [ICalEvent] {
    var lines: [String] = []
    for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n") {
        if let f = raw.first, f == " " || f == "\t", !lines.isEmpty { lines[lines.count - 1] += raw.dropFirst() } else { lines.append(String(raw)) }
    }
    var out: [ICalEvent] = [], props: [(String, [String: String], String)]? = nil, depth = 0
    for l in lines {
        guard let (name, params, value) = icsLine(l) else { continue }
        if name == "BEGIN" { if props == nil { if value.uppercased() == "VEVENT" { props = []; depth = 0 } } else { depth += 1 }; continue }
        if name == "END", props != nil {
            if depth > 0 { depth -= 1 } else { if let e = icsEvent(props!) { out.append(e) }; props = nil }
            continue
        }
        if depth == 0 { props?.append((name, params, value)) }  // never an alarm's own SUMMARY
    }
    return out
}

// "DTSTART;TZID="America/New_York":20261030T160000" → name, parameters, value. A colon inside quotes is not the split.
private func icsLine(_ l: String) -> (String, [String: String], String)? {
    var quoted = false, split: String.Index?
    for i in l.indices { if l[i] == "\"" { quoted.toggle() } else if l[i] == ":" && !quoted { split = i; break } }
    guard let split else { return nil }
    var parts = l[..<split].split(separator: ";").map(String.init)
    guard !parts.isEmpty else { return nil }
    let name = parts.removeFirst().uppercased()
    var params: [String: String] = [:]
    for p in parts { let kv = p.split(separator: "=", maxSplits: 1).map(String.init); if kv.count == 2 { params[kv[0].uppercased()] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } }
    return (name, params, String(l[l.index(after: split)...]))
}

private func icsText(_ v: String) -> String {
    v.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\N", with: "\n")
        .replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";").replacingOccurrences(of: "\\\\", with: "\\")
}

// A date or date-time value: (moment, all-day, its time zone). All-day dates are midnight here.
func icsDate(_ v: String, _ params: [String: String]) -> (Date, Bool, TimeZone)? {
    let allDay = params["VALUE"] == "DATE" || v.count == 8
    let utc = v.hasSuffix("Z")
    // shortcut: a TZID that is not a standard place name (some Outlook files) reads as this Mac's time zone; map Windows names if a real calendar needs it.
    let tz = utc ? TimeZone(identifier: "UTC")! : params["TZID"].flatMap { id in TimeZone(identifier: id) ?? TimeZone(identifier: id.split(separator: "/").suffix(2).joined(separator: "/")) } ?? cal.timeZone
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = allDay ? cal.timeZone : tz
    f.dateFormat = allDay ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss"
    guard let d = f.date(from: String(v.prefix(allDay ? 8 : 15))) else { return nil }
    return (d, allDay, tz)
}

// "PT1H30M", "P1D", "-PT15M" → seconds.
func icsDuration(_ s: String) -> TimeInterval {
    var total = 0.0, num = ""
    for ch in s {
        if ch.isNumber { num.append(ch); continue }
        let v = Double(num) ?? 0
        num = ""
        switch ch { case "W": total += v * 604800; case "D": total += v * 86400; case "H": total += v * 3600; case "M": total += v * 60; case "S": total += v; default: break }
    }
    return s.hasPrefix("-") ? -total : total
}

private func icsEvent(_ props: [(String, [String: String], String)]) -> ICalEvent? {
    var e = ICalEvent(), end: Date?, duration: TimeInterval?, hasStart = false
    for (name, params, v) in props {
        switch name {
        case "UID": e.uid = v
        case "SUMMARY": e.title = icsText(v)
        case "LOCATION": e.place = icsText(v)
        case "DESCRIPTION": e.notes = icsText(v)
        case "TRANSP": e.free = v.uppercased() == "TRANSPARENT"
        case "STATUS": e.cancelled = v.uppercased() == "CANCELLED"
        case "DTSTART": guard let (d, a, tz) = icsDate(v, params) else { return nil }; e.start = d; e.allDay = a; e.tz = tz; hasStart = true
        case "DTEND": end = icsDate(v, params)?.0
        case "DURATION": duration = icsDuration(v)
        case "RRULE": e.rule = Dictionary(v.split(separator: ";").compactMap { p -> (String, String)? in
                let kv = p.split(separator: "=", maxSplits: 1).map(String.init); return kv.count == 2 ? (kv[0].uppercased(), kv[1].uppercased()) : nil }, uniquingKeysWith: { a, _ in a })
        case "EXDATE": for one in v.split(separator: ",") { if let d = icsDate(String(one), params)?.0 { e.exdates.insert(d) } }
        case "RECURRENCE-ID": e.recurrenceID = icsDate(v, params)?.0
        default: break
        }
    }
    guard hasStart else { return nil }
    e.end = end ?? duration.map { e.start.addingTimeInterval($0) } ?? (e.allDay ? addDays(e.start, 1) : e.start)
    if e.end < e.start { e.end = e.start }
    return e
}

// MARK: repeats

// Every start of `e` that overlaps a..b (the first one is DTSTART). Repeats by day, week, month and year, with the usual parts.
func occurrences(_ e: ICalEvent, from a: Date, to b: Date) -> [Date] {
    let len = e.end.timeIntervalSince(e.start)
    func overlaps(_ d: Date) -> Bool { d < b && (d.addingTimeInterval(len) > a || (len == 0 && d >= a)) }
    // shortcut: rules by the hour or minute, or with BYSETPOS/BYWEEKNO/BYYEARDAY, show the first time only; add them if a real calendar needs one.
    guard let r = e.rule, let freq = r["FREQ"], ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].contains(freq),
          r["BYSETPOS"] == nil, r["BYWEEKNO"] == nil, r["BYYEARDAY"] == nil else { return overlaps(e.start) ? [e.start] : [] }
    var c = Calendar(identifier: .gregorian)
    c.timeZone = e.allDay ? cal.timeZone : e.tz
    let names = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
    c.firstWeekday = (names.firstIndex(of: r["WKST"] ?? "MO") ?? 1) + 1
    let step = max(1, Int(r["INTERVAL"] ?? "") ?? 1)
    let count = Int(r["COUNT"] ?? "")
    let until = r["UNTIL"].flatMap { icsDate($0, e.allDay ? [:] : ["TZID": e.tz.identifier])?.0 }  // no Z: the event's own time zone
    // BYDAY: "MO,WE" or "2TU", "-1FR" → (which one in the month, 0 = every; weekday 1 = Sunday)
    let byDay: [(Int, Int)] = (r["BYDAY"] ?? "").split(separator: ",").compactMap { p in
        guard p.count >= 2, let w = names.firstIndex(of: String(p.suffix(2))) else { return nil }
        return (Int(p.dropLast(2)) ?? 0, w + 1)
    }
    let byMonthDay = (r["BYMONTHDAY"] ?? "").split(separator: ",").compactMap { Int($0) }
    let byMonth = (r["BYMONTH"] ?? "").split(separator: ",").compactMap { Int($0) }
    let t = c.dateComponents([.hour, .minute, .second], from: e.start)
    func day(_ y: Int, _ m: Int, _ d: Int) -> Date? {
        guard let x = c.date(from: DateComponents(year: y, month: m, day: d, hour: t.hour, minute: t.minute, second: t.second)),
              c.component(.month, from: x) == m else { return nil }  // Feb 31 does not exist: skipped, as the rules say
        return x
    }
    func inMonth(_ y: Int, _ m: Int) -> [Date] {
        guard let first = day(y, m, 1) else { return [] }
        let last = c.range(of: .day, in: .month, for: first)!.count
        if !byDay.isEmpty {
            return byDay.flatMap { n, w -> [Date] in
                let all = (1...last).compactMap { day(y, m, $0) }.filter { c.component(.weekday, from: $0) == w }
                if n == 0 { return all }
                let i = n > 0 ? n - 1 : all.count + n
                return all.indices.contains(i) ? [all[i]] : []
            }
        }
        let days = byMonthDay.isEmpty ? [c.component(.day, from: e.start)] : byMonthDay
        return days.compactMap { day(y, m, $0 > 0 ? $0 : last + 1 + $0) }
    }
    let y0 = c.component(.year, from: e.start), m0 = c.component(.month, from: e.start)
    let week0 = c.dateInterval(of: .weekOfYear, for: e.start)!.start
    var out: [Date] = [], made = 0
    for period in 0..<5000 {  // shortcut: 5000 steps (13 years of daily repeats) from the first time; later times of an older daily event are not shown
        var list: [Date]
        switch freq {
        case "DAILY": list = [c.date(byAdding: .day, value: period * step, to: e.start)!]
        case "WEEKLY":
            let wk = c.date(byAdding: .weekOfYear, value: period * step, to: week0)!
            let days = byDay.isEmpty ? [c.component(.weekday, from: e.start)] : byDay.map(\.1)
            list = days.compactMap { w in
                let off = (w - c.firstWeekday + 7) % 7
                let d = c.date(byAdding: .day, value: off, to: wk)!
                return day(c.component(.year, from: d), c.component(.month, from: d), c.component(.day, from: d))
            }
        case "MONTHLY":
            let mm = m0 - 1 + period * step
            list = inMonth(y0 + mm / 12, mm % 12 + 1)
        default:
            list = (byMonth.isEmpty ? [m0] : byMonth).flatMap { inMonth(y0 + period * step, $0) }
        }
        // BYMONTH narrows every rule; BYDAY and BYMONTHDAY narrow a daily one (weekly, monthly and yearly use them to pick days above).
        list = list.filter { d in
            (byMonth.isEmpty || byMonth.contains(c.component(.month, from: d))) && (freq != "DAILY" ||
            ((byDay.isEmpty || byDay.contains { $0.1 == c.component(.weekday, from: d) }) && (byMonthDay.isEmpty || byMonthDay.contains(c.component(.day, from: d)))))
        }
        if period == 0 { list.append(e.start) }  // the first time always counts, even off the rule's days
        for d in Set(list).sorted() where d >= e.start {
            if let until, d > until { return out }
            made += 1
            if let count, made > count { return out }
            if d >= b { return out }
            if overlaps(d) && !e.exdates.contains(d) { out.append(d) }
        }
    }
    return out
}

// The events of one subscribed calendar between two dates, as Dateline items. A changed occurrence replaces the one it changes.
func subItems(_ s: Sub, _ events: [ICalEvent], from a: Date, to b: Date) -> [Item] {
    var changed: [String: Set<Date>] = [:]
    for e in events { if let r = e.recurrenceID { changed[e.uid, default: []].insert(r) } }
    var out: [Item] = []
    for e in events where !(e.cancelled && e.recurrenceID == nil) {
        let len = e.end.timeIntervalSince(e.start)
        let starts = e.recurrenceID != nil ? (e.cancelled ? [] : occurrences(ICalEvent(start: e.start, end: e.end), from: a, to: b))
            : occurrences(e, from: a, to: b).filter { !(changed[e.uid]?.contains($0) ?? false) }
        for d in starts {
            let at = e.recurrenceID ?? d  // the occurrence's own key stays the same when it was moved
            out.append(Item(id: "\(s.id)/\(e.uid)|\(Int(at.timeIntervalSince1970))", calendarID: s.id, title: e.title, start: d, end: d.addingTimeInterval(len),
                            allDay: e.allDay, place: e.place, notes: e.notes, showAs: e.free ? .free : .busy,
                            alerts: s.alerts && !e.allDay ? [d] : []))
        }
    }
    return out
}

// The calendars made on this Mac: one all-day line a day.
@MainActor func madeItems(_ s: Sub, from a: Date, to b: Date) -> [Item] {
    var out: [Item] = [], d = cal.startOfDay(for: a)
    while d < b {
        var title: String?
        if s.kind == "moon", let m = moonDay(d) {
            title = [MoonDay.new: "🌑 New moon", .firstHalf: "🌓 First quarter", .full: "🌕 Full moon", .lastHalf: "🌗 Last quarter"][m]
        } else if s.kind == "sun", let g = Here.shared.spot, let t = sunTimes(d, at: g) {
            title = "☀ " + timeText(t.rise, short: false) + " · " + timeText(t.set, short: false)
        }
        if let title {
            out.append(Item(id: "\(s.id)/\(Int(d.timeIntervalSince1970))", calendarID: s.id, title: title, start: d, end: addDays(d, 1),
                            allDay: true, place: "", notes: "", showAs: .free))
        }
        d = addDays(d, 1)
    }
    return out
}

// webcal:// is how calendar links are often shared; it is plain https underneath.
func subAddress(_ text: String) -> URL? {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.lowercased().hasPrefix("webcal://") { t = "https://" + t.dropFirst(9) }
    guard let u = URL(string: t), ["https", "http"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else { return nil }
    return u
}

// Downloads and reads a calendar; the file's text comes back so it can be kept for when the address stops working.
func downloadCalendar(_ u: URL) async -> Result<(String, [ICalEvent]), Failure> {
    var req = URLRequest(url: u, timeoutInterval: 30)
    req.setValue("text/calendar", forHTTPHeaderField: "Accept")
    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { return .failure(Failure("The address answered with error \(h.statusCode).")) }
        guard data.count < 20_000_000, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              text.contains("BEGIN:VCALENDAR") else { return .failure(Failure("That address is not a calendar. Look for a link ending in .ics or starting with webcal://.")) }
        let events = await Task.detached { parseICS(text) }.value
        return .success((text, events))
    } catch { return .failure(Failure("Couldn't reach it: \(error.localizedDescription)")) }
}

// MARK: the Store side

extension Store {
    static let subFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Dateline/Subscribed")

    var subInfos: [CalInfo] { subs.map { CalInfo(id: $0.id, title: $0.name, account: "Subscribed", color: Palette.tags[$0.color % Palette.tags.count], writable: false) } }

    func sub(_ id: String) -> Sub? { subs.first { $0.id == id } }

    func subEvents(from a: Date, to b: Date) -> [Item] {
        subs.flatMap { s in (s.kind == nil ? subItems(s, subParsed[s.id] ?? [], from: a, to: b) : madeItems(s, from: a, to: b)).map(decorated) }
    }

    // After a calendar is added, renamed, recolored or removed.
    func subsChanged() {
        calendars = calendars.filter { !isSub($0.id) } + subInfos
        refetch()
    }

    func loadSubs() {
        if let v: [Sub] = load("subscriptions") { subs = v }
        for s in subs where s.kind == nil {
            if let text = try? String(contentsOf: Self.subFolder.appendingPathComponent(s.id + ".ics"), encoding: .utf8) { subParsed[s.id] = parseICS(text) }
        }
    }

    // Adds a calendar; `text`/`events` when the Subscribe window already downloaded it.
    func subscribe(_ s: Sub, text: String? = nil, events: [ICalEvent]? = nil) {
        var s = s
        if let text, let events { keep(text, for: s.id); subParsed[s.id] = events; s.updated = Date() }
        subs.append(s)
        subsChanged()
        if s.kind == nil && text == nil { refreshSub(s.id) }
    }

    func unsubscribe(_ id: String) {
        subs.removeAll { $0.id == id }
        subParsed[id] = nil
        hidden.remove(id)
        for i in sets.indices { sets[i].calendars.removeAll { $0 == id } }
        try? FileManager.default.removeItem(at: Self.subFolder.appendingPathComponent(id + ".ics"))
        subsChanged()
    }

    func editSub(_ id: String, _ change: (inout Sub) -> Void) {
        guard let i = subs.firstIndex(where: { $0.id == id }) else { return }
        change(&subs[i])
        subsChanged()
    }

    // Every 5 minutes: the calendars whose time has come. A failed one tries again after an hour.
    func refreshSubs() {
        guard access != .sample else { return }
        let now = Date()
        for s in subs where s.kind == nil {
            let last = subTried[s.id] ?? s.updated ?? .distantPast
            if now.timeIntervalSince(last) >= Double(s.problem == nil ? s.hours : min(s.hours, 1)) * 3600 { refreshSub(s.id) }
        }
    }

    func refreshSub(_ id: String) {
        guard access != .sample, let s = sub(id), s.kind == nil else { return }
        subTried[id] = Date()
        guard let u = subAddress(s.url) else { editSub(id) { $0.problem = "The address is not a web address." }; return }
        Task {
            let r = await downloadCalendar(u)
            guard sub(id) != nil else { return }  // removed while it downloaded
            switch r {
            case .success(let (text, events)):
                keep(text, for: id)
                subParsed[id] = events
                editSub(id) { $0.updated = Date(); $0.problem = nil }
            case .failure(let f): editSub(id) { $0.problem = f.message }
            }
        }
    }

    private func keep(_ text: String, for id: String) {
        try? FileManager.default.createDirectory(at: Self.subFolder, withIntermediateDirectories: true)
        try? text.write(to: Self.subFolder.appendingPathComponent(id + ".ics"), atomically: true, encoding: .utf8)
    }
}

// MARK: the ready-made list (free public addresses, each checked to work on 2026-10-28; moon and sun are worked out on this Mac)

struct ReadyMade: Identifiable {
    let name, about, group: String
    var url = "", kind: String? = nil
    let color: Int
    var id: String { name }
}

let readyMade = [
    ReadyMade(name: "Costa Rica holidays", about: "Public holidays and days off, in English", group: "Holidays",
              url: "https://calendar.google.com/calendar/ical/en.cr%23holiday%40group.v.calendar.google.com/public/basic.ics", color: 0),
    ReadyMade(name: "Feriados de Costa Rica", about: "The same holidays, in Spanish", group: "Holidays",
              url: "https://calendar.google.com/calendar/ical/es.cr%23holiday%40group.v.calendar.google.com/public/basic.ics", color: 0),
    ReadyMade(name: "United States holidays", about: "Federal holidays plus Thanksgiving, Halloween and others", group: "Holidays",
              url: "https://calendar.google.com/calendar/ical/en.usa%23holiday%40group.v.calendar.google.com/public/basic.ics", color: 4),
    ReadyMade(name: "Moon phases", about: "New moon, full moon and the quarters", group: "Sky", kind: "moon", color: 7),
    ReadyMade(name: "Sunrise and sunset", about: "For where this Mac is, one all-day note each day", group: "Sky", kind: "sun", color: 1),
    ReadyMade(name: "Costa Rica national football team", about: "Match dates and kick-off times", group: "Sports",
              url: "https://pub.fotmob.com/prod/pub/api/v2/calendar/team/6705.ics", color: 2),
]

// MARK: the Subscribe window (approved mockup: web address tab, ready-made tab)

struct SubscribeSheet: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @State var tab = 0
    @State var address = ""
    @State var name = ""
    @State var color = 3
    @State var hours = 24
    @State var alerts = false
    @State var checking = false
    @State var found: (String, [ICalEvent])?
    @State var problem: String?
    @State var group = "All"
    @State var checked = ""  // the address `found` belongs to

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $tab) { Text("Web address").tag(0); Text("Ready-made").tag(1) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240).frame(maxWidth: .infinity)
            if tab == 0 { web } else { ready }
        }
        .padding(.horizontal, 26).padding(.vertical, 20)
        .frame(width: 580)
        .background(Palette.pop)
        .font(.ui(13))
    }

    var web: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Subscribe to a calendar").font(.ui(15, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Paste a calendar's web address", text: $address).textFieldStyle(.roundedBorder)
                    Button("Paste") { if let s = NSPasteboard.general.string(forType: .string) { address = s } }
                }
                Text("Addresses that start with webcal:// or https:// both work.").font(.ui(11.5)).foregroundStyle(Palette.text3)
            }
            if checking {
                HStack(spacing: 7) { ProgressView().controlSize(.small); Text("Checking the address…").foregroundStyle(Palette.text2) }.font(.ui(12))
            } else if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.ui(12)).foregroundStyle(Palette.now).fixedSize(horizontal: false, vertical: true)
            } else if let events = found?.1 {
                let next = upcoming(events)
                Label("Found it: \(events.count) event\(events.count == 1 ? "" : "s")" + (next.first.map { ", the next one " + when($0.start) } ?? ", none coming up"),
                      systemImage: "checkmark.circle.fill").font(.ui(12)).foregroundStyle(Palette.tags[2])
                if !next.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("COMING UP IN THIS CALENDAR").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3)
                        ForEach(next) { it in
                            HStack(spacing: 8) {
                                Circle().fill(Palette.tags[color]).frame(width: 8, height: 8)
                                Text(dateText(it.start, "EEE MMM d")).foregroundStyle(Palette.text3).monospacedDigit().frame(width: 76, alignment: .leading)
                                Text(it.title + (it.allDay ? "" : ", " + timeText(it.start))).lineLimit(1)
                            }
                        }
                    }
                    .font(.ui(12)).padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Palette.side)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line))
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow { Text("Name").foregroundStyle(Palette.text2); TextField("", text: $name).textFieldStyle(.roundedBorder) }
                GridRow { Text("Color").foregroundStyle(Palette.text2); Swatches(pick: $color) }
                GridRow {
                    Text("Update").foregroundStyle(Palette.text2)
                    Picker("", selection: $hours) { Text("Every hour").tag(1); Text("Every day").tag(24); Text("Every week").tag(168) }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                GridRow { Text("Alerts").foregroundStyle(Palette.text2); Toggle("Alert me for these events", isOn: $alerts).toggleStyle(.switch).controlSize(.small) }
            }
            Divider().overlay(Palette.line)
            HStack {
                Text("You can't change these events; they come from the address.").font(.ui(12)).foregroundStyle(Palette.text3)
                Spacer()
                Button("Cancel") { app.subscribing = false }.keyboardShortcut(.cancelAction)
                Button("Subscribe") { add() }.keyboardShortcut(.defaultAction).disabled(found == nil || checking)
            }
        }
        .task(id: address) {
            guard address != checked || found == nil else { return }  // back to a checked address after an error: check it again
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

    var ready: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                ForEach(["All", "Holidays", "Sky", "Sports"], id: \.self) { g in
                    Button(g) { group = g }.buttonStyle(.plain).font(.ui(12))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .foregroundStyle(group == g ? .white : Palette.text2)
                        .background(Capsule().fill(group == g ? Palette.accent : .clear))
                        .overlay(Capsule().strokeBorder(group == g ? Palette.accent : Palette.line))
                }
            }
            VStack(spacing: 0) {
                let list = readyMade.filter { group == "All" || $0.group == group }
                ForEach(list) { r in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).fontWeight(.semibold)
                            Text(r.about).font(.ui(11.5)).foregroundStyle(Palette.text3)
                        }
                        Spacer()
                        if added(r) { Label("Added", systemImage: "checkmark").font(.ui(12)).foregroundStyle(Palette.tags[2]) }
                        else { Button("Add") { store.subscribe(Sub(url: r.url, kind: r.kind, name: r.name, color: r.color, hours: 168)) } }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    if r.id != list.last?.id { Divider().overlay(Palette.lineSoft) }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line))
            Text("The list is small on purpose and free: each one is a public web address checked to work before it went in. More can come in a later update.")
                .font(.ui(11.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Palette.line)
            HStack {
                let n = readyMade.filter(added).count
                Text(n == 0 ? "None added" : "\(n) added").font(.ui(12)).foregroundStyle(Palette.text3)
                Spacer()
                Button("Done") { app.subscribing = false }.keyboardShortcut(.defaultAction)
            }
        }
    }

    func added(_ r: ReadyMade) -> Bool { store.subs.contains { r.kind != nil ? $0.kind == r.kind : $0.url == r.url } }

    func upcoming(_ events: [ICalEvent]) -> [Item] {
        let now = sampleToday ?? Date()
        let s = Sub(url: "", name: "", color: color)
        return Array(subItems(s, events, from: now, to: now.addingTimeInterval(400 * 86400)).sorted { $0.start < $1.start }.prefix(3))
    }

    func when(_ d: Date) -> String {
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: sampleToday ?? Date()), to: cal.startOfDay(for: d)).day ?? 99
        return n == 0 ? "today" : n == 1 ? "tomorrow" : n < 7 ? "on " + dateText(d, "EEEE") : "on " + dateText(d, "MMMM d")
    }

    func add() {
        guard let f = found else { return }
        let (text, events) = f
        let n = name.trimmingCharacters(in: .whitespaces)
        store.subscribe(Sub(url: address.trimmingCharacters(in: .whitespacesAndNewlines), name: n.isEmpty ? "Subscribed" : n, color: color, hours: hours, alerts: alerts),
                        text: text, events: events)
        app.subscribing = false
    }
}

// The name the calendar gives itself (X-WR-CALNAME), if any.
func calendarName(_ text: String) -> String? {
    text.split(whereSeparator: \.isNewline).lazy.compactMap { icsLine(String($0)) }.first { $0.0 == "X-WR-CALNAME" }
        .map { icsText($0.2).trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
}

struct Swatches: View {
    @Binding var pick: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(Palette.tags.indices, id: \.self) { i in
                Button { pick = i } label: {
                    Circle().fill(Palette.tags[i]).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Palette.tags[i], lineWidth: 2).padding(-4).opacity(pick == i ? 1 : 0))
                }.buttonStyle(.plain).padding(4)
            }
        }
    }
}

// The "Subscribed" group in the sidebar, with its right-click menu.
struct SubscribedList: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    let row: (CalInfo, AnyView?) -> AnyView
    @State var renaming: Sub?
    @State var newName = ""

    var body: some View {
        if !store.subs.isEmpty {
            Text("Subscribed").font(.ui(11)).foregroundStyle(Palette.text3).padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
            ForEach(store.subs) { s in
                if let c = store.calendar(s.id) {
                    row(c, AnyView(status(s)))
                        .contextMenu {
                            if s.kind == nil { Button("Update now") { store.refreshSub(s.id) } }
                            Button("Rename…") { newName = s.name; renaming = s }
                            Menu("Color") {
                                ForEach(Array(["Red", "Orange", "Green", "Teal", "Blue", "Purple", "Pink", "Gray"].enumerated()), id: \.offset) { i, n in
                                    Button(n) { store.editSub(s.id) { $0.color = i } }
                                }
                            }
                            if s.kind == nil {
                                Toggle("Alert me for these events", isOn: Binding(get: { s.alerts }, set: { v in store.editSub(s.id) { $0.alerts = v } }))
                                Menu("Update") {
                                    ForEach([(1, "Every hour"), (24, "Every day"), (168, "Every week")], id: \.0) { h, n in
                                        Toggle(n, isOn: Binding(get: { s.hours == h }, set: { _ in store.editSub(s.id) { $0.hours = h } }))
                                    }
                                }
                            }
                            Divider()
                            Button("Remove", role: .destructive) { store.unsubscribe(s.id) }
                        }
                }
            }
        }
        Button("+ Add a calendar") { app.subscribing = true }
            .buttonStyle(.plain).font(.ui(12)).foregroundStyle(Palette.accent).padding(.horizontal, 8).padding(.top, 6)
        if !store.subs.isEmpty {
            Text("Right-click a subscribed calendar to update it now, rename it, change its color or remove it.")
                .font(.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8).padding(.top, 4)
        }
        Color.clear.frame(height: 0)
            .alert("Rename calendar", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") {
                    let n = newName.trimmingCharacters(in: .whitespaces)
                    if let s = renaming, !n.isEmpty { store.editSub(s.id) { $0.name = n } }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
    }

    @ViewBuilder func status(_ s: Sub) -> some View {
        if let p = s.problem {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Palette.tags[1]).help(p + " The last events stay until it works again.")
        } else if let u = s.updated {
            let when = cal.isDateInToday(u) ? timeText(u) : dateText(u, "MMM d")
            // A long name keeps its room: the label drops the word "updated" before the name is cut.
            ViewThatFits(in: .horizontal) {
                Text("updated " + when)
                Text(when).fixedSize()
            }.font(.ui(11)).foregroundStyle(Palette.text3).help("Updated " + when)
        }
    }
}

// MARK: sample and self-test

// A small calendar file with the awkward parts real ones have: a folded line, escapes, an alarm inside an event, time zones,
// repeats by week (with a skipped and a moved week), by month and by year, and a cancelled event.
let sampleICS = """
BEGIN:VCALENDAR\r
X-WR-CALNAME:Grade 5 schedule\r
BEGIN:VTIMEZONE\r
TZID:America/Costa_Rica\r
BEGIN:STANDARD\r
DTSTART:19700101T000000\r
TZOFFSETFROM:-0600\r
TZOFFSETTO:-0600\r
END:STANDARD\r
END:VTIMEZONE\r
BEGIN:VEVENT\r
UID:meet\r
DTSTART;TZID=America/Costa_Rica:20261030T160000\r
DTEND;TZID=America/Costa_Rica:20261030T170000\r
SUMMARY:Parent meeting\r
DESCRIPTION:Room 4\\, upstairs\\nBring the form\r
LOCATION:Escuela\r
BEGIN:VALARM\r
SUMMARY:Alarm text that is not the title\r
TRIGGER:-PT15M\r
END:VALARM\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:trip\r
DTSTART;VALUE=DATE:20261102\r
SUMMARY:Field trip to the Museo \r
 Nacional\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:swim\r
DTSTART:20261028T220000Z\r
DURATION:PT45M\r
RRULE:FREQ=WEEKLY;BYDAY=WE,FR;COUNT=6\r
EXDATE:20261104T220000Z\r
SUMMARY:Swim class\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:swim\r
RECURRENCE-ID:20261106T220000Z\r
DTSTART:20261106T230000Z\r
DTEND:20261106T234500Z\r
SUMMARY:Swim class (late)\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:board\r
DTSTART;TZID="America/Costa_Rica":20261110T180000\r
DTEND;TZID="America/Costa_Rica":20261110T190000\r
RRULE:FREQ=MONTHLY;BYDAY=2TU;UNTIL=20270301T000000Z\r
SUMMARY:School board\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:thanks\r
DTSTART;VALUE=DATE:20261126\r
DTEND;VALUE=DATE:20261127\r
RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=4TH\r
SUMMARY:Thanksgiving\r
TRANSP:TRANSPARENT\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:last\r
DTSTART;VALUE=DATE:20261031\r
RRULE:FREQ=MONTHLY;COUNT=4\r
SUMMARY:Month end\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:gone\r
DTSTART;VALUE=DATE:20261113\r
STATUS:CANCELLED\r
SUMMARY:Cancelled day\r
END:VEVENT\r
END:VCALENDAR\r
"""

func subSelftest(_ expect: (Bool, String) -> Void, at: (Int, Int, Int, Int, Int) -> Date) {
    let ev = parseICS(sampleICS)
    expect(ev.count == 8, "8 events read (the time zone block and the alarm are not events)")
    let meet = ev.first { $0.uid == "meet" }
    expect(meet?.title == "Parent meeting" && meet?.notes == "Room 4, upstairs\nBring the form", "title and escaped notes; the alarm's text is not the title")
    expect(meet?.start == at(2026, 10, 30, 16, 0) && meet?.end == at(2026, 10, 30, 17, 0), "time zone by name")
    let trip = ev.first { $0.uid == "trip" }
    expect(trip?.title == "Field trip to the Museo Nacional" && trip?.allDay == true && trip?.end == at(2026, 11, 3, 0, 0), "folded line; an all-day date without an end is one day")
    let s = Sub(id: "sub-t", url: "", name: "t", color: 0)
    let items = subItems(s, ev, from: at(2026, 10, 1, 0, 0), to: at(2027, 12, 31, 0, 0))
    let swim = items.filter { $0.title.hasPrefix("Swim") }.sorted { $0.start < $1.start }.map { ($0.title, $0.start) }
    // Wed 28, Fri 30, Wed 4 (skipped), Fri 6 (moved to 5 PM), Wed 11, Fri 13: 4 PM here (22:00 UTC).
    expect(swim.count == 5 && swim.map(\.1) == [at(2026, 10, 28, 16, 0), at(2026, 10, 30, 16, 0), at(2026, 11, 6, 17, 0), at(2026, 11, 11, 16, 0), at(2026, 11, 13, 16, 0)]
           && swim[2].0 == "Swim class (late)", "weekly repeat: count, skipped week, moved week")
    expect(items.first { $0.title == "Swim class" }?.end == at(2026, 10, 28, 16, 45), "duration")
    let board = items.filter { $0.title == "School board" }.map(\.start)
    expect(board == [at(2026, 11, 10, 18, 0), at(2026, 12, 8, 18, 0), at(2027, 1, 12, 18, 0), at(2027, 2, 9, 18, 0)], "second Tuesday each month, until March")
    expect(items.filter { $0.title == "Thanksgiving" }.map(\.start) == [at(2026, 11, 26, 0, 0), at(2027, 11, 25, 0, 0)], "fourth Thursday of November each year")
    expect(items.first { $0.title == "Thanksgiving" }?.showAs == .free, "TRANSP:TRANSPARENT shows as free")
    expect(items.filter { $0.title == "Month end" }.map(\.start) == [at(2026, 10, 31, 0, 0), at(2026, 12, 31, 0, 0), at(2027, 1, 31, 0, 0), at(2027, 3, 31, 0, 0)],
           "the 31st skips months without one, and the count only counts real ones")
    expect(!items.contains { $0.title == "Cancelled day" }, "cancelled events are left out")
    let week = subItems(s, ev, from: at(2026, 11, 1, 0, 0), to: at(2026, 11, 8, 0, 0))
    expect(week.map(\.title).sorted() == ["Field trip to the Museo Nacional", "Swim class (late)"], "only what overlaps the week")
    expect(Set(items.map(\.id)).count == items.count, "every occurrence has its own id")
    var alerting = s; alerting.alerts = true
    expect(subItems(alerting, ev, from: at(2026, 10, 30, 0, 0), to: at(2026, 10, 31, 0, 0)).first { $0.title == "Parent meeting" }?.alerts == [at(2026, 10, 30, 16, 0)]
           && items.allSatisfy { $0.alerts.isEmpty }, "alerts only when switched on")
    expect(subAddress("webcal://example.com/a.ics")?.absoluteString == "https://example.com/a.ics" && subAddress("ftp://x/y") == nil && subAddress("hello") == nil, "web addresses")
    expect(calendarName(sampleICS) == "Grade 5 schedule", "the calendar's own name")
    expect(icsDuration("P1DT2H") == 93600 && icsDuration("-PT15M") == -900, "durations")
    // Review fixes: rule filters, the first time off the rule's days, UNTIL in the event's own zone, the name's escapes.
    let more = parseICS("""
    BEGIN:VCALENDAR
    X-WR-CALNAME;VALUE=TEXT:Grade 5\\, Room 4
    BEGIN:VEVENT
    UID:weekdays
    SUMMARY:School day
    DTSTART:20261030T090000
    RRULE:FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR;COUNT=3
    END:VEVENT
    BEGIN:VEVENT
    UID:offday
    SUMMARY:Club
    DTSTART:20261027T100000
    RRULE:FREQ=WEEKLY;BYDAY=WE,FR;COUNT=4
    END:VEVENT
    BEGIN:VEVENT
    UID:hawaii
    SUMMARY:Call
    DTSTART;TZID=Pacific/Honolulu:20261124T180000
    RRULE:FREQ=WEEKLY;UNTIL=20261201T180000
    END:VEVENT
    END:VCALENDAR
    """)
    let mi = subItems(s, more, from: at(2026, 10, 1, 0, 0), to: at(2027, 1, 1, 0, 0))
    expect(mi.filter { $0.title == "School day" }.map(\.start).sorted() == [at(2026, 10, 30, 9, 0), at(2026, 11, 2, 9, 0), at(2026, 11, 3, 9, 0)], "daily on weekdays skips the weekend")
    expect(mi.filter { $0.title == "Club" }.map(\.start).sorted() == [at(2026, 10, 27, 10, 0), at(2026, 10, 28, 10, 0), at(2026, 10, 30, 10, 0), at(2026, 11, 4, 10, 0)], "the first time counts even off the rule's days")
    expect(mi.filter { $0.title == "Call" }.count == 2, "UNTIL without Z is in the event's own time zone")
    expect(calendarName("""
    BEGIN:VCALENDAR
    X-WR-CALNAME;VALUE=TEXT:Grade 5\\, Room 4
    """) == "Grade 5, Room 4", "the name with a parameter and an escape")
}
