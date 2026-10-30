// Phase 8 (approved mockup, section 1): iCloud and Google accounts signed in inside Dateline, with no help from the Mac's settings.
// iCloud speaks CalDAV (email + app-specific password); Google signs in through the browser and speaks its Calendar API.
// Changes show at once and go to the account in the background, one at a time per account; a failed one reloads the calendar.
// The passwords and Google sign-ins live in a private file (never the Keychain, never --sample or a test run).
// The calendar-file writers and the server-answer readers here are pure, covered by --selftest; --accounts-check drives the network code against a stand-in server.
import Foundation
import SwiftUI
import AppKit
import EventKit
import Network
import CryptoKit
import UniformTypeIdentifiers

struct Account: Codable, Identifiable, Equatable {
    var id = "acc-" + UUID().uuidString
    var kind: String  // "icloud" or "google"
    var email: String
    var cals: [AccCal] = []
    var synced: Date? = nil
    var problem: String? = nil
    var carried: Bool? = nil  // the Mac's choices were carried over to this account's calendars (once)
    var name: String { kind == "google" ? "Google" : "iCloud" }
}

// One calendar on an account. `id` is Dateline's calendar id; `remote` is the CalDAV address or Google's calendar id.
struct AccCal: Codable, Equatable {
    var id: String
    var remote: String
    var title: String
    var color: String  // "#RRGGBB"
    var writable: Bool
    var defaultAlerts: [Int] = []  // Google: minutes before, used by events that keep the calendar's own alerts
}

func isAcc(_ calendarID: String) -> Bool { calendarID.hasPrefix("acc-") }
// Dateline's id for an account's calendar: the account's id and a short fingerprint of the calendar's address (never "|", which marks an occurrence).
func calID(_ accountID: String, _ remote: String) -> String {
    accountID + "-" + SHA256.hash(data: Data(remote.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
}

// What Dateline holds of one account's calendar between syncs.
struct DavRes { var etag: String?; var text: String; var events: [ICalEvent] }
struct GEv { var iid: String; var master: String?; var etag: String?; var item: Item }

final class AccData {
    var dav: [String: [String: DavRes]] = [:]  // calendar id → event address → the event file
    var google: [String: [GEv]] = [:]
    var loaded: Set<String> = []  // accounts read this launch: only these hide the Mac's own copy
    var chain: [String: Task<Void, Never>] = [:]
    var pending: [String: Int] = [:]
    var tokens: [String: (String, Date)] = [:]
    var secrets: [String: String]?
    var goneEtag: [String: String] = [:]  // event address → the version a change still going out got, for a delete queued behind it
}

// MARK: the private file

enum AccountSecrets {
    nonisolated(unsafe) static var testMode = false  // --selftest and --accounts-check: never the real file
    static var url: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Dateline/accounts.json") }

    static func read() -> [String: String] {
        guard !testMode, let d = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
    }

    // Only John's Mac account can read it (file 0600, folder 0700). Written whole: a crash leaves the old file or the new one.
    static func write(_ v: [String: String]) throws {
        guard !testMode else { return }
        let dir = url.deletingLastPathComponent(), fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".accounts.\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: try JSONEncoder().encode(v), attributes: [.posixPermissions: 0o600]),
              rename(tmp.path, url.path) == 0 else { unlink(tmp.path); throw Failure("Couldn't save the sign-in on this Mac.") }
    }
}

// MARK: talking to the servers

// Follows a redirect, but a sign-in sent to one server is never carried on to another.
final class KeepSignInHome: NSObject, URLSessionTaskDelegate {
    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest) async -> URLRequest? {
        var n = newRequest
        // Kept only for the same server, or a hop between Apple's own iCloud servers (caldav.icloud.com to p12-caldav.icloud.com).
        let from = task.originalRequest?.url, to = n.url
        func apple(_ h: String) -> Bool { h == "icloud.com" || h.hasSuffix(".icloud.com") }
        let f = from?.host?.lowercased() ?? "", t = to?.host?.lowercased() ?? ""
        let same = !t.isEmpty && to?.scheme == from?.scheme && to?.port == from?.port && (t == f || (to?.scheme == "https" && apple(f) && apple(t)))
        if !same { n.setValue(nil, forHTTPHeaderField: "Authorization") }
        return n
    }
}

enum AccNet {
    nonisolated(unsafe) static var icloudRoot = URL(string: "https://caldav.icloud.com/")!
    nonisolated(unsafe) static var googleAPI = "https://www.googleapis.com/calendar/v3"
    nonisolated(unsafe) static var driveUpload = "https://www.googleapis.com/upload/drive/v3/files"
    nonisolated(unsafe) static var googleToken = URL(string: "https://oauth2.googleapis.com/token")!
    static let googleAuth = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    // Reuses Audrey Mail's Google key for now (John, Oct 30); a Dateline key goes in before it is ever sold.
    nonisolated(unsafe) static var googleClientFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Audrey Mail/google_client.json")

    static func request(_ method: String, _ url: URL, auth: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: url, timeoutInterval: 60)
        r.httpMethod = method
        r.setValue(auth, forHTTPHeaderField: "Authorization")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = body
        let (d, resp): (Data, URLResponse)
        do { (d, resp) = try await URLSession.shared.data(for: r, delegate: KeepSignInHome()) } catch { throw Failure("Couldn't reach the account: \(error.localizedDescription)") }
        guard let h = resp as? HTTPURLResponse else { throw Failure("The account gave no answer.") }
        if h.statusCode == 401 || h.statusCode == 403 && auth.hasPrefix("Basic") { throw Failure("The account refused the sign-in. Remove it and add it again.") }
        return (d, h)
    }

    static func basic(_ email: String, _ pw: String) -> String { "Basic " + Data("\(email):\(pw)".utf8).base64EncodedString() }
}

// A tiny reader for the servers' XML answers: names without their namespace, text, children.
final class XNode {
    let name: String; var text = ""; var kids: [XNode] = []; var attrs: [String: String] = [:]
    init(_ n: String) { name = n }
    func all(_ n: String) -> [XNode] { kids.flatMap { ($0.name == n ? [$0] : []) + $0.all(n) } }
    func first(_ n: String) -> XNode? { all(n).first }
}

func parseXML(_ d: Data) -> XNode? {
    final class P: NSObject, XMLParserDelegate {
        var stack: [XNode] = [XNode("root")]
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
            let n = XNode(e); n.attrs = a; stack.last!.kids.append(n); stack.append(n)
        }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) { if stack.count > 1 { stack.removeLast() } }
        func parser(_ p: XMLParser, foundCharacters s: String) { stack.last!.text += s }
        func parser(_ p: XMLParser, foundCDATA c: Data) { stack.last!.text += String(data: c, encoding: .utf8) ?? "" }
    }
    let x = XMLParser(data: d), p = P()
    x.shouldProcessNamespaces = true
    x.delegate = p
    return x.parse() ? p.stack[0] : nil
}

// The calendars in a CalDAV home's answer: event calendars only, never the inbox, outbox or task lists.
func davCalendars(_ x: XNode, base: URL, accountID: String) -> [AccCal] {
    x.all("response").compactMap { r in
        guard let href = r.first("href")?.text.trimmingCharacters(in: .whitespacesAndNewlines), let u = URL(string: href, relativeTo: base)?.absoluteURL,
              r.first("resourcetype")?.first("calendar") != nil else { return nil }
        // Event calendars only (iCloud lists Reminders lists here too); no list of kinds means any kind.
        if let kinds = r.first("supported-calendar-component-set"), !kinds.all("comp").contains(where: { $0.attrs["name"]?.uppercased() == "VEVENT" }) { return nil }
        let title = r.first("displayname")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var color = r.first("calendar-color")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "#1E88E5"
        if color.count == 9 { color = String(color.prefix(7)) }  // iCloud adds the see-through part
        let privs = r.first("current-user-privilege-set")
        let writable = privs == nil || privs!.first("write") != nil || privs!.first("all") != nil || privs!.first("write-content") != nil
        return AccCal(id: calID(accountID, u.absoluteString), remote: u.absoluteString, title: title.isEmpty ? "Calendar" : title, color: color, writable: writable)
    }
}

// The events in a calendar-query answer: address, version and the event file.
func davEvents(_ x: XNode, base: URL) -> [String: DavRes] {
    var out: [String: DavRes] = [:]
    for r in x.all("response") {
        guard let href = r.first("href")?.text.trimmingCharacters(in: .whitespacesAndNewlines), let u = URL(string: href, relativeTo: base)?.absoluteURL,
              let text = r.first("calendar-data")?.text, text.contains("BEGIN:VCALENDAR") else { continue }
        let etag = r.first("getetag")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        out[u.absoluteString] = DavRes(etag: etag, text: text, events: parseICS(text))
    }
    return out
}

let davProps = """
<?xml version="1.0" encoding="UTF-8"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/">\
<d:prop><d:resourcetype/><d:displayname/><a:calendar-color/><d:current-user-privilege-set/><c:supported-calendar-component-set/></d:prop></d:propfind>
"""

// Finds an iCloud account's calendars: who you are, where your calendars live, then the list.
func icloudCalendars(email: String, password: String, accountID: String) async throws -> [AccCal] {
    let auth = AccNet.basic(email, password)
    func find(_ u: URL, _ prop: String, _ ns: String) async throws -> URL {
        let body = "<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\" xmlns:c=\"\(ns)\"><d:prop><c:\(prop)/></d:prop></d:propfind>"
        let (d, h) = try await AccNet.request("PROPFIND", u, auth: auth, body: Data(body.utf8), headers: ["Depth": "0", "Content-Type": "application/xml"])
        guard h.statusCode == 207, let href = parseXML(d)?.first(prop)?.first("href")?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              let out = URL(string: href, relativeTo: h.url ?? u)?.absoluteURL else { throw Failure("iCloud didn't answer as expected (error \(h.statusCode)).") }
        return out
    }
    let principal = try await find(AccNet.icloudRoot, "current-user-principal", "DAV:")
    let home = try await find(principal, "calendar-home-set", "urn:ietf:params:xml:ns:caldav")
    let (d, h) = try await AccNet.request("PROPFIND", home, auth: auth, body: Data(davProps.utf8), headers: ["Depth": "1", "Content-Type": "application/xml"])
    guard h.statusCode == 207, let x = parseXML(d) else { throw Failure("iCloud didn't list the calendars (error \(h.statusCode)).") }
    return davCalendars(x, base: h.url ?? home, accountID: accountID)
}

private let utcFormat: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; return f }()
func icsUTC(_ d: Date) -> String { utcFormat.string(from: d) }

