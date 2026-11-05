// iPhone step 2 (John 2026-11-04): Dateline's own extras (emoji, colors, tags, formatted notes, travel choices), calendar sets, recent emoji,
// alert sounds and Look settings, shared between the Mac and the iPhone through the person's own iCloud. No Dateline server.
// The events themselves already sync through iCloud and Google; only what Dateline adds on top goes here.
// Route: iCloud key-value storage, because it holds the data: John's Mac held 0 event extras and 2 KB of sets on 2026-11-04, and the self-check measures 500 formatted notes at a small part of its 1 MB.
// shortcut: everything in one compressed 1 MB value; move to CloudKit if `problem` ever reports it full.
import Foundation
import CryptoKit

/// Where the shared copy lives: the real iCloud, or a pretend one in memory for every check (as SampleCalendar stands in for real calendars).
@MainActor
public protocol CloudStore: AnyObject {
    func data() -> Data?
    func write(_ d: Data)
    func onChange(_ act: @escaping @MainActor () -> Void)  // the other device's copy arrived
}

@MainActor
public final class ICloudKVS: CloudStore {
    private let kv = NSUbiquitousKeyValueStore.default
    private var observer: Any?
    private static let key = "sync.v1"
    public init() { kv.synchronize() }
    public func data() -> Data? { kv.data(forKey: Self.key) }
    public func write(_ d: Data) { kv.set(d, forKey: Self.key) }
    public func onChange(_ act: @escaping @MainActor () -> Void) {
        observer = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: kv, queue: .main) { _ in Task { @MainActor in act() } }
    }
}

@MainActor
public final class MemoryCloud: CloudStore {
    public var raw: Data?
    public var writes = 0
    public init() {}
    public func data() -> Data? { raw }
    public func write(_ d: Data) { raw = d; writes += 1 }
    public func onChange(_ act: @escaping @MainActor () -> Void) {}
}

/// One record in the shared copy. `v` nil: removed on purpose here (a real delete, never a missing or unreadable value).
public struct SyncRec: Codable, Equatable { public var v: Data?; public var t: Double }
/// What this device and the shared copy last agreed on, per record: a fingerprint of the value and when it changed.
public struct Seen: Codable, Equatable { public var h: String?; public var t: Double }

func fingerprint(_ d: Data?) -> String? { d.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } }
// Records: "e/<uid>" one event's extras, "sets", "emoji", "s/<setting>". Every event record is one kind.
func syncKind(_ key: String) -> String { key.hasPrefix("e/") ? "e/" : key }
/// Google's own id and Apple's copy of it ("…@google.com") are the same event.
public func syncUID(_ uid: String) -> String { uid.hasSuffix("@google.com") ? String(uid.dropLast(11)) : uid }

/// Merges this device's records with the shared copy, record by record, the newest change winning.
/// `local`: what this device holds now, empty values left out. A record goes out as removed only when the person removed it (`removed`),
/// or when it is gone while others of its kind are still here and `blocked` doesn't hold its kind; an emptied, new or unread device never removes anything.
/// A record this device never agreed on is dated 0, so the copy already in iCloud comes first: an empty or new device can only receive.
/// Returns what to change here (nil value = remove), the shared copy to write (nil = nothing new for it) and the new agreements.
/// `stamps`: when the person made a change here, by record; a change without one is dated now.
public func syncMerge(local: [String: Data], seen: [String: Seen], remote: [String: SyncRec], now: Double, removed: Set<String> = [], blocked: Set<String> = [], stamps: [String: Double] = [:]) -> (here: [String: Data?], cloud: [String: SyncRec]?, seen: [String: Seen]) {
    let present = Set(local.keys.map(syncKind)).subtracting(blocked)
    var here: [String: Data?] = [:], cloud = remote, pushed = false, agreed = seen
    for k in Set(local.keys).union(seen.keys).union(remote.keys) {
        let lv = local[k], lh = fingerprint(lv), s = seen[k], theirs = remote[k]
        var mine: SyncRec?
        if let s, s.h == lh { mine = SyncRec(v: lv, t: s.t) }  // unchanged since the last agreement
        else if lv != nil { mine = SyncRec(v: lv, t: s == nil ? 0 : stamps[k] ?? now) }  // changed here; first contact (also before iCloud has downloaded): any dated copy comes first
        else if s != nil, removed.contains(k) || present.contains(syncKind(k)) { mine = SyncRec(v: nil, t: stamps[k] ?? now) }  // removed here
        if let m = mine, theirs.map({ m.t > $0.t }) ?? true {
            if theirs != m { cloud[k] = m; pushed = true }
            agreed[k] = Seen(h: lh, t: m.t)
        } else if let r = theirs {
            if s?.h == lh && s?.t == r.t { continue }  // already agreed on this version (written here in this device's own encoding)
            if fingerprint(r.v) != lh { here.updateValue(r.v, forKey: k) }
            agreed[k] = Seen(h: fingerprint(r.v), t: r.t)
        }
    }
    return (here, pushed ? cloud : nil, agreed)
}

