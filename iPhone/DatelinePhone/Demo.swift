#if DEBUG
// Debug builds only. `--sample -demo <screen>` opens one screen on the sample calendars for the cloud pictures;
// `--selftest` runs the checks below and quits. Neither ever asks for calendars, reminders, contacts or location, reads a Keychain or writes saved settings.
import Foundation
import SwiftUI
import EventKit
import CoreLocation
import Contacts
import DatelineCore

@MainActor
enum Demo {
    static let args = ProcessInfo.processInfo.arguments
    static var screen: String? { args.firstIndex(of: "-demo").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    static var selfTest: Bool { args.contains("--selftest") }
    static var savedAtStart: Set<String> = []

    /// The mockup's "today": Monday Oct 26, 2026, 9:41 in Costa Rica.
    static var today: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9, minute: 41))! }

    static func make() -> PhoneState? {
        guard screen != nil || selfTest else { return nil }
        savedAtStart = savedKeys()
        Look.reset(); WorkWeek.reset(); Alerts.reset(); Zones.reset(); WeatherPrefs.reset()  // never saved: Look.reset turns saving off first
        WorkWeek.start = "Sunday"  // the phone mockups' month starts on Sunday
        cal.timeZone = TimeZone(identifier: "America/Costa_Rica")!
        sampleToday = today
        Here.shared.spot = tamarindo  // the mockups' sunrise and weather; never the phone's location
        WeatherStore.sample = true  // made-up weather, never the network
        let app = PhoneState(store: Store(sample: true), today: today, sample: true)
        if let s = app.store.sets.first(where: { $0.name == "Family" }) { app.store.use(s) }
        for it in app.store.between(addDays(today, -7), addDays(today, 14)) where it.geo != nil { app.drive[it.id] = 25 }  // made-up drive times, never Apple Maps
        app.emails = sampleEmails()
        if selfTest { Task { await SelfTest.run(app) } } else { open(screen!, app) }
        return app
    }

    static func sampleEmails() -> [EmailFind] {
        func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(byAdding: .minute, value: h * 60 + m, to: addDays(cal.startOfDay(for: today), d))! }
        var dentist = Parsed(title: "Dentist", start: at(2, 8, 30), end: at(2, 9, 30), place: "Clínica Dental Playa", dateGiven: true)
        dentist.calendarCode = "family"
        return [
            EmailFind(from: "Clínica Dental Playa", quote: "Your appointment is confirmed for Wednesday, October 28 at 8:30 a.m. Please arrive 10 minutes early.", parsed: dentist, emoji: "🦷", alert: "Arrive 10 min early"),
            EmailFind(from: "Escuela Tamarindo", quote: "The school play is on Thursday at 5 p.m. in the main hall.", parsed: Parsed(title: "School play", start: at(3, 17), end: at(3, 18), place: "Main hall", dateGiven: true)),
            EmailFind(from: "SANSA Airlines", quote: "Your flight to San José leaves Saturday at 7:15 a.m.", parsed: Parsed(title: "Flight to San José", start: at(5, 7, 15), end: at(5, 8, 15), dateGiven: true)),
        ]
    }

    static func open(_ s: String, _ app: PhoneState) {
        switch s {
        case "day": app.mode = .day
        case "month": app.mode = .month
        case "year": app.mode = .year
        case "add": app.adding = "Dinner with Ana Friday 7pm at Lola's"
        case "details", "details2":
            let title = s == "details" ? "Dentist" : "Marco at the condo"
            if let it = app.store.between(today, addDays(today, 7)).first(where: { $0.title == title }) { app.open(it) }
        case "tasks": app.tab = .tasks
        case "places": app.tab = .places
        case "email": app.email = app.emails.first
        case "settings": app.tab = .settings; License.shared.test = .bought(serial: 586300)
        case "unlock": License.shared.test = .trial(daysLeft: 3); app.showUnlock = true
        case "widgets": app.demoWidgets = true
        default: app.mode = .week
        }
    }

    /// The app's own saved settings, by name (system keys left out).
    static func savedKeys() -> Set<String> {
        let all = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        return Set(all.keys.filter { !$0.hasPrefix("com.apple.") && !$0.hasPrefix("Apple") && !$0.hasPrefix("NS") })
    }
}