func davEventsIn(_ c: AccCal, auth: String, from a: Date, to b: Date) async throws -> [String: DavRes] {
    let body = """
    <?xml version="1.0" encoding="UTF-8"?><c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/><c:calendar-data/></d:prop>\
    <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT"><c:time-range start="\(icsUTC(a))" end="\(icsUTC(b))"/></c:comp-filter></c:comp-filter></c:filter></c:calendar-query>
    """
    guard let u = URL(string: c.remote) else { throw Failure("A calendar address is broken.") }
    let (d, h) = try await AccNet.request("REPORT", u, auth: auth, body: Data(body.utf8), headers: ["Depth": "1", "Content-Type": "application/xml"])
    guard h.statusCode == 207, let x = parseXML(d) else { throw Failure("\(c.title) didn't load (error \(h.statusCode)).") }
    return davEvents(x, base: h.url ?? u)
}

// MARK: writing calendar files

private func icsEsc(_ s: String) -> String {
    s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
}

private func icsDay(_ d: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone; f.dateFormat = "yyyyMMdd"
    return f.string(from: d)
}

// Long lines are folded at 73 bytes, as the standard asks.
private func icsFold(_ line: String) -> String {
    var out = "", cur = ""
    for ch in line {
        if cur.utf8.count + String(ch).utf8.count > 73 { out += cur + "\r\n "; cur = "" }
        cur.append(ch)
    }
    return out + cur
}

private func icsUnfold(_ text: String) -> [String] {
    var lines: [String] = []
    for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
        if let f = raw.first, f == " " || f == "\t", !lines.isEmpty { lines[lines.count - 1] += raw.dropFirst() } else if !raw.isEmpty { lines.append(String(raw)) }
    }
    return lines
}

private func icsJoin(_ lines: [String]) -> String { lines.map(icsFold).joined(separator: "\r\n") + "\r\n" }

// The lines Dateline writes for what an event says (everything else in the file, such as guests, stays as it was).
private func icsFields(_ it: Item, link: String) -> [String] {
    var l = it.allDay ? ["DTSTART;VALUE=DATE:" + icsDay(it.start), "DTEND;VALUE=DATE:" + icsDay(max(it.end, addDays(it.start, 1)))]
        : ["DTSTART:" + icsUTC(it.start), "DTEND:" + icsUTC(it.end)]
    l.append("SUMMARY:" + icsEsc(it.title))
    if !it.place.isEmpty { l.append("LOCATION:" + icsEsc(it.place)) }
    if !it.notes.isEmpty { l.append("DESCRIPTION:" + icsEsc(it.notes)) }
    if !link.isEmpty { l.append("URL;VALUE=URI:" + link) }
    l.append("TRANSP:" + (it.showAs == .free ? "TRANSPARENT" : "OPAQUE"))
    return l
}
private let icsOwned: Set<String> = ["DTSTART", "DTEND", "DURATION", "SUMMARY", "LOCATION", "DESCRIPTION", "URL", "TRANSP", "DTSTAMP", "LAST-MODIFIED", "SEQUENCE",
                                     "X-APPLE-STRUCTURED-LOCATION"]
private func propName(_ l: String) -> String { String(l.prefix { $0 != ":" && $0 != ";" }).uppercased() }

func icsNew(uid: String, _ it: Item, link: String, alertMinutes: Int?, rule: String?) -> String {
    var l = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Dateline//EN", "BEGIN:VEVENT", "UID:" + uid, "DTSTAMP:" + icsUTC(Date())] + icsFields(it, link: link)
    if let rule { l.append("RRULE:" + rule) }
    if let m = alertMinutes { l += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder", "TRIGGER:-PT\(m)M", "END:VALARM"] }
    return icsJoin(l + ["END:VEVENT", "END:VCALENDAR"])
}

// One VEVENT's lines, by the RECURRENCE-ID it carries (nil = the main one).
private func vevents(_ lines: [String]) -> [(range: Range<Int>, rid: Date?)] {
    var out: [(Range<Int>, Date?)] = [], start: Int?, depth = 0
    for (i, l) in lines.enumerated() {
        let u = l.uppercased()
        if u == "BEGIN:VEVENT" { start = i; depth = 0; continue }
        guard let s = start else { continue }
        if u.hasPrefix("BEGIN:") { depth += 1 } else if u.hasPrefix("END:") && u != "END:VEVENT" { depth -= 1 }
        if u == "END:VEVENT" {
            let rid = lines[s..<i].first { propName($0) == "RECURRENCE-ID" }.flatMap { parseICS("BEGIN:VEVENT\n\($0)\nDTSTART:20000101T000000Z\nEND:VEVENT").first?.recurrenceID }
            out.append((s..<(i + 1), rid)); start = nil
        }
    }
    return out
}

// Rewrites what Dateline shows of one event; `occurrence` = one occurrence of a repeating event, which gets (or keeps) its own changed copy.
func icsPatch(_ text: String, occurrence: Date?, _ it: Item, link: String) -> String {
    var lines = icsUnfold(text)
    let evs = vevents(lines)
    func rewrite(_ r: Range<Int>) {
        var block = Array(lines[r]), depth = 0, keep: [String] = []
        for l in block.dropFirst().dropLast() {
            let u = l.uppercased()
            if u.hasPrefix("BEGIN:") { depth += 1 } else if u.hasPrefix("END:") { depth -= 1; keep.append(l); continue }
            if depth == 0 && icsOwned.contains(propName(l)) { continue }
            keep.append(l)
        }
        let seq = (lines[r].first { propName($0) == "SEQUENCE" }.flatMap { Int($0.split(separator: ":").last ?? "") } ?? 0) + 1
        // The new fields go before the first alarm, so they stay at the event's own level.
        let at = keep.firstIndex { $0.uppercased().hasPrefix("BEGIN:") } ?? keep.count
        keep.insert(contentsOf: icsFields(it, link: link) + ["DTSTAMP:" + icsUTC(Date()), "SEQUENCE:\(seq)"], at: at)
        block = [block[0]] + keep + [block[block.count - 1]]
        lines.replaceSubrange(r, with: block)
    }
    if let occ = occurrence {
        if let own = evs.first(where: { $0.rid == occ }) { rewrite(own.range); return icsJoin(lines) }
        guard let main = evs.first(where: { $0.rid == nil }) else { return text }
        // A new changed copy: the main event without its repeat, marked with the occurrence it replaces.
        var copy = Array(lines[main.range]).filter { !["RRULE", "RDATE", "EXDATE"].contains(propName($0)) }
        let allDay = copy.first { propName($0) == "DTSTART" }?.uppercased().contains("VALUE=DATE") ?? false
        copy.insert(allDay ? "RECURRENCE-ID;VALUE=DATE:" + icsDay(occ) : "RECURRENCE-ID:" + icsUTC(occ), at: 1)
        let end = lines.lastIndex { $0.uppercased() == "END:VCALENDAR" } ?? lines.count
        lines.insert(contentsOf: copy, at: end)
        rewrite(end..<(end + copy.count))
        return icsJoin(lines)
    }
    guard let main = evs.first(where: { $0.rid == nil }) ?? evs.first else { return text }
    rewrite(main.range)
    return icsJoin(lines)
}

// Takes one occurrence out of a repeating event (and drops its changed copy, if any).
func icsDropOccurrence(_ text: String, _ occ: Date) -> String {
    var lines = icsUnfold(text)
    if let own = vevents(lines).first(where: { $0.rid == occ }) { lines.removeSubrange(own.range) }
    guard let main = vevents(lines).first(where: { $0.rid == nil }) else { return icsJoin(lines) }
    let allDay = lines[main.range].first { propName($0) == "DTSTART" }?.uppercased().contains("VALUE=DATE") ?? false
    lines.insert(allDay ? "EXDATE;VALUE=DATE:" + icsDay(occ) : "EXDATE:" + icsUTC(occ), at: main.range.lowerBound + 1)
    return icsJoin(lines)
}

// Dateline items from one CalDAV calendar. One-time events keep the plain id; a repeating one's occurrences add their original start.
func davItems(_ c: AccCal, _ res: [String: DavRes], from a: Date, to b: Date) -> [Item] {
    var out: [Item] = []
    for r in res.values {
        var changed = Set<Date>()
        for e in r.events { if let rid = e.recurrenceID { changed.insert(rid) } }
        let repeating = r.events.contains { $0.rule != nil }
        for e in r.events where !e.cancelled {
            let len = e.end.timeIntervalSince(e.start)
            let starts = e.recurrenceID != nil ? occurrences(ICalEvent(start: e.start, end: e.end), from: a, to: b)
                : occurrences(e, from: a, to: b).filter { !changed.contains($0) }
            for d in starts {
                let at = e.recurrenceID ?? d
                out.append(Item(id: "\(c.id)/\(e.uid)" + (repeating ? "|\(Int(at.timeIntervalSince1970))" : ""), calendarID: c.id, title: e.title,
                                start: d, end: d.addingTimeInterval(len), allDay: e.allDay, place: e.place, notes: e.notes, showAs: e.free ? .free : .busy,
                                alerts: e.alarms.map { d.addingTimeInterval($0) }, link: e.url, files: e.files))
            }
        }
    }
    return out
}

// MARK: Google

private let isoFormat = ISO8601DateFormatter()
private let dayFormat: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()

func googleItem(_ c: AccCal, _ j: [String: Any]) -> GEv? {
    guard let iid = j["id"] as? String, (j["status"] as? String) != "cancelled",
          let s = j["start"] as? [String: Any], let e = j["end"] as? [String: Any] else { return nil }
    let iso = isoFormat
    func day(_ v: String) -> Date? { dayFormat.timeZone = cal.timeZone; return dayFormat.date(from: v) }
    let allDay = s["date"] != nil
    guard let a = allDay ? (s["date"] as? String).flatMap(day) : (s["dateTime"] as? String).flatMap(iso.date),
          let b = allDay ? (e["date"] as? String).flatMap(day) : (e["dateTime"] as? String).flatMap(iso.date) else { return nil }
    let master = j["recurringEventId"] as? String
    let orig = (j["originalStartTime"] as? [String: Any]).flatMap { o in (o["dateTime"] as? String).flatMap(iso.date) ?? (o["date"] as? String).flatMap(day) } ?? a
    let rem = j["reminders"] as? [String: Any]
    let mins = (rem?["useDefault"] as? Bool ?? true) ? c.defaultAlerts : ((rem?["overrides"] as? [[String: Any]]) ?? []).compactMap { $0["minutes"] as? Int }
    let link = (j["hangoutLink"] as? String) ?? ""
    let files = (j["attachments"] as? [[String: Any]] ?? []).compactMap { f -> Attach? in
        guard let u = f["fileUrl"] as? String else { return nil }
        return Attach(name: f["title"] as? String ?? u, url: u, id: f["fileId"] as? String, type: f["mimeType"] as? String ?? "")
    }
    let id = "\(c.id)/\(master ?? iid)" + (master != nil ? "|\(Int(orig.timeIntervalSince1970))" : "")
    return GEv(iid: iid, master: master, etag: j["etag"] as? String,
               item: Item(id: id, calendarID: c.id, title: j["summary"] as? String ?? "", start: a, end: b, allDay: allDay, place: j["location"] as? String ?? "",
                          notes: j["description"] as? String ?? "", showAs: (j["transparency"] as? String) == "transparent" ? .free : .busy,
                          alerts: allDay ? [] : mins.map { a.addingTimeInterval(-Double($0 * 60)) }, link: link, files: files))
}

// `known`: the link the event already had from Google (its Meet link), which is never copied into the notes.
func googleBody(_ it: Item, link: String, known: String = "") -> [String: Any] {
    func when(_ d: Date) -> [String: Any] {
        if it.allDay { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"; return ["date": f.string(from: d), "dateTime": NSNull()] }
        return ["dateTime": ISO8601DateFormatter().string(from: d), "timeZone": cal.timeZone.identifier, "date": NSNull()]
    }
    // Google has no field for a pasted link: it goes in the notes, where Dateline and Google Calendar both find it.
    var notes = it.notes
    if !link.isEmpty, link != known, !notes.contains(link) { notes += (notes.isEmpty ? "" : "\n\n") + "Join: " + link }
    return ["summary": it.title, "location": it.place, "description": notes, "start": when(it.start), "end": when(it.allDay ? max(it.end, addDays(it.start, 1)) : it.end),
            "transparency": it.showAs == .free ? "transparent" : "opaque"]
}

func googleClient() throws -> (String, String) {
    guard let d = try? Data(contentsOf: AccNet.googleClientFile), let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let i = (root["installed"] ?? root["web"]) as? [String: Any], let id = i["client_id"] as? String, let secret = i["client_secret"] as? String
    else { throw Failure("Google sign-in isn't set up on this Mac (Audrey Mail's Google key is missing).") }
    return (id, secret)
}

private func b64url(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
private func randomText(_ n: Int) -> String { var b = [UInt8](repeating: 0, count: n); _ = SecRandomCopyBytes(kSecRandomDefault, n, &b); return b64url(Data(b)) }

func formBody(_ p: [String: String]) -> Data {
    var ok = CharacterSet.alphanumerics; ok.insert(charactersIn: "-._~")
    return Data(p.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: ok) ?? "")" }.joined(separator: "&").utf8)
}

// Google's answer to a sign-in or a refresh.
func googleTokens(_ p: [String: String]) async throws -> (access: String, refresh: String?, expires: Date) {
    var r = URLRequest(url: AccNet.googleToken); r.httpMethod = "POST"
    r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); r.httpBody = formBody(p)
    let (d, resp): (Data, URLResponse)
    do { (d, resp) = try await URLSession.shared.data(for: r) } catch { throw Failure("Couldn't reach Google: \(error.localizedDescription)") }
    let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    guard (resp as? HTTPURLResponse)?.statusCode == 200, let a = j["access_token"] as? String else {
        throw Failure((j["error"] as? String) == "invalid_grant" ? "Google ended the sign-in. Remove the account and add it again." : "Google refused the sign-in (\(j["error"] as? String ?? "no answer")).")
    }
    return (a, j["refresh_token"] as? String, Date().addingTimeInterval(Double(j["expires_in"] as? Int ?? 3600) - 60))
}

// Signs in through the browser and catches Google's answer on this Mac (127.0.0.1); returns the long-lived sign-in.
func googleSignIn() async throws -> (refresh: String, access: String, expires: Date) {
    let (id, secret) = try googleClient()
    let verifier = randomText(64), state = randomText(24)
    let challenge = b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    let catcher = try Catcher(state: state)
    let port = try await catcher.start()
    let redirect = "http://127.0.0.1:\(port)"
    var c = URLComponents(url: AccNet.googleAuth, resolvingAgainstBaseURL: false)!
    c.queryItems = [.init(name: "client_id", value: id), .init(name: "redirect_uri", value: redirect), .init(name: "response_type", value: "code"),
                    .init(name: "scope", value: "https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/drive.file"),  // Drive: only the files Dateline attaches
                    .init(name: "state", value: state),
                    .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
                    .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent")]
    _ = await MainActor.run { NSWorkspace.shared.open(c.url!) }
    let q = try await catcher.wait()
    guard let code = q["code"] else { throw Failure(q["error"] == "access_denied" ? "Google sign-in was cancelled." : "Google sign-in didn't finish.") }
    let t = try await googleTokens(["grant_type": "authorization_code", "code": code, "redirect_uri": redirect, "code_verifier": verifier, "client_id": id, "client_secret": secret])
    guard let refresh = t.refresh else { throw Failure("Google didn't give a lasting sign-in. Try again.") }
    return (refresh, t.access, t.expires)
}

// One-shot listener on 127.0.0.1 for Google's redirect (the same way Audrey Mail signs in). A wrong `state` can't end it.
final class Catcher: @unchecked Sendable {
    private let l: NWListener, q = DispatchQueue(label: "catcher"), state: String
    private var done: CheckedContinuation<[String: String], Error>?, ready: CheckedContinuation<UInt16, Error>?
    init(state: String) throws {
        self.state = state
        let p = NWParameters.tcp; p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        l = try NWListener(using: p)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { c in
            q.async {
                self.ready = c
                self.l.stateUpdateHandler = { s in
                    switch s {
                    case .ready: self.ready?.resume(returning: self.l.port?.rawValue ?? 0); self.ready = nil
                    case .failed(let e): self.ready?.resume(throwing: e); self.ready = nil
                    default: break
                    }
                }
                self.l.newConnectionHandler = { self.handle($0) }
                self.l.start(queue: self.q)
            }
        }
    }
    func wait() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { c in
            q.async {
                self.done = c
                self.q.asyncAfter(deadline: .now() + 300) { self.finish(.failure(Failure("Google sign-in timed out."))) }
            }
        }
    }
    private func finish(_ r: Result<[String: String], Error>) { guard let d = done else { return }; done = nil; l.cancel(); d.resume(with: r) }
    private func handle(_ conn: NWConnection) {
        conn.start(queue: q)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            var got: [String: String] = [:]
            if parts.count >= 2, let c = URLComponents(string: "http://127.0.0.1" + parts[1]), c.path == "/" { for i in c.queryItems ?? [] { got[i.name] = i.value ?? "" } }
            let ok = got["state"] == self.state
            let body = "<html><body style=\"font-family:-apple-system;text-align:center;margin-top:20vh\"><h2>\(ok && got["code"] != nil ? "You are signed in." : "Sign-in was not completed.")</h2><p>You can close this tab and go back to Dateline.</p></body></html>"
            let resp = "HTTP/1.1 \(ok ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel(); if ok { self.finish(.success(got)) } })
        }
    }
}