/// Look and alert sound choices: the real saved settings, or a dictionary in memory for the checks and pictures.
public struct SyncSettings {
    public static let keys = ["lookAppearance", "lookFont", "lookScale", "lookPack", "lookHour", "alertSounds"]
    public var read: () -> [String: Any]
    public var write: (String, Any) -> Void
    public static var real: SyncSettings {
        SyncSettings(read: { Dictionary(uniqueKeysWithValues: keys.compactMap { k in UserDefaults.standard.object(forKey: k).map { (k, $0) } }) },  // only what was chosen: an untouched default is never sent
                     write: { k, v in  // only the arrived key is saved: the reload must not save the other settings' defaults as choices
                         UserDefaults.standard.set(v, forKey: k)
                         let was = Look.saves; Look.saves = false; Look.reload(); Alerts.reloadSounds(); Look.saves = was
                         Look.apply(); NotificationCenter.default.post(name: Look.synced, object: nil) })  // the Mac window redraws in the new Look
    }
    public static var memory: SyncSettings {
        final class Box { var d: [String: Any] = [:] }
        let b = Box()
        return SyncSettings(read: { b.d }, write: { b.d[$0] = $1 })
    }
}

/// Saved on this device between launches.
public struct SyncMemo: Codable, Equatable {
    var seen: [String: Seen] = [:]
    var uids: [String: String] = [:]  // this device's extras key -> the event's uid
    var alias: [String: String] = [:]  // a calendar id here -> the other device's name for it, so the name goes back unchanged
    var removed: Set<String> = []  // records the person removed here since the last pass (also the last one of its kind)
    var stamps: [String: Double] = [:]  // when the person changed each record here since the last pass
}

public struct SyncState {
    public var on: Bool?  // set by the checks; nil = the "Sync with your Mac" switch (on unless turned off)
    public var settings = SyncSettings.real
    public var clock: () -> Double = { Date().timeIntervalSince1970 }
    public var problem: String?  // the shared copy is full or unreadable: nothing was changed
    var memo = SyncMemo()
    var saved = SyncMemo()  // the memo as last saved
    var skip: Set<String> = []  // kinds whose saved copy did not read on this device: left out entirely
    var scanned: Date?
    var applying = false  // the other device's records being written here: not the person's changes
    var soon: Task<Void, Never>?
    var ticker: Task<Void, Never>?
    public init() {}
}

extension Store {
    public var syncOn: Bool { sync.on ?? (UserDefaults.standard.object(forKey: "syncExtras") as? Bool ?? true) }