/// `--selftest`: drives the real phone state and store on the sample calendars, prints PASS or FAIL for each check, then quits with 0 or 1.
@MainActor
enum SelfTest {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }

    static func run(_ app: PhoneState) async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)  // let the first screen draw
        let store = app.store, today = Demo.today, mon = cal.startOfDay(for: today)
        check(store.access == .sample && store.taskAccess == .sample, "the checks run on the sample calendars and reminders")
        check(EKEventStore.authorizationStatus(for: .event) == .notDetermined && EKEventStore.authorizationStatus(for: .reminder) == .notDetermined, "calendars and reminders were never asked for")
        check(CLLocationManager().authorizationStatus == .notDetermined && CNContactStore.authorizationStatus(for: .contacts) == .notDetermined, "location and contacts were never asked for")

        licenseSelftest { ok, name in check(ok, name) }
        weatherSelftest { ok, name in check(ok, name) }
        syncSelftest { ok, name in check(ok, name) }  // a pretend iCloud in memory, never the real one

        check(store.activeSet?.name == "Family" && store.hidden.contains("work") && !store.hidden.contains("family"), "the Family set shows only its calendars")
        app.mode = .week
        check(app.days == [mon, addDays(mon, 1), addDays(mon, 2)], "the week shows three days from today")
        app.step(1)
        check(app.anchor == addDays(mon, 3), "a swipe moves the week by three days")
        app.mode = .day; app.step(-1)
        check(app.anchor == addDays(mon, 2), "a swipe moves the day view by one day")
        app.goToday()
        check(app.anchor == mon, "Today goes back to today")
        app.mode = .month
        check(monthGrid(mon).first == addDays(mon, -29) && weekLetters().first == "S", "the month starts on Sunday Sep 27, like the mockup")
        check(!store.shown(on: addDays(mon, 2)).filter(\.allDay).isEmpty, "the school holiday shows on Wednesday")
        app.mode = .week

        let p = parseSentence("Dinner with Ana Friday 7pm at Lola's", now: today)
        let fri7 = cal.date(byAdding: .hour, value: 19, to: addDays(mon, 4))!
        check(p.title == "Dinner with Ana" && p.place == "Lola's" && p.start == fri7, "the add box reads name, day, time and place")
        check(app.calendarFor(p)?.id == "family", "a new event goes to the Family set's calendar")
        guard case .success(let added) = app.add(p) else { check(false, "adding an event works"); return finish() }
        check(store.between(addDays(mon, 4), addDays(mon, 5)).contains { $0.id == added.id && $0.calendarID == "family" }, "the new event is on Friday's calendar")
        var moved = added; moved.title = "Dinner with Ana and Sam"; moved.place = "Casa Luna"
        check(store.update(moved) == nil && store.between(addDays(mon, 4), addDays(mon, 5)).first { $0.id == added.id }?.title == moved.title, "editing the name and place saves")
        check(store.delete(moved) == nil && !store.between(addDays(mon, 4), addDays(mon, 5)).contains { $0.id == added.id }, "deleting the event takes it off the calendar")

        let mail = app.emails.count
        if case .success(let d) = app.add(app.emails[0].parsed, emoji: app.emails[0].emoji) {
            check(store.between(addDays(mon, 2), addDays(mon, 3)).first { $0.id == d.id }.map { $0.emoji == "🦷" && $0.calendarID == "family" } == true, "an event from an email keeps its emoji and calendar")
            store.delete(d)
        } else { check(false, "an event from an email is added") }
        check(app.emails.count == mail, "adding from the sheet is what clears an email, not the add itself")

        if let t = store.todos.first(where: { $0.title == "Call the plumber" }) {
            app.toggle(t)
            check(store.todos.first { $0.id == t.id }?.done == true, "ticking a task finishes it")
            app.moveTask(t, days: 1)
            check(store.todos.first { $0.id == t.id }?.due == addDays(mon, 1), "swiping a task moves it to tomorrow")
        } else { check(false, "the sample has the plumber task") }
        let n = store.todos.count
        app.addTask("Buy coffee tomorrow 9am")
        check(store.todos.count == n + 1 && store.todos.last.map { $0.title == "Buy coffee" && $0.timed && $0.due == cal.date(byAdding: .hour, value: 9, to: addDays(mon, 1)) } == true, "a typed task gets its day and time")
        check(dayTasks(store, mon, now: today).contains { $0.title == "Pay condo fee" }, "an overdue task shows on today's tasks row")

        check(!License.shared.enter("DLK-K000001.not-a-real-key") && License.shared.status == .bought(serial: 0), "a wrong key is refused and changes nothing")
        check(!store.trialOver, "the sample calendars never lock, whatever the trial")

        check(Demo.savedKeys() == Demo.savedAtStart, "no saved settings were written")
        finish()
    }

    static func finish() {
        print("DONE failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