func googleJSON(_ method: String, _ path: String, token: String, body: [String: Any]? = nil) async throws -> [String: Any] {
    guard let u = URL(string: AccNet.googleAPI + path) else { throw Failure("A Google address is broken.") }
    let (d, h) = try await AccNet.request(method, u, auth: "Bearer " + token, body: body.flatMap { try? JSONSerialization.data(withJSONObject: $0) },
                                          headers: body == nil ? [:] : ["Content-Type": "application/json"])
    if method == "DELETE", [200, 204, 410].contains(h.statusCode) { return [:] }
    let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    guard (200..<300).contains(h.statusCode) else {
        let err = (j["error"] as? [String: Any])?["message"] as? String ?? "error \(h.statusCode)"
        if err.contains("has not been used") || err.contains("is disabled") { throw Failure("Google Calendar isn't switched on for the Google key yet.") }
        throw Failure("Google: " + err)
    }
    return j
}

private func pathPart(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s }

func googleCalendars(token: String, accountID: String) async throws -> (email: String, cals: [AccCal]) {
    let j = try await googleJSON("GET", "/users/me/calendarList?maxResults=250", token: token)
    let items = j["items"] as? [[String: Any]] ?? []
    let email = items.first { $0["primary"] as? Bool == true }?["id"] as? String ?? ""
    let cals = items.compactMap { c -> AccCal? in
        guard let id = c["id"] as? String else { return nil }
        let role = c["accessRole"] as? String ?? ""
        return AccCal(id: calID(accountID, id), remote: id, title: c["summaryOverride"] as? String ?? c["summary"] as? String ?? id,
                      color: c["backgroundColor"] as? String ?? "#1E88E5", writable: role == "owner" || role == "writer",
                      defaultAlerts: (c["defaultReminders"] as? [[String: Any]] ?? []).compactMap { $0["minutes"] as? Int })
    }
    return (email, cals)
}

func googleEventsIn(_ c: AccCal, token: String, from a: Date, to b: Date) async throws -> [GEv] {
    var out: [GEv] = [], page: String? = nil
    let iso = ISO8601DateFormatter()
    repeat {
        var p = "/calendars/\(pathPart(c.remote))/events?singleEvents=true&maxResults=2500&timeMin=\(pathPart(iso.string(from: a)))&timeMax=\(pathPart(iso.string(from: b)))"
        if let page { p += "&pageToken=" + pathPart(page) }
        let j = try await googleJSON("GET", p, token: token)
        out += (j["items"] as? [[String: Any]] ?? []).compactMap { googleItem(c, $0) }
        page = j["nextPageToken"] as? String
    } while page != nil && out.count < 20000
    return out
}