    func startSync(_ c: CloudStore) {
        cloud = c
        if let v: SyncMemo = load("syncMemo") { sync.memo = v; sync.saved = v }  // unread: every record counts as first contact, so iCloud's copy wins and nothing is removed
        // A kind whose saved copy didn't read starts over as first contact, so an edit saved over it later can't send the rest as removed.
        if !sync.skip.isEmpty { sync.memo.seen = sync.memo.seen.filter { !sync.skip.contains(syncKind($0.key)) } }
        c.onChange { [weak self] in self?.syncNow() }
        // Look and alert sounds are changed outside the store: a pass every minute picks them up.
        sync.ticker = Task { [weak self] in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 60_000_000_000); self?.syncNow() }
        }
    }

    // Soon after a change here, so a burst of changes is one pass.
    public func syncSoon() {
        guard cloud != nil, access != .sample, sync.soon == nil else { return }
        sync.soon = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.sync.soon = nil
            self?.syncNow()
        }
    }

    // Records removed by the person here (an event's extras cleared or deleted, the last calendar set deleted).
    func syncRemoved(_ key: String) { sync.memo.removed.insert(key); syncChanged(key) }
    // When the person changed a record here, so a change made while sync was off or held back still dates from then.
    func syncChanged(_ key: String) { sync.memo.stamps[key] = sync.clock() }

    public func syncNow() {
        defer { if sync.memo != sync.saved { sync.saved = sync.memo; save(sync.memo, "syncMemo") } }  // also what changed outside a pass (uids learned while the switch was off)
        guard let cloud, syncOn else { return }
        var remote: [String: SyncRec] = [:]
        if let raw = cloud.data() {
            guard let d = try? (raw as NSData).decompressed(using: .zlib) as Data, let r = try? JSONDecoder().decode([String: SyncRec].self, from: d) else {
                sync.problem = "The iCloud copy of Dateline's extras can't be read."; return  // never written over
            }
            remote = r
        }
        // Sets name calendars and Reminders lists: they wait until both have been read, or the names would go out as this device's bare ids.
        let setsReady = canRead && taskAccess != .unknown
        if setsReady { let fixed = sets.map(localSet); if fixed != sets { sets = fixed } }  // set calendars that only now can be matched by name
        let skipped = { (k: String) in self.sync.skip.contains(syncKind(k)) || (k == "sets" && !setsReady) }
        let local = syncRecords().filter { !skipped($0.key) }
        let unmapped = extras.keys.contains { uidFor($0) == nil }  // an event not matched yet can't tell "gone" from "not read yet"
        let m = syncMerge(local: local, seen: sync.memo.seen.filter { !skipped($0.key) }, remote: remote.filter { !skipped($0.key) }, now: sync.clock(),
                          removed: sync.memo.removed, blocked: unmapped ? ["e/"] : [], stamps: sync.memo.stamps)
        var seen = m.seen.merging(sync.memo.seen.filter { skipped($0.key) }) { a, _ in a }
        if let out = m.cloud {
            let full = remote.merging(out) { $1 }
            guard let json = try? JSONEncoder().encode(full), let packed = try? (json as NSData).compressed(using: .zlib) as Data else { return }
            if packed.count < 900_000 { cloud.write(packed); sync.problem = nil }
            else {  // the other device's changes still come in; this device's stay unsent (not agreed) until there is room
                sync.problem = "Dateline's extras are too big for iCloud's 1 MB."
                for k in out.keys where out[k] != remote[k] { seen[k] = sync.memo.seen[k] }
            }
        } else { sync.problem = nil }
        let failed = applyHere(m.here)
        for k in failed { seen[k] = sync.memo.seen[k] }  // not applied, so not agreed: the newer copy keeps winning instead of being pushed over
        // Agreed as this device writes it back: another version's encoding of the same value must not count as a change here next pass.
        if !m.here.isEmpty { let now = syncRecords(); for k in m.here.keys where !failed.contains(k) { if let t = seen[k]?.t { seen[k] = Seen(h: fingerprint(now[k]), t: t) } } }
        let sent = sync.problem == nil
        sync.memo.seen = seen
        sync.memo.removed = sent ? sync.memo.removed.filter(skipped) : sync.memo.removed  // left-out kinds keep their removals for a later pass
        sync.memo.stamps = sent ? sync.memo.stamps.filter { skipped($0.key) } : sync.memo.stamps
        sync.memo.uids = sync.memo.uids.filter { extras[$0.key] != nil }
    }

    // The event a key belongs to, by its uid: "~uid" came from the other device, "calendar/uid" is an account's event, a plain key is looked up.
    func uidFor(_ k: String) -> String? {
        if k.hasPrefix("~") { return String(k.dropFirst()) }
        if let i = k.firstIndex(of: "/") { return syncUID(String(k[k.index(after: i)...])) }
        return sync.memo.uids[k]
    }

    private func names(_ infos: [CalInfo], _ id: String) -> String { sync.memo.alias[id] ?? infos.first { $0.id == id }.map { $0.account + "\u{1F}" + $0.title } ?? id }
    private func localID(_ p: String, _ infos: [CalInfo]) -> String {
        if infos.contains(where: { $0.id == p }) { return p }
        let parts = p.components(separatedBy: "\u{1F}")
        guard parts.count == 2 else { return p }
        let same = infos.filter { $0.title == parts[1] }, accountHere = infos.contains { $0.account == parts[0] }
        // The iPhone can call an account something else ("Gmail" for the Mac's address): then the title alone, only when no account here has that name and one calendar has the title. Else kept as is.
        guard let c = infos.first(where: { $0.account == parts[0] && $0.title == parts[1] }) ?? (!accountHere && same.count == 1 ? same[0] : nil) else { return p }
        sync.memo.alias[c.id] = p
        return c.id
    }
    private var calInfos: [CalInfo] { source.allCalendars() + calendars }
    private func localSet(_ s: CalSet) -> CalSet {
        let c = calInfos
        var s = s
        s.calendars = s.calendars.map { localID($0, c) }; s.defaultCalendar = s.defaultCalendar.map { localID($0, c) }; s.lists = s.lists?.map { localID($0, lists) }
        return s
    }

    // What this device holds now, as records. Empty values are left out: "nothing here" is never sent as a change.
    func syncRecords() -> [String: Data] {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        if canRead, sync.scanned == nil, extras.keys.contains(where: { uidFor($0) == nil }) {  // extras saved before step 2: their events' uids, once a launch (extras of events deleted elsewhere never match)
            sync.scanned = Date()
            let (a, b) = Self.accWindow()
            for it in source.events(from: a, to: b) where !it.uid.isEmpty && extras[key(it.id)] != nil { sync.memo.uids[key(it.id)] = syncUID(it.uid) }
        }
        var out: [String: Data] = [:]
        // One event can have two keys (the Mac's copy and an account's): the account's wins, then the plain one, then "~".
        func rank(_ k: String) -> Int { k.contains("/") ? 0 : k.hasPrefix("~") ? 2 : 1 }
        for k in extras.keys.sorted(by: { (rank($1), $1) < (rank($0), $0) }) {
            if let uid = uidFor(k), let x = extras[k], let d = try? enc.encode(x) { out["e/" + uid] = d }
        }
        let c = calInfos
        let portable = sets.map { s -> CalSet in
            var s = s
            s.calendars = s.calendars.map { names(c, $0) }; s.defaultCalendar = s.defaultCalendar.map { names(c, $0) }; s.lists = s.lists?.map { names(lists, $0) }
            return s
        }
        if !sets.isEmpty, let d = try? enc.encode(portable) { out["sets"] = d }
        if !recentEmoji.isEmpty, let d = try? enc.encode(recentEmoji) { out["emoji"] = d }
        for (k, v) in sync.settings.read() where JSONSerialization.isValidJSONObject([v]) { if let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .fragmentsAllowed]) { out["s/" + k] = d } }
        return out
    }

    // The other device's newer records, written here. A value that does not read is skipped, never written over a good one.
    // Returns the records that could not be applied.
    @discardableResult
    func applyHere(_ here: [String: Data?]) -> [String] {
        guard !here.isEmpty else { return [] }
        var failed: [String] = []
        sync.applying = true
        defer { sync.applying = false }
        let dec = JSONDecoder()
        var ex = extras
        for (k, v) in here {
            if k.hasPrefix("e/") {
                let uid = String(k.dropFirst(2)), x = v.flatMap { try? dec.decode(Extra.self, from: $0) }
                if v != nil && x == nil { failed.append(k); continue }
                let keys = Set(ex.keys.filter { uidFor($0) == uid } + sync.memo.uids.filter { $0.value == uid }.map(\.key))  // also a key emptied here, so it comes back under its own name
                for kk in keys.isEmpty ? ["~" + uid] : keys { ex[kk] = x }
            } else if k == "sets" {
                if v == nil { sets = [] }  // the other device deleted its last set
                else if let s = v.flatMap({ try? dec.decode([CalSet].self, from: $0) }) { sets = s.map(localSet) } else { failed.append(k) }
            } else if k == "emoji" {
                if let e = v.flatMap({ try? dec.decode([String].self, from: $0) }) { recentEmoji = e } else if v != nil { failed.append(k) }
            } else if k.hasPrefix("s/"), SyncSettings.keys.contains(String(k.dropFirst(2))) {
                if let val = v.flatMap({ try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }) { sync.settings.write(String(k.dropFirst(2)), val) } else if v != nil { failed.append(k) }
            }
        }
        if ex != extras { extras = ex }
        refetch()  // the views pick up the new extras
        return failed
    }
}

