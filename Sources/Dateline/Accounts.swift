// Phase 8 (approved mockup, section 1): iCloud and Google accounts signed in inside Dateline, with no help from the Mac's settings.
// iCloud speaks CalDAV (email + app-specific password); Google signs in through the browser and speaks its Calendar API.
// Changes show at once and go to the account in the background, one at a time per account; a failed one reloads the calendar.
// The passwords and Google sign-ins live in a private file (never the Keychain, never --sample or a test run).
// The calendar-file writers and the server-answer readers here are pure, covered by --selftest; --accounts-check drives the network code against a stand-in server.
import Foundation
import SwiftUI
import AppKit
import Network
import CryptoKit
import UniformTypeIdentifiers
import DatelineCore

// The Attachments part of the event panel: the files, a drop area and Add…, or on a calendar from the Mac's settings, why not and where to sign in.
struct AttachmentsBox: View {
    @ObservedObject var store: Store
    let item: Item
    @State private var adding: [String] = []
    @State private var over = false
    @AppStorage("attachHintOff") private var hintOff = false
    @State private var signIn = ""  // Google sign-in progress or failure, shown under the hint
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let (a, c) = store.accCal(item.calendarID) { files(a, c) } else { macHint }
    }

    func files(_ a: Account, _ c: AccCal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(over ? Palette.accent : Palette.line, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
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
                    Text(t).font(.ui(10, weight: .bold)).foregroundStyle(.white).frame(width: 32, height: 32).background(col, in: RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.name).lineLimit(1).truncationMode(.middle).foregroundStyle(Palette.text)
                        if let n = f.size { Text(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)).font(.ui(11)).foregroundStyle(Palette.text3) }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).contextMenu { actions(a, f, writable) }
            Menu { actions(a, f, writable) } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Account actions").menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(Palette.text3)
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
                .font(.ui(12)).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading).background(Palette.tags[1].opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                // Google signs in straight away: its Accounts choice now leads to the Mac's settings, which this calendar already uses.
                Button("Sign in to \(kind)…") {
                    if kind == "Google" { signIn = "Finish signing in to Google in your browser."; Task { signIn = await store.addGoogle()?.message ?? "" } }
                    else { UserDefaults.standard.set("accounts", forKey: "settingsTab"); openSettings() }
                }.buttonStyle(.borderedProminent)
                Button("Not now") { hintOff = true }
            }.controlSize(.small)
            if !signIn.isEmpty { Text(signIn).font(.ui(12)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

// MARK: the Accounts tab

struct AccountSettings: View {
    @ObservedObject var store: Store
    @State var picked: String? = nil
    @State var adding: String? = nil  // "icloud" or "google" while that form shows
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var note = ""

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
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
                    Button { picked = nil; adding = nil; note = "" } label: { Image(systemName: "plus") }.accessibilityLabel("Add an account")
                        .buttonStyle(.borderless).frame(width: 28, height: 20).help("Add an account")
                    Button { if let p = picked, p != "mac" { store.removeAccount(p); picked = nil } } label: { Image(systemName: "minus") }.accessibilityLabel("Remove this account")
                        .buttonStyle(.borderless).frame(width: 28, height: 20).disabled(picked == nil || picked == "mac")
                    Spacer()
                }.padding(.top, 4)
            }.frame(width: 220)

            VStack(alignment: .leading, spacing: 12) {
                if adding == "icloud" { icloudForm }
                else if adding == "google" { googleSteps }
                else if let p = picked, let a = store.accounts.first(where: { $0.id == p }) { detail(a) }
                else if picked == "mac" {
                    Text("Calendars set up in the Mac's own settings keep working as before. If an account is also signed in here, Dateline shows its calendars once, from here.")
                        .font(.system(size: 12)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                    addChoices.padding(.top, 4)
                } else { addChoices }
                if !note.isEmpty { Text(note).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
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
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).foregroundStyle(on ? .white : Palette.text)
                    Text(sub).font(.system(size: 11)).foregroundStyle(on ? .white.opacity(0.85) : bad ? .red : Palette.text3)
                }
                Spacer(minLength: 0)
            }.padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain).background(on ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
    }

    func badge(_ kind: String) -> some View {
        let (t, c): (String, Color) = kind == "google" ? ("G", Color(red: 0.26, green: 0.52, blue: 0.96)) : kind == "icloud" ? ("☁", Color(red: 0.2, green: 0.6, blue: 0.95)) : ("⌘", Palette.text3)
        return Text(t).font(.system(size: 12, weight: .bold)).foregroundStyle(.white).frame(width: 24, height: 24).background(c, in: RoundedRectangle(cornerRadius: 4))
    }

    var addChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADD AN ACCOUNT").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.text3)
            choice("icloud", "iCloud", "Email and an app-specific password from your Apple Account") { adding = "icloud"; note = "" }
            choice("google", "Google", "Add it in the Mac's Internet Accounts") { adding = "google"; note = "" }
        }
    }

    func choice(_ kind: String, _ title: String, _ sub: String, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            HStack(spacing: 12) {
                badge(kind)
                VStack(alignment: .leading, spacing: 1) { Text(title).font(.system(size: 13, weight: .medium)); Text(sub).font(.system(size: 11)).foregroundStyle(Palette.text3) }
                Spacer()
            }.padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain).background(Palette.text3.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).disabled(busy)
    }

    var icloudForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an iCloud account").font(.system(size: 13, weight: .semibold))
            TextField("Apple Account email", text: $email).textFieldStyle(.roundedBorder).frame(width: 280)
            SecureField("App-specific password", text: $password).textFieldStyle(.roundedBorder).frame(width: 280)
            Text("Apple asks for an app-specific password for any calendar app that isn't Apple's. Make one at account.apple.com, under Sign-In and Security.")
                .font(.system(size: 12)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            Link("Open account.apple.com", destination: URL(string: "https://account.apple.com/account/manage")!).font(.system(size: 12))
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

    // Until Google verifies Dateline, its own sign-in shows Google's "not verified" page; the Mac's Internet Accounts route never does.
    var googleSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add your Google calendars").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Open Internet Accounts in your Mac's System Settings.")
                Text("2. Click Add Account, then Google, and sign in.")
                Text("3. Make sure Calendars is turned on.")
            }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text("Your Google calendars then appear in Dateline under On this Mac, usually within a minute.")
                .font(.system(size: 12)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Internet Accounts") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!) }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { adding = nil }
            }
            Divider()
            HStack(spacing: 4) {
                Text("Want to attach files to Google events?").foregroundStyle(Palette.text3)
                Button("Sign in to Google in Dateline") { google() }.buttonStyle(.link)
            }.font(.system(size: 12))
            Text("Google may show a warning on that page for now.").font(.system(size: 11)).foregroundStyle(Palette.text3)
        }
    }

    func detail(_ a: Account) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(a.email).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.text3).textCase(.uppercase)
            ForEach(a.cals, id: \.id) { c in
                HStack(spacing: 8) { Circle().fill(hexColor(c.color)).frame(width: 8, height: 8); Text(c.title).font(.system(size: 13)); if !c.writable { Text("read-only").font(.system(size: 11)).foregroundStyle(Palette.text3) } }
            }
            if let p = a.problem { Text(p).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text("If this account is also set up in the Mac's settings, Dateline shows its calendars once, not twice: the copy signed in here wins.")
                .font(.system(size: 12)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(a.synced.map { "Synced " + timeText($0, short: false) } ?? "Not synced yet").font(.system(size: 12)).foregroundStyle(Palette.text3)
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