func hexColor(_ s: String) -> Color {
    let h = s.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard h.count >= 6, let v = UInt32(h.prefix(6), radix: 16) else { return Palette.personal }
    return Color(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
}

// MARK: the Store side

extension Store {
    // The window of events kept from each account: a year back, two years ahead.
    static func accWindow() -> (Date, Date) { let n = Date(); return (n.addingTimeInterval(-366 * 86400), n.addingTimeInterval(731 * 86400)) }

    var accInfos: [CalInfo] {
        accounts.flatMap { a in a.cals.map { CalInfo(id: $0.id, title: $0.title, account: a.email.isEmpty ? a.name : a.email, color: hexColor($0.color), writable: $0.writable) } }
    }

    func accCal(_ id: String) -> (Account, AccCal)? {
        for a in accounts { if let c = a.cals.first(where: { $0.id == id }) { return (a, c) } }
        return nil
    }

    // A calendar on the Mac that an account here already shows: hidden, so nothing shows twice.
    // shortcut: one iCloud account is assumed (the Mac's is called "iCloud"); match by Apple ID if two ever sign in.
    func shownHere(_ s: EKSource) -> Bool {
        accounts.contains { a in accData.loaded.contains(a.id) && (a.kind == "google" ? s.title.caseInsensitiveCompare(a.email) == .orderedSame : s.title == "iCloud" && s.sourceType == .calDAV) }
    }

    func accEvents(from a: Date, to b: Date) -> [Item] {
        accounts.flatMap { acc in
            acc.cals.flatMap { c -> [Item] in
                acc.kind == "google" ? (accData.google[c.id] ?? []).map(\.item).filter { $0.end > a && $0.start < b } : davItems(c, accData.dav[c.id] ?? [:], from: a, to: b)
            }
        }.map(decorated)
    }

    func loadAccounts() {
        if let v: [Account] = load("accounts") { accounts = v }
        refreshAccounts()
    }

    private func secret(_ id: String) -> String? {
        if accData.secrets == nil { accData.secrets = AccountSecrets.read() }
        return accData.secrets?[id]
    }
    private func setSecret(_ id: String, _ v: String?) throws {
        var s = accData.secrets ?? AccountSecrets.read()
        s[id] = v
        try AccountSecrets.write(s)
        accData.secrets = s
    }

    private func edit(_ id: String, _ change: (inout Account) -> Void) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[i])
    }

    func accountsChanged() {
        if access == .granted { reloadCalendars() } else { calendars = accInfos + subInfos; refetch() }
    }

    private func googleToken(_ a: Account) async throws -> String {
        if let (t, exp) = accData.tokens[a.id], exp > Date() { return t }
        guard let r = secret(a.id) else { throw Failure("The Google sign-in is missing. Remove the account and add it again.") }
        let (id, s) = try googleClient()
        let t = try await googleTokens(["grant_type": "refresh_token", "refresh_token": r, "client_id": id, "client_secret": s])
        accData.tokens[a.id] = (t.access, t.expires)
        return t.access
    }

    // Reads every calendar of every account (every 5 minutes, and after changes). Skipped while changes are still going out.
    // shortcut: each read downloads the whole window again; add CalDAV ctags / Google sync tokens if it ever feels slow.
    func refreshAccounts() {
        guard access != .sample else { return }
        for a in accounts where accData.pending[a.id, default: 0] == 0 { Task { await sync(a.id) } }
    }

    func sync(_ id: String) async {
        guard let a = accounts.first(where: { $0.id == id }) else { return }
        let (from, to) = Self.accWindow()
        do {
            var cals: [AccCal], dav: [String: [String: DavRes]] = [:], g: [String: [GEv]] = [:]
            if a.kind == "google" {
                let t = try await googleToken(a)
                cals = try await googleCalendars(token: t, accountID: a.id).cals
                for c in cals { g[c.id] = try await googleEventsIn(c, token: t, from: from, to: to) }
            } else {
                guard let pw = secret(a.id) else { throw Failure("The iCloud password is missing. Remove the account and add it again.") }
                cals = try await icloudCalendars(email: a.email, password: pw, accountID: a.id)
                for c in cals { dav[c.id] = try await davEventsIn(c, auth: AccNet.basic(a.email, pw), from: from, to: to) }
            }
            guard accounts.contains(where: { $0.id == id }), accData.pending[id, default: 0] == 0 else { return }  // removed, or changed while it read
            for c in a.cals { accData.dav[c.id] = nil; accData.google[c.id] = nil }
            for (k, v) in dav { accData.dav[k] = v }
            for (k, v) in g { accData.google[k] = v }
            accData.loaded.insert(id)
            edit(id) { $0.cals = cals; $0.synced = Date(); $0.problem = nil }
            if a.carried != true { carryOver(a.id); edit(id) { $0.carried = true } }
        } catch {
            edit(id) { $0.problem = (error as? Failure)?.message ?? error.localizedDescription }
        }
        accountsChanged()
    }

    // The first time an account shows, its calendars take the place of the Mac's copies in what is hidden, in the sets and in the full-screen alerts.
    // The Mac's ids stay too, so the choices still hold if the account can't be reached at a later launch.
    private func carryOver(_ id: String) {
        guard let a = accounts.first(where: { $0.id == id }) else { return }
        let mac = ek.calendars(for: .event).filter { s in a.kind == "google" ? s.source.title.caseInsensitiveCompare(a.email) == .orderedSame : s.source.title == "iCloud" }
        var map: [String: String] = [:]
        for m in mac { if let c = a.cals.first(where: { $0.title.caseInsensitiveCompare(m.title) == .orderedSame }) { map[m.calendarIdentifier] = c.id } }
        guard !map.isEmpty else { return }
        // Dateline's own extras (emoji, tags, notes formatting, travel) follow each event; the account's id is the event's UID.
        let (from, to) = Self.accWindow()
        var ex = extras  // saved once at the end, not once per event
        defer { if ex != extras { extras = ex } }
        for e in ek.events(matching: ek.predicateForEvents(withStart: from, end: to, calendars: mac.filter { map[$0.calendarIdentifier] != nil })) {
            guard let old = e.eventIdentifier, let x = ex[old], let c = map[e.calendar.calendarIdentifier], var uid = e.calendarItemExternalIdentifier else { continue }
            if a.kind == "google", uid.hasSuffix("@google.com") { uid = String(uid.dropLast(11)) }
            if ex[c + "/" + uid] == nil { ex[c + "/" + uid] = x }
        }
        hidden.formUnion(hidden.compactMap { map[$0] })
        for i in sets.indices {
            sets[i].calendars += sets[i].calendars.compactMap { map[$0] }.filter { !sets[i].calendars.contains($0) }
            if let d = sets[i].defaultCalendar, let n = map[d] { sets[i].defaultCalendar = n }
        }
        if let f = Alerts.fullCalendars { Alerts.fullCalendars = f.union(f.compactMap { map[$0] }) }
    }

    func addICloud(email: String, password: String) async -> Failure? {
        let e = email.trimmingCharacters(in: .whitespaces), pw = password.trimmingCharacters(in: .whitespaces)
        if accounts.contains(where: { $0.kind == "icloud" && $0.email.caseInsensitiveCompare(e) == .orderedSame }) { return Failure("\(e) is already signed in.") }
        let a = Account(kind: "icloud", email: e)
        do {
            let cals = try await icloudCalendars(email: e, password: pw, accountID: a.id)
            guard !cals.isEmpty else { return Failure("Signed in, but this iCloud account has no calendars.") }
            try setSecret(a.id, pw)
        } catch {
            if (error as? Failure)?.message.hasPrefix("The account refused") == true { return Failure("iCloud refused the sign-in. Check the email and the app-specific password.") }
            return (error as? Failure) ?? Failure(error.localizedDescription)
        }
        accounts.append(a)
        await sync(a.id)
        return nil
    }

    func addGoogle() async -> Failure? {
        var a = Account(kind: "google", email: "")
        do {
            let s = try await googleSignIn()
            let (email, _) = try await googleCalendars(token: s.access, accountID: a.id)
            if accounts.contains(where: { $0.kind == "google" && $0.email.caseInsensitiveCompare(email) == .orderedSame }) { return Failure("\(email) is already signed in.") }
            a.email = email
            try setSecret(a.id, s.refresh)
            accData.tokens[a.id] = (s.access, s.expires)
        } catch { return (error as? Failure) ?? Failure(error.localizedDescription) }
        accounts.append(a)
        await sync(a.id)
        return nil
    }

    func removeAccount(_ id: String) {
        guard let a = accounts.first(where: { $0.id == id }) else { return }
        try? setSecret(id, nil)
        accData.chain[id]?.cancel(); accData.chain[id] = nil; accData.pending[id] = nil
        for c in a.cals { accData.dav[c.id] = nil; accData.google[c.id] = nil; hidden.remove(c.id) }
        for i in sets.indices {
            sets[i].calendars.removeAll { $0.hasPrefix(id + "-") }
            if sets[i].defaultCalendar?.hasPrefix(id + "-") == true { sets[i].defaultCalendar = nil }
        }
        if let f = Alerts.fullCalendars, f.contains(where: { $0.hasPrefix(id + "-") }) { Alerts.fullCalendars = f.filter { !$0.hasPrefix(id + "-") } }
        accData.loaded.remove(id); accData.tokens[id] = nil
        accounts.removeAll { $0.id == id }
        accountsChanged()
    }

    // MARK: changes, shown at once and sent in the background

    @discardableResult private func send(_ a: Account, _ c: AccCal, _ op: @escaping (Store) async throws -> Void) -> Task<Void, Never> {
        accData.pending[a.id, default: 0] += 1
        let prev = accData.chain[a.id]
        accData.chain[a.id] = Task { [weak self] in
            await prev?.value
            guard let self else { return }
            guard !Task.isCancelled, self.accounts.contains(where: { $0.id == a.id }) else { return }  // the account was removed
            // A failed change shows its error; the sync once the queue is empty brings back what the account really has.
            do { try await op(self) } catch { self.onError?("\(c.title): " + ((error as? Failure)?.message ?? error.localizedDescription)) }
            self.accData.pending[a.id] = max(0, self.accData.pending[a.id, default: 1] - 1)
            if self.accData.pending[a.id] == 0 { await self.sync(a.id) }
        }
        return accData.chain[a.id]!
    }

    @discardableResult private func davSend(_ a: Account, _ c: AccCal, href: String, new: Bool = false) -> Task<Void, Never> {
        send(a, c) { s in
            guard let pw = s.secret(a.id), let u = URL(string: href) else { throw Failure("The iCloud password is missing.") }
            let etag = s.accData.dav[c.id]?[href]?.etag
            var h = ["Content-Type": "text/calendar; charset=utf-8"]
            if new { h["If-None-Match"] = "*" } else if let etag { h["If-Match"] = etag }
            guard let body = s.accData.dav[c.id]?[href]?.text else { return }  // deleted again before it went out
            let (_, r) = try await AccNet.request("PUT", u, auth: AccNet.basic(a.email, pw), body: Data(body.utf8), headers: h)
            if r.statusCode == 412 { throw Failure("it was changed somewhere else meanwhile, so it was reloaded.") }
            guard (200..<300).contains(r.statusCode) else { throw Failure("the change didn't save (error \(r.statusCode)).") }
            let etag2 = r.value(forHTTPHeaderField: "ETag")
            if s.accData.dav[c.id]?[href] != nil { s.accData.dav[c.id]?[href]?.etag = etag2 } else { s.accData.goneEtag[href] = etag2 }  // deleted while it went out
        }
    }

    private func gSend(_ a: Account, _ c: AccCal, _ method: String, _ path: String, _ body: [String: Any]?) {
        send(a, c) { s in
            let t = try await s.googleToken(a)
            let j = try await googleJSON(method, "/calendars/\(pathPart(c.remote))/events" + path, token: t, body: body)
            if method != "DELETE", let ev = googleItem(c, j), let i = s.accData.google[c.id]?.firstIndex(where: { $0.iid == ev.iid }) { s.accData.google[c.id]?[i].etag = ev.etag }
        }
    }

    // The event file and the occurrence (nil = a one-time event or the whole series) an item stands for.
    private func davRef(_ it: Item) -> (href: String, occ: Date?, repeating: Bool)? {
        let parts = it.id.split(separator: "|").map(String.init)  // "calendar/uid", then the occurrence for a repeating event
        guard let (_, c) = accCal(it.calendarID) else { return nil }
        let uid = String(it.id.dropFirst(c.id.count + 1).split(separator: "|").first ?? "")
        guard let (href, r) = accData.dav[c.id]?.first(where: { $0.value.events.contains { $0.uid == uid } }) else { return nil }
        let repeating = r.events.contains { $0.rule != nil }
        let occ = repeating ? Double(parts.last ?? "").map(Date.init(timeIntervalSince1970:)) : nil
        return (href, occ, repeating)
    }

    func accRepeats(_ it: Item) -> Bool {
        accCal(it.calendarID)?.0.kind == "google" ? (accData.google[it.calendarID]?.first { $0.item.id == it.id }?.master != nil) : (davRef(it)?.repeating ?? false)
    }

    func accAdd(_ it: Item, alertMinutes: Int?, repeats: (unit: Character, n: Int)?) -> Result<Item, Failure> {
        guard let (a, c) = accCal(it.calendarID) else { return .failure(Failure("That calendar is gone.")) }
        guard c.writable else { return .failure(Failure("\(c.title) can't take new events.")) }
        let rule = repeats.map { r in "FREQ=" + ["d": "DAILY", "w": "WEEKLY", "m": "MONTHLY", "y": "YEARLY"][r.unit]! + (r.n > 1 ? ";INTERVAL=\(r.n)" : "") }
        var it = it
        let link = callLink(in: [it.link])?.url.absoluteString ?? it.link
        if a.kind == "google" {
            let gid = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")  // Google takes an id made here, so the event keeps it
            it.id = "\(c.id)/\(gid)" + (rule != nil ? "|\(Int(it.start.timeIntervalSince1970))" : "")
            accData.google[c.id, default: []].append(GEv(iid: gid, master: rule != nil ? gid : nil, etag: nil, item: it))
            var body = googleBody(it, link: link); body["id"] = gid
            if let rule { body["recurrence"] = ["RRULE:" + rule] }
            if let m = alertMinutes { body["reminders"] = ["useDefault": false, "overrides": [["method": "popup", "minutes": m]]] }
            gSend(a, c, "POST", "", body)
        } else {
            let uid = UUID().uuidString
            let href = URL(string: uid + ".ics", relativeTo: URL(string: c.remote))!.absoluteString
            it.id = "\(c.id)/\(uid)" + (rule != nil ? "|\(Int(it.start.timeIntervalSince1970))" : "")
            let text = icsNew(uid: uid, it, link: link, alertMinutes: alertMinutes, rule: rule)
            accData.dav[c.id, default: [:]][href] = DavRes(etag: nil, text: text, events: parseICS(text))
            davSend(a, c, href: href, new: true)
        }
        refetch()
        return .success(it)
    }

    func accUpdate(_ it: Item, old: Item?) -> Failure? {
        let from = old?.calendarID ?? it.calendarID
        if from != it.calendarID { return Failure("Moving an event to a calendar on another account isn't ready yet. Option-drag a copy to it, then delete this one.") }
        guard let (a, c) = accCal(it.calendarID) else { return Failure("That calendar is gone.") }
        guard c.writable else { return Failure("\(c.title) is read-only.") }
        let link = callLink(in: [it.link])?.url.absoluteString ?? it.link.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.kind == "google" {
            guard let i = accData.google[c.id]?.firstIndex(where: { $0.item.id == it.id }), let ev = accData.google[c.id]?[i] else { return Failure("That event is gone.") }
            accData.google[c.id]?[i].item = it
            gSend(a, c, "PATCH", "/" + pathPart(ev.iid), googleBody(it, link: link, known: ev.item.link))
        } else {
            guard let ref = davRef(it), let res = accData.dav[c.id]?[ref.href] else { return Failure("That event is gone.") }
            let text = icsPatch(res.text, occurrence: ref.occ, it, link: link)
            accData.dav[c.id]?[ref.href] = DavRes(etag: res.etag, text: text, events: parseICS(text))
            davSend(a, c, href: ref.href)
        }
        return nil
    }

    func accDelete(_ it: Item, series: Bool) -> Failure? {
        guard let (a, c) = accCal(it.calendarID) else { return Failure("That calendar is gone.") }
        guard c.writable else { return Failure("\(c.title) is read-only.") }
        if a.kind == "google" {
            guard let ev = accData.google[c.id]?.first(where: { $0.item.id == it.id }) else { return Failure("That event is gone.") }
            let target = series ? ev.master ?? ev.iid : ev.iid
            accData.google[c.id]?.removeAll { $0.iid == target || $0.master == target }
            gSend(a, c, "DELETE", "/" + pathPart(target), nil)
        } else {
            guard let ref = davRef(it), let res = accData.dav[c.id]?[ref.href] else { return Failure("That event is gone.") }
            if let occ = ref.occ, !series {
                let text = icsDropOccurrence(res.text, occ)
                accData.dav[c.id]?[ref.href] = DavRes(etag: res.etag, text: text, events: parseICS(text))
                davSend(a, c, href: ref.href)
            } else {
                // shortcut: "this and later" (undo of adding a repeating event) deletes the whole series, which is right for the first occurrence only.
                accData.dav[c.id]?[ref.href] = nil
                davSendDelete(a, c, ref.href, res.etag)
            }
        }
        return nil
    }

    private func davSendDelete(_ a: Account, _ c: AccCal, _ href: String, _ etag: String?) {
        send(a, c) { s in
            guard let pw = s.secret(a.id), let u = URL(string: href) else { throw Failure("The iCloud password is missing.") }
            let tag = s.accData.goneEtag.removeValue(forKey: href) ?? etag
            let (_, r) = try await AccNet.request("DELETE", u, auth: AccNet.basic(a.email, pw), headers: tag.map { ["If-Match": $0] } ?? [:])
            if r.statusCode == 412 { throw Failure("it was changed somewhere else meanwhile, so it was reloaded.") }
            guard (200..<300).contains(r.statusCode) || r.statusCode == 404 else { throw Failure("the delete didn't go through (error \(r.statusCode)).") }
        }
    }
}