// Two stores on the sample calendars stand in for the Mac and the iPhone, sharing a pretend iCloud. Nothing real is read or written.
@MainActor public func syncSelftest(_ expect: (Bool, String) -> Void) {
    // The merge alone.
    let a = Data("a".utf8), b = Data("b".utf8)
    var m = syncMerge(local: [:], seen: [:], remote: ["e/1": SyncRec(v: a, t: 5)], now: 10)
    expect(m.here["e/1"] == .some(a) && m.cloud == nil, "sync: a new device takes iCloud's copy and sends nothing")
    m = syncMerge(local: [:], seen: ["e/1": Seen(h: fingerprint(a), t: 5)], remote: ["e/1": SyncRec(v: a, t: 5)], now: 10)
    expect(m.here["e/1"] == .some(a) && m.cloud == nil, "sync: an emptied device removes nothing and gets it back")
    m = syncMerge(local: ["e/2": b], seen: ["e/1": Seen(h: fingerprint(a), t: 5), "e/2": Seen(h: fingerprint(b), t: 5)], remote: ["e/1": SyncRec(v: a, t: 5), "e/2": SyncRec(v: b, t: 5)], now: 10)
    expect(m.cloud?["e/1"] == SyncRec(v: nil, t: 10), "sync: an event's extras removed here are removed in iCloud")
    m = syncMerge(local: ["e/1": b], seen: [:], remote: ["e/1": SyncRec(v: a, t: 5)], now: 10)
    expect(m.here["e/1"] == .some(a) && m.cloud == nil, "sync: on first contact iCloud's copy wins over a different one here")

    // The Mac and an empty iPhone.
    var t = 1000.0
    let cloud = MemoryCloud()
    let mac = Store(source: SampleCalendar()), phone = Store(source: SampleCalendar(prefix: "p"))  // the iPhone's event ids differ from the Mac's; the uids match
    phone.extras = [:]; phone.sets = []; phone.recentEmoji = []
    mac.recentEmoji = ["🏠", "🦷"]
    mac.sync.settings.write("lookFont", "Serif")
    for s in [mac, phone] { s.sync.on = true; s.sync.clock = { t }; s.cloud = cloud }
    let macExtras = mac.extras, macSets = mac.sets
    func find(_ s: Store, _ title: String) -> Item? { s.between(addDays(Date(), -60), addDays(Date(), 60)).first { $0.title == title } }

    phone.syncNow()  // the empty phone goes first
    expect(cloud.raw == nil, "sync: an empty iPhone writes nothing to iCloud")
    mac.syncNow()
    expect(cloud.raw != nil && mac.extras == macExtras && mac.sets == macSets, "sync: the Mac's first sync sends its extras and keeps them all")
    t += 10; phone.syncNow()
    expect(find(phone, "Dentist")?.emoji == "🦷" && find(phone, "Marco at the condo")?.tags == ["Condo", "Visitors"], "sync: the iPhone gets the Mac's emoji and tags")
    expect(phone.sets.map(\.name) == macSets.map(\.name) && phone.sets.first?.calendars == macSets.first?.calendars, "sync: the iPhone gets the calendar sets, matched to its calendars")
    expect(phone.recentEmoji == ["🏠", "🦷"] && phone.sync.settings.read()["lookFont"] as? String == "Serif", "sync: recent emoji and Look settings arrive")
    var w = cloud.writes
    mac.syncNow(); phone.syncNow(); mac.syncNow()
    expect(cloud.writes == w && mac.extras == macExtras, "sync: once both agree nothing more is written")

    // An empty side never erases the other.
    phone.extras = [:]; phone.sets = []
    t += 10; phone.syncNow(); mac.syncNow()
    expect(mac.extras == macExtras && mac.sets == macSets, "sync: an iPhone that lost its extras erases nothing on the Mac")
    expect(find(phone, "Dentist")?.emoji == "🦷" && phone.sets.count == macSets.count, "sync: and gets them back")
    mac.extras = [:]
    t += 10; mac.syncNow()
    expect(mac.extras == macExtras, "sync: a Mac that lost its extras gets them back from iCloud")

    // Newest change wins, per event, also when iCloud kept only the other device's whole copy.
    let before = cloud.raw
    t += 10
    if var d = find(mac, "Dentist") { d.emoji = "😬"; mac.update(d) }
    if var c = find(mac, "Marco at the condo") { c.color = 5; mac.update(c) }
    mac.syncNow()
    cloud.raw = before  // the iPhone wrote before the Mac's copy reached it
    t += 10
    if var d = find(phone, "Dentist") { d.emoji = "😁"; phone.update(d) }
    phone.syncNow(); mac.syncNow(); phone.syncNow()
    expect(find(mac, "Dentist")?.emoji == "😁" && find(phone, "Dentist")?.emoji == "😁", "sync: the newer change to the same event wins on both")
    expect(find(phone, "Marco at the condo")?.color == 5 && find(mac, "Marco at the condo")?.color == 5, "sync: the Mac's change to another event is not lost")
    t += 10
    if var d = find(phone, "Dentist") { d.emoji = ""; phone.update(d) }
    phone.syncNow(); mac.syncNow()
    expect(find(mac, "Dentist")?.emoji == "" && find(mac, "Marco at the condo")?.tags == ["Condo", "Visitors"], "sync: an emoji removed on the iPhone is removed on the Mac, nothing else")

    // A newer record this device can't read is skipped and not pushed over on the next pass.
    func edited(_ change: (inout [String: SyncRec]) -> Void) {
        guard let raw = cloud.raw, let d = try? (raw as NSData).decompressed(using: .zlib) as Data, var r = try? JSONDecoder().decode([String: SyncRec].self, from: d) else { return }
        change(&r)
        cloud.raw = try? (JSONEncoder().encode(r) as NSData).compressed(using: .zlib) as Data
    }
    t += 10
    edited { $0["e/sample-9"] = SyncRec(v: Data("not an extra".utf8), t: t) }
    let unreadable = cloud.raw
    mac.syncNow(); t += 10; mac.syncNow()
    expect(cloud.raw == unreadable && find(mac, "Marco at the condo")?.color == 5, "sync: a newer record that doesn't read is skipped and never pushed over")
    edited { $0["e/sample-9"] = SyncRec(v: try? JSONEncoder().encode(Extra(tags: ["Condo", "Visitors"], plain: nil)), t: t) }

    // Removing the last extras of all is still sent.
    t += 10; phone.syncNow(); mac.syncNow()
    if var c = find(phone, "Marco at the condo") { c.emoji = ""; c.color = nil; c.tags = []; phone.update(c) }
    t += 10; phone.syncNow(); mac.syncNow()
    expect(phone.extras.isEmpty && mac.extras.isEmpty, "sync: removing the very last extras on the iPhone removes them on the Mac")
    if var c = find(mac, "Marco at the condo") { c.tags = ["Condo"]; mac.update(c) }
    t += 10; mac.syncNow(); phone.syncNow()
    expect(find(phone, "Marco at the condo")?.tags == ["Condo"], "sync: and new extras after that still arrive")

    // A saved copy that didn't read on this device is left out: it sends nothing and takes nothing.
    phone.sync.skip = ["e/"]; phone.extras = [:]
    w = cloud.writes; t += 10; phone.syncNow(); mac.syncNow()
    expect(cloud.writes == w && phone.extras.isEmpty && find(mac, "Marco at the condo")?.tags == ["Condo"], "sync: extras that didn't read on the iPhone are left out and erase nothing")
    phone.sync.skip = []

    // A change made while held back keeps its own time: the Mac's later change wins.
    phone.sync.on = false
    t += 10; if var c = find(phone, "Marco at the condo") { c.tags = ["Old"]; phone.update(c) }
    t += 10; if var c = find(mac, "Marco at the condo") { c.tags = ["New"]; mac.update(c) }
    mac.syncNow(); phone.sync.on = true; t += 10; phone.syncNow()
    expect(find(phone, "Marco at the condo")?.tags == ["New"] && find(mac, "Marco at the condo")?.tags == ["New"], "sync: a change made with the switch off loses to a later one on the Mac")

    // A new event on a Google or Exchange calendar: its uid (and on some servers its id) changes once the server has it. The extras follow it.
    let macSrc = mac.source as! SampleCalendar, phoneSrc = phone.source as! SampleCalendar
    func serverGave(_ src: SampleCalendar, _ title: String, uid: String, id: String? = nil) {
        guard let i = src.events.firstIndex(where: { $0.title == title }) else { return }
        src.events[i].uid = uid; if let id { src.events[i].id = id }
    }
    t += 10
    if var g = find(mac, "Gym") { g.emoji = "🏋️"; mac.update(g) }  // made on the Mac before the server answered
    mac.syncNow()
    serverGave(macSrc, "Gym", uid: "server-gym")  // the server's own uid, the one the iPhone sees
    serverGave(phoneSrc, "Gym", uid: "server-gym")
    _ = mac.between(addDays(Date(), -60), addDays(Date(), 60))  // the Mac reads its calendar again
    t += 10; mac.syncNow(); phone.syncNow()
    expect(find(phone, "Gym")?.emoji == "🏋️", "sync: a new event's extras reach the iPhone after the server gives it its own uid")
    serverGave(macSrc, "Gym", uid: "server-gym-2", id: "gym-new-id")  // a server that also changes the event's id here
    serverGave(phoneSrc, "Gym", uid: "server-gym-2")
    let count = mac.extras.count
    t += 10; let seenGym = find(mac, "Gym")?.emoji; mac.syncNow(); phone.syncNow()
    expect(seenGym == "🏋️" && mac.extras.count == count && mac.extras["gym-new-id"]?.emoji == "🏋️", "sync: an event whose id changed keeps its extras on the Mac, under one key")
    expect(find(phone, "Gym")?.emoji == "🏋️" && phone.extras.values.filter { $0.emoji == "🏋️" }.count == 1, "sync: and on the iPhone, once, not twice")

    // Deleting the last calendar set deletes it on the other device too.
    t += 10; phone.syncNow(); mac.syncNow()
    for s in mac.sets { mac.deleteSet(s.id) }
    t += 10; mac.syncNow(); phone.syncNow()
    expect(mac.sets.isEmpty && phone.sets.isEmpty, "sync: deleting the last calendar set on the Mac deletes it on the iPhone")

    // A copy that can't be read is left alone; the switch off sends nothing.
    let good = cloud.raw, junk = Data("junk".utf8)
    cloud.raw = junk; w = cloud.writes
    let held = mac.extras
    mac.syncNow()
    expect(cloud.raw == junk && cloud.writes == w && mac.extras == held && mac.sync.problem != nil, "sync: an unreadable iCloud copy is never written over and changes nothing")
    cloud.raw = good; phone.sync.on = false
    if var d = find(phone, "Dentist") { d.emoji = "🦷"; phone.update(d) }
    w = cloud.writes; t += 10; phone.syncNow()
    expect(cloud.writes == w, "sync: with the switch off nothing is sent")

    // Size: 500 events with formatted notes, against iCloud's 1 MB.
    let rtf = { (i: Int) in Data(#"{\rtf1\ansi\ansicpg1252\cocoartf2822 \cocoatextscaling0\cocoaplatform0{\fonttbl\f0\fswiss\fcharset0 Helvetica;\f1\fswiss\fcharset0 Helvetica-Bold;}{\colortbl;\red255\green255\blue255;}{\*\expandedcolortbl;;}\pard\tx560\tx1120\pardirnatural\partightenfactor0 \f1\b\fs26 \cf0 Event \#(i) agenda\f0\b0 \ Bring the papers for visit \#(i), call \#(i * 7919 % 10007) first, room \#(i % 37). Ask about the \#(i * 31 % 97) open items and the next date.}"#.utf8) }
    var big: [String: SyncRec] = [:]
    for i in 0..<500 { big["e/uid-\(i)-\(UUID().uuidString)"] = SyncRec(v: try? JSONEncoder().encode(Extra(emoji: "🦷", tags: ["Tag \(i % 9)"], rich: rtf(i), plain: "Event \(i) agenda")), t: Double(i)) }
    let size = (try? (JSONEncoder().encode(big) as NSData).compressed(using: .zlib).count) ?? .max
    print("sync size: 500 events with formatted notes = \(size / 1024) KB of iCloud's 1024 KB")
    expect(size < 450_000, "sync: 500 formatted notes fit in half of iCloud's 1 MB (\(size / 1024) KB)")
}