// MARK: attachments (Phase 8, approved mockup section 2)
// iCloud keeps the files itself (managed attachments, RFC 8607); Google keeps them in the account's Drive and the event links to them.
// A repeating event's file goes on the whole series, as Apple Calendar does.

let attachLimit = 100_000_000  // Dateline's own cap, so a stray video never sits whole in memory

func icsDropAttach(_ text: String, _ url: String) -> String {
    icsJoin(icsUnfold(text).filter { !(propName($0) == "ATTACH" && $0.hasSuffix(":" + url)) })
}

// The file name for iCloud; a name with accents also goes in the standard's UTF-8 form.
func attachDisposition(_ name: String) -> String {
    let plain = String(String.UnicodeScalarView(name.unicodeScalars.map { $0.isASCII && $0.value >= 32 && $0 != "\"" && $0 != "\\" ? $0 : "_" }))
    return "attachment;filename=\"\(plain)\"" + (plain == name ? "" : ";filename*=UTF-8''" + pathPart(name))
}

// The Mac account an attachments hint names, or nil when signing in here can't help (a calendar on the Mac only, Exchange and the like).
// shortcut: any source named with an email reads as Google; check the source type if an Exchange user ever sees the wrong name.
func macAccountKind(_ account: String) -> String? { account.hasPrefix("iCloud") ? "iCloud" : account.contains("@") || account.hasPrefix("Google") ? "Google" : nil }

func driveUpload(token: String, name: String, type: String, data: Data) async throws -> [String: Any] {
    // Resumable, sent in one go: Drive takes only 5 MB in a single multipart request.
    guard let u = URL(string: AccNet.driveUpload + "?uploadType=resumable&fields=id,webViewLink") else { throw Failure("A Google address is broken.") }
    let meta = try JSONSerialization.data(withJSONObject: ["name": name])
    var (d, h) = try await AccNet.request("POST", u, auth: "Bearer " + token, body: meta, headers: ["Content-Type": "application/json; charset=UTF-8", "X-Upload-Content-Type": type])
    if (200..<300).contains(h.statusCode) {
        guard let loc = h.value(forHTTPHeaderField: "Location"), let up = URL(string: loc) else { throw Failure("Google Drive didn't start the upload.") }
        (d, h) = try await AccNet.request("PUT", up, auth: "Bearer " + token, body: data, headers: ["Content-Type": type])
    }
    var j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    guard (200..<300).contains(h.statusCode), let id = j["id"] as? String else {
        let err = (j["error"] as? [String: Any])?["message"] as? String ?? "error \(h.statusCode)"
        if err.lowercased().contains("insufficient") { throw Failure("Google needs a fresh sign-in to put files in your Drive: remove the Google account in Settings, Accounts, and add it again.") }
        if err.contains("has not been used") || err.contains("is disabled") { throw Failure("Google Drive isn't switched on for the Google key yet.") }
        throw Failure("Google Drive: " + err)
    }
    if j["webViewLink"] == nil { j["webViewLink"] = "https://drive.google.com/file/d/\(id)/view" }  // in case the asked-for fields don't carry over to the upload step
    return j
}

extension Store {
    func accAttach(_ it: Item, _ file: URL) async {
        guard let (a, c) = accCal(it.calendarID), c.writable else { return }
        let name = file.lastPathComponent
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        // No size counts as unreadable, so the cap can't be skipped.
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { onError?("\(name) couldn't be read."); return }
        guard size <= attachLimit else { onError?("\(name) is over 100 MB, more than Dateline attaches."); return }
        // Read off the main thread, and only when its turn in the queue comes, so dropped files never sit in memory together.
        let read: () async throws -> Data = {
            do { return try await Task.detached { try Data(contentsOf: file) }.value } catch { throw Failure("\(name) couldn't be read.") }
        }
        if a.kind == "google" {
            guard let ev = accData.google[c.id]?.first(where: { $0.item.id == it.id }) else { onError?("That event is gone."); return }
            await gFiles(a, c, ev.master ?? ev.iid, upload: { t in try await driveUpload(token: t, name: name, type: type, data: try await read()) }) { f, list in
                list + [["fileUrl": f?["webViewLink"] as? String ?? "", "title": name, "mimeType": type, "fileId": f?["id"] as? String ?? ""]]
            }.value
        } else {
            guard let ref = davRef(it) else { onError?("That event is gone."); return }
            await davFiles(a, c, ref.href, "?action=attachment-add", read, ["Content-Type": type, "Content-Disposition": attachDisposition(name)]).value
        }
    }

    func accDetach(_ it: Item, _ f: Attach) async {
        guard let (a, c) = accCal(it.calendarID), c.writable else { return }
        if a.kind == "google" {
            guard let ev = accData.google[c.id]?.first(where: { $0.item.id == it.id }) else { return }
            // shortcut: a file attached to just one changed occurrence (an exception) isn't seen here; fix when someone hits it.
            await gFiles(a, c, ev.master ?? ev.iid) { _, list in list.filter { ($0["fileUrl"] as? String) != f.url } }.value  // the file stays in Drive, as with Google Calendar
        } else {
            guard let ref = davRef(it), let res = accData.dav[c.id]?[ref.href] else { return }
            if let id = f.id {
                await davFiles(a, c, ref.href, "?action=attachment-remove&managed-id=" + pathPart(id), nil, [:]).value
            } else {  // a plain link someone else put in: taken out of the event file like any other change
                let text = icsDropAttach(res.text, f.url)
                accData.dav[c.id]?[ref.href] = DavRes(etag: res.etag, text: text, events: parseICS(text))
                refetch()
                await davSend(a, c, href: ref.href).value
            }
        }
    }

    // The file to open or save; nil = a link to open in the browser (Google Drive, or a server other than the account's own).
    func accFetch(_ it: Item, _ f: Attach) async throws -> Data? {
        guard let (a, c) = accCal(it.calendarID), a.kind == "icloud", let u = URL(string: f.url), let host = u.host, let cal = URL(string: c.remote) else { return nil }
        // The password goes only to the account's own servers, never to a link someone else put in the event.
        guard (host == cal.host && u.scheme == cal.scheme) || (f.id != nil && u.scheme == "https" && host.hasSuffix(".icloud.com")), let pw = secret(a.id) else { return nil }
        let (d, h) = try await AccNet.request("GET", u, auth: AccNet.basic(a.email, pw))
        guard h.statusCode == 200 else { throw Failure("\(f.name) didn't download (error \(h.statusCode)).") }
        return d
    }

    private func davFiles(_ a: Account, _ c: AccCal, _ href: String, _ query: String, _ body: (() async throws -> Data)?, _ headers: [String: String]) -> Task<Void, Never> {
        send(a, c) { s in
            guard let pw = s.secret(a.id), let u = URL(string: href + query), let file = URL(string: href) else { throw Failure("The iCloud password is missing.") }
            let auth = AccNet.basic(a.email, pw), before = s.accData.dav[c.id]?[href]
            var h = headers
            if let e = before?.etag { h["If-Match"] = e }
            let (_, r) = try await AccNet.request("POST", u, auth: auth, body: try await body?() ?? Data(), headers: h)
            if r.statusCode == 412 { throw Failure("it was changed somewhere else meanwhile, so it was reloaded.") }
            if r.statusCode == 413 { throw Failure("the file is too big for iCloud.") }
            guard (200..<300).contains(r.statusCode) else { throw Failure("the file didn't go through (error \(r.statusCode)).") }
            // The server's new copy, so the next file goes on top of this one. Not when an edit was made meanwhile:
            // that edit then goes out on the old version, is refused and reloads, instead of quietly dropping the file.
            let (d, g) = try await AccNet.request("GET", file, auth: auth)
            if g.statusCode == 200, let text = String(data: d, encoding: .utf8), s.accData.dav[c.id]?[href]?.text == before?.text {
                s.accData.dav[c.id]?[href] = DavRes(etag: g.value(forHTTPHeaderField: "ETag"), text: text, events: parseICS(text))
                s.refetch()
            }
        }
    }

    // The upload goes first, so the event's list is read and written back right away, not around a long upload.
    private func gFiles(_ a: Account, _ c: AccCal, _ target: String, upload: ((String) async throws -> [String: Any])? = nil,
                        _ change: @escaping ([String: Any]?, [[String: Any]]) -> [[String: Any]]) -> Task<Void, Never> {
        send(a, c) { s in
            let t = try await s.googleToken(a)
            let up = try await upload?(t)
            let path = "/calendars/\(pathPart(c.remote))/events/\(pathPart(target))"
            do {
                let list = try await googleJSON("GET", path, token: t)["attachments"] as? [[String: Any]] ?? []
                _ = try await googleJSON("PATCH", path + "?supportsAttachments=true", token: t, body: ["attachments": change(up, list)])
            } catch {
                // The event didn't take the file: it comes out of Drive again, so retries don't leave copies.
                if let id = up?["id"] as? String, let u = URL(string: AccNet.driveUpload.replacingOccurrences(of: "/upload/", with: "/") + "/" + pathPart(id)) {
                    _ = try? await AccNet.request("DELETE", u, auth: "Bearer " + t)
                }
                throw error
            }
        }
    }
}

// The Attachments part of the event panel: the files, a drop area and Add…, or on a calendar from the Mac's settings, why not and where to sign in.
struct AttachmentsBox: View {
    @ObservedObject var store: Store
    let item: Item
    @State private var adding: [String] = []
    @State private var over = false
    @AppStorage("attachHintOff") private var hintOff = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let (a, c) = store.accCal(item.calendarID) { files(a, c) } else { macHint }
    }

    func files(_ a: Account, _ c: AccCal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(item.files.enumerated()), id: \.offset) { _, f in fileRow(a, f, c.writable) }
            ForEach(Array(adding.enumerated()), id: \.offset) { _, n in
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Adding \(n)…").foregroundStyle(Palette.text3).lineLimit(1) }
            }
            if c.writable {
                HStack(spacing: 4) {
                    Text("Drop files here, or").foregroundStyle(Palette.text3)
                    Button("Add…") { pick() }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 7).strokeBorder(over ? Palette.accent : Palette.line, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                Text(a.kind == "google" ? "On Google events the file goes into your Google Drive and the event links to it, which is how Google Calendar itself does attachments." : "On iCloud events these open on your iPhone too.")
                    .font(.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            } else if item.files.isEmpty { Text("No attachments").foregroundStyle(Palette.text3) }
        }
        // shortcut: files dragged as files (Finder, the desktop, Photos' "drag out"); a picture dragged from inside a web page isn't taken.
        .onDrop(of: [.fileURL], isTargeted: $over) { ps in
            guard c.writable else { return false }
            for p in ps { _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { Task { @MainActor in add([u]) } } } }
            return true
        }
    }

    func fileRow(_ a: Account, _ f: Attach, _ writable: Bool) -> some View {
        let (t, col) = thumb(f)
        return HStack(spacing: 8) {
            Button { open(f) } label: {
                HStack(spacing: 8) {
                    Text(t).font(.ui(9, weight: .bold)).foregroundStyle(.white).frame(width: 30, height: 30).background(col, in: RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.name).lineLimit(1).truncationMode(.middle).foregroundStyle(Palette.text)
                        if let n = f.size { Text(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)).font(.ui(11)).foregroundStyle(Palette.text3) }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).contextMenu { actions(a, f, writable) }
            Menu { actions(a, f, writable) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(Palette.text3)
        }
    }

    @ViewBuilder func actions(_ a: Account, _ f: Attach, _ writable: Bool) -> some View {
        Button(a.kind == "google" ? "Open in Google Drive" : "Open") { open(f) }
        if a.kind == "icloud" { Button("Save a Copy…") { save(f) } }
        if writable { Button("Remove") { Task { await store.accDetach(item, f) } } }
    }

    func thumb(_ f: Attach) -> (String, Color) {
        let ext = (f.name as NSString).pathExtension.lowercased(), t = UTType(mimeType: f.type) ?? UTType(filenameExtension: ext)
        if t?.conforms(to: .image) == true { return ("IMG", Palette.tags[3]) }
        if t?.conforms(to: .pdf) == true { return ("PDF", Palette.tags[0]) }
        return (ext.isEmpty ? "FILE" : String(ext.prefix(4)).uppercased(), Palette.tags[7])
    }

    // Only the last part of the server's name, so a name like "../x" can't write outside the folder.
    func safeName(_ n: String) -> String { let s = (n as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "-"); return s.isEmpty || s == ".." ? "Attachment" : s }

    func open(_ f: Attach) {
        Task {
            do {
                guard let d = try await store.accFetch(item, f) else {
                    if let u = URL(string: f.url), ["https", "http"].contains(u.scheme?.lowercased()) { NSWorkspace.shared.open(u) }
                    return
                }
                let name = safeName(f.name)
                let u = try await Task.detached {  // off the main thread: the file can be large
                    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Dateline attachments")
                    // Copies opened over a day ago are cleared, so private files don't pile up.
                    for old in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
                    where ((try? old.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) < Date().addingTimeInterval(-86_400) { try? FileManager.default.removeItem(at: old) }
                    let dir = root.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let u = dir.appendingPathComponent(name)
                    try d.write(to: u); try quarantine(u)
                    return u
                }.value
                NSWorkspace.shared.open(u)
            } catch { store.onError?((error as? Failure)?.message ?? error.localizedDescription) }
        }
    }

    func save(_ f: Attach) {
        let p = NSSavePanel(); p.nameFieldStringValue = safeName(f.name)
        guard p.runModal() == .OK, let to = p.url else { return }
        Task {
            do { if let d = try await store.accFetch(item, f) { try d.write(to: to); try quarantine(to) } } catch { store.onError?((error as? Failure)?.message ?? error.localizedDescription) }
        }
    }


    func pick() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
        if p.runModal() == .OK { add(p.urls) }
    }

    func add(_ urls: [URL]) {
        for u in urls where !u.hasDirectoryPath {
            adding.append(u.lastPathComponent)
            Task {
                await store.accAttach(item, u)
                if let i = adding.firstIndex(of: u.lastPathComponent) { adding.remove(at: i) }
            }
        }
    }

    @ViewBuilder var macHint: some View {
        let c = store.calendar(item.calendarID), kind = macAccountKind(c?.account ?? "") ?? "iCloud"
        VStack(alignment: .leading, spacing: 8) {
            (Text("Not on this calendar yet. ").bold() + Text("\"\(c?.title ?? "")\" comes through the Mac's settings, which don't let other apps add files. Sign in to this \(kind) account in Dateline to attach files."))
                .font(.ui(11.5)).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true).padding(10)
                .frame(maxWidth: .infinity, alignment: .leading).background(Palette.tags[1].opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
            HStack(spacing: 8) {
                Button("Sign in to \(kind)…") { UserDefaults.standard.set("accounts", forKey: "settingsTab"); openSettings() }.buttonStyle(.borderedProminent)
                Button("Not now") { hintOff = true }
            }.controlSize(.small)
        }
    }
}

// MARK: the Accounts tab

struct AccountSettings: View {
    @ObservedObject var store: Store
    @State var picked: String? = nil
    @State var adding: String? = nil  // "icloud" while the iCloud form shows
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var note = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                // Plain rows, not List: List is drawn by AppKit and comes out blank in --render pictures.
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.accounts) { a in
                            row(a.id, a.kind, a.email, a.problem == nil ? "\(a.name), \(a.cals.count) calendar\(a.cals.count == 1 ? "" : "s")" : "Not syncing", bad: a.problem != nil)
                        }
                        row("mac", "mac", "On this Mac", "From the Mac's settings")
                    }.padding(4)
                }
                .background(Palette.win).overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.text3.opacity(0.3)))
                HStack(spacing: 0) {
                    // Plain button back to the add choices; a Menu here was easy to miss.
                    Button { picked = nil; adding = nil; note = "" } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).frame(width: 26, height: 20).help("Add an account")
                    Button { if let p = picked, p != "mac" { store.removeAccount(p); picked = nil } } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless).frame(width: 26, height: 20).disabled(picked == nil || picked == "mac")
                    Spacer()
                }.padding(.top, 4)
            }.frame(width: 220)

            VStack(alignment: .leading, spacing: 10) {
                if adding == "icloud" { icloudForm }
                else if let p = picked, let a = store.accounts.first(where: { $0.id == p }) { detail(a) }
                else if picked == "mac" {
                    Text("Calendars set up in the Mac's own settings keep working as before. If an account is also signed in here, Dateline shows its calendars once, from here.")
                        .font(.system(size: 12)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                    addChoices.padding(.top, 6)
                } else { addChoices }
                if !note.isEmpty { Text(note).font(.system(size: 11.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                Spacer()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20).frame(width: 600, height: 340)
    }

    func row(_ id: String, _ kind: String, _ title: String, _ sub: String, bad: Bool = false) -> some View {
        let on = picked == id
        return Button { picked = id; adding = nil; note = "" } label: {
            HStack(spacing: 8) {
                badge(kind)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).foregroundStyle(on ? .white : Palette.text)
                    Text(sub).font(.system(size: 11)).foregroundStyle(on ? .white.opacity(0.85) : bad ? .red : Palette.text3)
                }
                Spacer(minLength: 0)
            }.padding(6).contentShape(Rectangle())
        }.buttonStyle(.plain).background(on ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
    }

    func badge(_ kind: String) -> some View {
        let (t, c): (String, Color) = kind == "google" ? ("G", Color(red: 0.26, green: 0.52, blue: 0.96)) : kind == "icloud" ? ("☁", Color(red: 0.2, green: 0.6, blue: 0.95)) : ("⌘", Palette.text3)
        return Text(t).font(.system(size: 12, weight: .bold)).foregroundStyle(.white).frame(width: 22, height: 22).background(c, in: RoundedRectangle(cornerRadius: 5))
    }

    var addChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADD AN ACCOUNT").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.text3)
            choice("icloud", "iCloud", "Email and an app-specific password from your Apple Account") { adding = "icloud"; note = "" }
            choice("google", "Google", "Signs in through Google in your browser") { google() }
        }
    }

    func choice(_ kind: String, _ title: String, _ sub: String, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            HStack(spacing: 10) {
                badge(kind)
                VStack(alignment: .leading, spacing: 1) { Text(title).font(.system(size: 12.5, weight: .medium)); Text(sub).font(.system(size: 11)).foregroundStyle(Palette.text3) }
                Spacer()
            }.padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain).background(Palette.text3.opacity(0.08), in: RoundedRectangle(cornerRadius: 7)).disabled(busy)
    }

    var icloudForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add an iCloud account").font(.system(size: 13, weight: .semibold))
            TextField("Apple Account email", text: $email).textFieldStyle(.roundedBorder).frame(width: 280)
            SecureField("App-specific password", text: $password).textFieldStyle(.roundedBorder).frame(width: 280)
            Text("Apple asks for an app-specific password for any calendar app that isn't Apple's. Make one at account.apple.com, under Sign-In and Security.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            Link("Open account.apple.com", destination: URL(string: "https://account.apple.com/account/manage")!).font(.system(size: 11.5))
            HStack {
                Button("Cancel") { adding = nil; email = ""; password = ""; note = "" }
                Button(busy ? "Signing in…" : "Sign In") {
                    busy = true; note = ""
                    Task {
                        let f = await store.addICloud(email: email, password: password)
                        busy = false
                        if let f { note = f.message } else { adding = nil; email = ""; password = ""; picked = store.accounts.last?.id }
                    }
                }.keyboardShortcut(.defaultAction).disabled(busy || email.isEmpty || password.isEmpty)
            }
        }
    }

    func detail(_ a: Account) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(a.email).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.text3).textCase(.uppercase)
            ForEach(a.cals, id: \.id) { c in
                HStack(spacing: 7) { Circle().fill(hexColor(c.color)).frame(width: 9, height: 9); Text(c.title).font(.system(size: 12.5)); if !c.writable { Text("read-only").font(.system(size: 11)).foregroundStyle(Palette.text3) } }
            }
            if let p = a.problem { Text(p).font(.system(size: 11.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text("If this account is also set up in the Mac's settings, Dateline shows its calendars once, not twice: the copy signed in here wins.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(a.synced.map { "Synced " + timeText($0, short: false) } ?? "Not synced yet").font(.system(size: 11.5)).foregroundStyle(Palette.text3)
                Button("Sync now") { Task { await store.sync(a.id) } }.controlSize(.small)
                Button("Remove account") { store.removeAccount(a.id); picked = nil }.controlSize(.small)
            }
        }
    }

    func google() {
        adding = nil; busy = true; note = "Finish signing in to Google in your browser."
        Task {
            let f = await store.addGoogle()
            busy = false
            note = f?.message ?? ""
            if f == nil { picked = store.accounts.last?.id }
        }
    }
}

// MARK: checks

// The iCloud network code end to end against scripts/caldav-standin.py: sign in, read, add, change, delete. Never saves a setting or a password.
@MainActor func accountsCheck(server: String) async -> Int32 {
    AccountSecrets.testMode = true
    AccNet.icloudRoot = URL(string: server)!
    var fails = 0
    func expect(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: " + what) } }
    let store = Store(sample: true)  // sample: nothing is saved, the Mac's calendars are never asked for
    var errors: [String] = []
    store.onError = { errors.append($0) }
    let wrong = await store.addICloud(email: "t@example.com", password: "nope")
    expect(wrong?.message.contains("refused") == true && store.accounts.isEmpty, "a wrong password is refused and adds nothing")
    let f = await store.addICloud(email: "t@example.com", password: "pw")
    expect(f == nil, "sign-in: \(f?.message ?? "")")
    guard let a = store.accounts.first, let c = a.cals.first else { print("accounts-check: no account, stopping"); return 1 }
    expect(a.cals.map(\.title) == ["Home"] && c.writable && c.color == "#FF2968", "only the event calendar, its colour and write access (\(a.cals.map(\.title)))")
    let (from, to) = Store.accWindow()
    func shown() -> [Item] { store.accEvents(from: from, to: to) }
    func settle() async { while let t = store.accData.chain[a.id] { await t.value; if store.accData.chain[a.id] == t { break } } }
    expect(shown().map(\.title) == ["Seed event"], "the server's event shows")

    let start = Date().addingTimeInterval(86400)
    guard case .success(let added) = store.accAdd(Item(id: "", calendarID: c.id, title: "Check event", start: start, end: start.addingTimeInterval(3600), allDay: false, place: "", notes: "", showAs: .busy), alertMinutes: 10, repeats: nil)
    else { print("FAIL: add refused"); return 1 }
    await settle()
    expect(Set(shown().map(\.title)) == ["Seed event", "Check event"] && store.accounts.first?.problem == nil, "an added event is on the server")
    var moved = added; moved.title = "Check moved"
    expect(store.accUpdate(moved, old: added) == nil, "an edit is accepted")
    await settle()
    var again = moved; again.title = "Check moved twice"
    expect(store.accUpdate(again, old: moved) == nil, "a second edit, with the server's new version")
    await settle()
    expect(Set(shown().map(\.title)) == ["Seed event", "Check moved twice"] && store.accounts.first?.problem == nil, "both edits reached the server (\(shown().map(\.title)))")
    guard let now = shown().first(where: { $0.title == "Check moved twice" }) else { return 1 }
    var last = now; last.title = "Edited then deleted"
    expect(store.accUpdate(last, old: now) == nil && store.accDelete(last, series: false) == nil, "an edit and a delete right after it are accepted")
    await settle()
    expect(shown().map(\.title) == ["Seed event"] && errors.isEmpty, "the delete behind an edit reached the server (\(errors))")

    // Attachments: two files at once on the seed event, an edit after that keeps them, one opened, one removed.
    guard let seed0 = shown().first(where: { $0.title == "Seed event" }) else { return 1 }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dateline-check-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let pdf = dir.appendingPathComponent("Rental agreement.pdf"), jpg = dir.appendingPathComponent("Casa Luna código.jpg")
    try? Data("pdf bytes".utf8).write(to: pdf); try? Data(repeating: 7, count: 2048).write(to: jpg)
    async let one: Void = store.accAttach(seed0, pdf)
    async let two: Void = store.accAttach(seed0, jpg)
    _ = await (one, two)
    await settle()
    func seedNow() -> Item? { shown().first { $0.id == seed0.id } }
    let got = seedNow()?.files ?? []
    expect(Set(got.map(\.name)) == ["Rental agreement.pdf", "Casa Luna código.jpg"] && got.allSatisfy { $0.id != nil } && got.first { $0.name.hasSuffix(".jpg") }?.size == 2048 && errors.isEmpty,
           "two files dropped at once are both on the event, with their names and sizes (\(got.map(\.name)), \(errors))")
    if let s0 = seedNow() { var renamed = s0; renamed.title = "Seed with files"; expect(store.accUpdate(renamed, old: s0) == nil, "an edit on an event with files"); await settle() }
    expect(seedNow()?.title == "Seed with files" && seedNow()?.files.count == 2, "an edit keeps the files (\(seedNow()?.files.map(\.name) ?? []))")
    if let s1 = seedNow(), let f = s1.files.first(where: { $0.name.hasSuffix(".pdf") }) {
        expect((try? await store.accFetch(s1, f)) == Data("pdf bytes".utf8), "an attached file opens with its own bytes")
        var stranger = f; stranger.url = "https://evil.example/steal"
        let sent: Data??; do { sent = .some(try await store.accFetch(s1, stranger)) } catch { sent = nil }  // a throw means a request went out
        expect(sent == .some(nil), "a link to another server never gets the password")
        await store.accDetach(s1, f)
        await settle()
    }
    expect(seedNow()?.files.map(\.name) == ["Casa Luna código.jpg"] && errors.isEmpty, "a removed file is gone, the other stays (\(seedNow()?.files.map(\.name) ?? []), \(errors))")
    if let s2 = seedNow() { var back = s2; back.title = "Seed event"; _ = store.accUpdate(back, old: s2); await settle() }

    // A change the server refuses must not take a later change down with it.
    guard let seed = shown().first, let href = store.accData.dav[c.id]?.first(where: { $0.value.events.first?.uid == "seed1" })?.key else { return 1 }
    store.accData.dav[c.id]?[href]?.etag = "\"stale\""
    var clash = seed; clash.title = "Seed clash"
    _ = store.accUpdate(clash, old: seed)
    _ = store.accAdd(Item(id: "", calendarID: c.id, title: "After the clash", start: start, end: start.addingTimeInterval(3600), allDay: false, place: "", notes: "", showAs: .busy), alertMinutes: nil, repeats: nil)
    await settle()
    expect(Set(shown().map(\.title)) == ["Seed event", "After the clash"] && errors.count == 1, "a refused edit reloads, and the add behind it still lands (\(shown().map(\.title)), \(errors))")
    expect(await store.addICloud(email: "T@example.com", password: "pw")?.message.contains("already") == true && store.accounts.count == 1, "the same iCloud account can't be added twice")
    store.removeAccount(a.id)
    expect(store.accounts.isEmpty && shown().isEmpty, "removing the account clears it")
    print(fails == 0 ? "accounts-check: all passed" : "accounts-check: \(fails) failed")
    return fails == 0 ? 0 : 1
}

func accountsSelftest(_ expect: (Bool, String) -> Void, at: (Int, Int, Int, Int, Int) -> Date) {
    AccountSecrets.testMode = true
    let c = AccCal(id: "acc-1-0a1b2c", remote: "https://p1.example/cal/home/", title: "Home", color: "#FF0000", writable: true)
    let base = Item(id: "", calendarID: c.id, title: "Dinner, with Ana; 7", start: at(2026, 10, 30, 19, 0), end: at(2026, 10, 30, 21, 0), allDay: false,
                    place: "Casa Luna", notes: "Line one\nLine two", showAs: .busy)
    let made = icsNew(uid: "u1", base, link: "https://zoom.us/j/123", alertMinutes: 15, rule: nil)
    let back = parseICS(made).first
    expect(back?.title == "Dinner, with Ana; 7" && back?.notes == "Line one\nLine two" && back?.start == base.start && back?.end == base.end, "accounts: a new event file reads back the same")
    expect(back?.url == "https://zoom.us/j/123" && back?.alarms == [-900], "accounts: the link and the alert are in the file")
    var moved = base; moved.title = "Dinner moved"; moved.start = at(2026, 10, 31, 20, 0); moved.end = at(2026, 10, 31, 22, 0); moved.showAs = .free
    let guest = made.replacingOccurrences(of: "END:VEVENT", with: "ATTENDEE;CN=Ana:mailto:ana@example.com\r\nEND:VEVENT")
    let patched = icsPatch(guest, occurrence: nil, moved, link: "")
    let p = parseICS(patched).first
    expect(p?.title == "Dinner moved" && p?.start == moved.start && p?.free == true && p?.url == "" && p?.alarms == [-900], "accounts: an edit rewrites what changed and keeps the alert")
    expect(patched.contains("ATTENDEE;CN=Ana") && patched.contains("SEQUENCE:1"), "accounts: an edit keeps the guests and counts up")
    let weekly = icsNew(uid: "w1", base, link: "", alertMinutes: nil, rule: "FREQ=WEEKLY")
    let occ = addDays(base.start, 7)
    var one = base; one.title = "Just this week"; one.start = occ.addingTimeInterval(3600); one.end = occ.addingTimeInterval(7200)
    let over = icsPatch(weekly, occurrence: occ, one, link: "")
    let items = davItems(c, ["h": DavRes(etag: nil, text: over, events: parseICS(over))], from: base.start, to: addDays(base.start, 21))
    expect(items.count == 3 && items.filter { $0.title == "Just this week" }.count == 1 && items.first { $0.title == "Just this week" }?.start == one.start,
           "accounts: one changed occurrence of a weekly event, the rest unchanged")
    expect(items.contains { $0.id == "\(c.id)/w1|\(Int(occ.timeIntervalSince1970))" }, "accounts: a changed occurrence keeps its id")
    var wholeDay = base; wholeDay.allDay = true; wholeDay.start = at(2026, 11, 2, 0, 0); wholeDay.end = at(2026, 11, 3, 0, 0)
    let days = icsPatch(icsNew(uid: "d1", wholeDay, link: "", alertMinutes: nil, rule: "FREQ=WEEKLY"), occurrence: at(2026, 11, 9, 0, 0), wholeDay, link: "")
    expect(days.contains("RECURRENCE-ID;VALUE=DATE:20261109\r\n"), "accounts: a changed day of an all-day series names the day")
    let dropped = icsDropOccurrence(over, occ)
    let left = davItems(c, ["h": DavRes(etag: nil, text: dropped, events: parseICS(dropped))], from: base.start, to: addDays(base.start, 21))
    expect(left.count == 2 && !left.contains { $0.title == "Just this week" }, "accounts: deleting one occurrence of a weekly event")
    let long = icsNew(uid: "l", Item(id: "", calendarID: "", title: String(repeating: "é", count: 60), start: base.start, end: base.end, allDay: false, place: "", notes: "", showAs: .busy), link: "", alertMinutes: nil, rule: nil)
    expect(long.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 } && parseICS(long).first?.title == String(repeating: "é", count: 60), "accounts: long lines fold and read back")

    let att = icsNew(uid: "a1", base, link: "", alertMinutes: nil, rule: nil).replacingOccurrences(of: "END:VEVENT", with:
        "ATTACH;MANAGED-ID=97S;FMTTYPE=application/pdf;SIZE=240000;FILENAME=Rental agreement.pdf:https://p1.example/att/97S\r\nATTACH:https://example.com/menu.pdf\r\nEND:VEVENT")
    let af = parseICS(att).first?.files ?? []
    expect(af == [Attach(name: "Rental agreement.pdf", url: "https://p1.example/att/97S", size: 240000, id: "97S", type: "application/pdf"), Attach(name: "menu.pdf", url: "https://example.com/menu.pdf")],
           "accounts: attached files read from the event file")
    expect(icsPatch(att, occurrence: nil, moved, link: "").contains("MANAGED-ID=97S") && parseICS(icsDropAttach(att, "https://example.com/menu.pdf")).first?.files.count == 1,
           "accounts: an edit keeps the files; a plain link can be taken out")
    expect(attachDisposition("a.pdf") == "attachment;filename=\"a.pdf\"" && attachDisposition("código.jpg") == "attachment;filename=\"c_digo.jpg\";filename*=UTF-8''c%C3%B3digo.jpg",
           "accounts: file names for iCloud, accents in the UTF-8 form")
    expect(macAccountKind("iCloud") == "iCloud" && macAccountKind("john@gmail.com") == "Google" && macAccountKind("On My Mac") == nil, "accounts: which sign-in the attachments hint names")

    let xml = """
    <?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/">
    <d:response><d:href>/123/calendars/home/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Home</d:displayname>
    <a:calendar-color>#FF2968FF</a:calendar-color><d:current-user-privilege-set><d:privilege><d:read/></d:privilege><d:privilege><d:write/></d:privilege></d:current-user-privilege-set></d:prop></d:propstat></d:response>
    <d:response><d:href>/123/calendars/inbox/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/><c:schedule-inbox/></d:resourcetype></d:prop></d:propstat></d:response>
    <d:response><d:href>/123/calendars/shared/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Shared</d:displayname>
    <d:current-user-privilege-set><d:privilege><d:read/></d:privilege></d:current-user-privilege-set></d:prop></d:propstat></d:response></d:multistatus>
    """
    let cals = parseXML(Data(xml.utf8)).map { davCalendars($0, base: URL(string: "https://p1.example/123/calendars/")!, accountID: "acc-1") } ?? []
    expect(cals.map(\.title) == ["Home", "Shared"] && cals.first?.color == "#FF2968" && cals.map(\.writable) == [true, false] && cals.first?.remote == "https://p1.example/123/calendars/home/",
           "accounts: the iCloud calendar list (no inbox, read-only marked)")
    let evx = "<d:multistatus xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\"><d:response><d:href>/123/calendars/home/u1.ics</d:href><d:propstat><d:prop><d:getetag>\"e1\"</d:getetag><c:calendar-data><![CDATA[\(made)]]></c:calendar-data></d:prop></d:propstat></d:response></d:multistatus>"
    let evs = parseXML(Data(evx.utf8)).map { davEvents($0, base: URL(string: "https://p1.example/")!) } ?? [:]
    expect(evs["https://p1.example/123/calendars/home/u1.ics"]?.etag == "\"e1\"" && evs.first?.value.events.first?.title == base.title, "accounts: events with their versions")

    let g: [String: Any] = ["id": "abc_20261030T160000Z", "recurringEventId": "abc", "status": "confirmed", "summary": "Standup", "etag": "\"9\"",
                            "start": ["dateTime": "2026-10-30T10:00:00-06:00"], "end": ["dateTime": "2026-10-30T10:30:00-06:00"],
                            "originalStartTime": ["dateTime": "2026-10-30T10:00:00-06:00"], "hangoutLink": "https://meet.google.com/abc-defg-hij",
                            "reminders": ["useDefault": true], "attachments": [["fileUrl": "https://drive.google.com/file/d/f1/view", "title": "Plan.pdf", "mimeType": "application/pdf", "fileId": "f1"]]]
    var gc = c; gc.defaultAlerts = [10]
    let ge = googleItem(gc, g)
    expect(ge?.item.id == "\(c.id)/abc|\(Int(at(2026, 10, 30, 10, 0).timeIntervalSince1970))" && ge?.master == "abc" && ge?.item.start == at(2026, 10, 30, 10, 0), "accounts: a Google occurrence")
    expect(ge?.item.alerts == [at(2026, 10, 30, 9, 50)] && ge.flatMap { callLink($0.item) }?.service == "Google Meet", "accounts: Google's own alerts and Meet link")
    expect(ge?.item.files == [Attach(name: "Plan.pdf", url: "https://drive.google.com/file/d/f1/view", id: "f1", type: "application/pdf")], "accounts: a Google event's Drive files")
    let allDay = googleItem(c, ["id": "x", "start": ["date": "2026-11-02"], "end": ["date": "2026-11-03"]])
    expect(allDay?.item.allDay == true && allDay?.item.start == at(2026, 11, 2, 0, 0) && allDay?.item.end == at(2026, 11, 3, 0, 0), "accounts: a Google all-day event")
    expect(googleItem(c, ["id": "y", "status": "cancelled", "start": ["date": "2026-11-02"], "end": ["date": "2026-11-03"]]) == nil, "accounts: a cancelled Google occurrence is left out")
    let body = googleBody(base, link: "https://zoom.us/j/9")
    expect((body["description"] as? String)?.hasSuffix("Join: https://zoom.us/j/9") == true && (body["start"] as? [String: Any])?["timeZone"] as? String == cal.timeZone.identifier,
           "accounts: a Google event with a pasted link")
}

// Marked as downloaded, so a program attached by someone else gets the Mac's usual "downloaded from the internet" check before it runs.
func quarantine(_ u: URL) throws {
    var v = URLResourceValues(); v.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
    var u = u; try u.setResourceValues(v)
}
