// Phase 3 rows in the event details (approved mockup): emoji, color, tags, and the formatted notes box.
import SwiftUI
import AppKit

// The emoji row: the button opens the picker under it.
struct EmojiRow: View {
    @ObservedObject var store: Store
    @Binding var item: Item
    let commit: () -> Void
    @State private var open = false
    var body: some View {
        HStack(spacing: 8) {
            Button { open = true } label: {
                Text(item.emoji.isEmpty ? "Add" : item.emoji).font(.ui(item.emoji.isEmpty ? 12 : 15)).foregroundStyle(Palette.text2)
                    .frame(minWidth: 30, minHeight: 26).padding(.horizontal, item.emoji.isEmpty ? 6 : 0)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Palette.field)).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line))
            }.buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                EmojiPicker(recent: store.recentEmoji) { e in item.emoji = e; store.usedEmoji(e); open = false; commit() }
            }
            if !item.emoji.isEmpty { Button("Remove") { item.emoji = ""; commit() }.buttonStyle(.plain).font(.ui(12)).foregroundStyle(Palette.text3) }
        }
    }
}

// shortcut: a hand-picked set with a few search words each, not every emoji; add rows here when one is missing.
let emojiGroups: [(String, [(String, String)])] = [
    ("Places", [("🏠", "home house condo"), ("🏢", "office building work"), ("🏥", "hospital clinic doctor"), ("🏖️", "beach vacation"),
                ("✈️", "plane flight travel"), ("🛫", "plane departure airport"), ("🚗", "car drive"), ("🌊", "ocean surf wave"),
                ("⛪", "church"), ("🏫", "school"), ("🏨", "hotel"), ("🏋️", "gym workout")]),
    ("People", [("👪", "family"), ("👶", "baby"), ("🧑‍⚕️", "doctor nurse"), ("🦷", "tooth dentist"), ("💇", "haircut hair"),
                ("🤝", "meeting deal handshake"), ("🎂", "birthday cake"), ("💑", "date couple"), ("🏃", "run running"), ("🐶", "dog pet vet")]),
    ("Things", [("📋", "board meeting clipboard"), ("💼", "work business"), ("📞", "call phone"), ("💻", "computer laptop"),
                ("🔧", "fix repair tools maintenance"), ("📦", "package delivery"), ("🎓", "school graduation class"), ("⚽", "soccer football sport"),
                ("💡", "idea"), ("🧾", "bill receipt invoice"), ("🎉", "party celebrate"), ("🛒", "shopping groceries market"), ("💊", "medicine pills"),
                ("📅", "calendar date"), ("✂️", "cut"), ("🎵", "music concert")]),
    ("Food", [("☕", "coffee"), ("🍽️", "dinner lunch restaurant meal"), ("🍕", "pizza"), ("🍺", "beer drinks"), ("🍷", "wine"),
              ("🥗", "salad lunch"), ("🍳", "breakfast"), ("🍰", "cake dessert"), ("🥥", "coconut")]),
]

struct EmojiPicker: View {
    let recent: [String]
    let pick: (String) -> Void
    @State private var search = ""
    @State private var group = "Recent"
    var body: some View {
        let all = emojiGroups.flatMap(\.1)
        let shown: [String] = !search.isEmpty
            ? all.filter { ($0.1 + " ").localizedCaseInsensitiveContains(search) }.map(\.0)
            : group == "Recent" ? recent + all.map(\.0).filter { !recent.contains($0) }  // recently used come first
            : emojiGroups.first { $0.0 == group }?.1.map(\.0) ?? []
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search emoji", text: $search).textFieldStyle(.roundedBorder)
            HStack(spacing: 2) {
                ForEach(["Recent"] + emojiGroups.map(\.0), id: \.self) { g in
                    Button(g) { group = g; search = "" }.buttonStyle(.plain).font(.ui(11.5, weight: g == group ? .semibold : .regular))
                        .foregroundStyle(g == group && search.isEmpty ? Palette.text : Palette.text3).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(g == group && search.isEmpty ? Palette.lineSoft : .clear))
                }
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 2), count: 8), spacing: 2) {
                    ForEach(shown, id: \.self) { e in
                        Button { pick(e) } label: { Text(e).font(.system(size: 19)).frame(width: 30, height: 30).contentShape(Rectangle()) }.buttonStyle(.plain)
                    }
                }
            }.frame(height: 140)
            if shown.isEmpty { Text("No emoji matches \u{201C}\(search)\u{201D}").font(.ui(11.5)).foregroundStyle(Palette.text3) }
        }.padding(12).frame(width: 272)
    }
}

// The color row: the calendar's own color first, then the eight event colors. Clicking the picked one goes back to the calendar's.
struct ColorRow: View {
    @ObservedObject var store: Store
    @Binding var item: Item
    let commit: () -> Void
    var body: some View {
        HStack(spacing: 3) {
            dot(store.calendar(item.calendarID)?.color ?? .gray, on: item.color == nil) { item.color = nil }.help("The calendar's color")
            ForEach(Palette.tags.indices, id: \.self) { i in dot(Palette.tags[i], on: item.color == i) { item.color = item.color == i ? nil : i } }
        }
    }

    func dot(_ c: Color, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button { act(); commit() } label: {
            Circle().fill(c).frame(width: 15, height: 15).padding(2.5).overlay(Circle().strokeBorder(on ? Palette.text : .clear, lineWidth: 1.5))
        }.buttonStyle(.plain)
    }
}

// The tags row: pills with an x, then a box that suggests tags already in use.
struct TagsRow: View {
    @ObservedObject var store: Store
    @Binding var item: Item
    let commit: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        let typed = text.trimmingCharacters(in: .whitespaces)
        let hits = typed.isEmpty ? [] : store.allTags.filter { $0.0.localizedCaseInsensitiveContains(typed) && !item.tags.contains($0.0) }.prefix(5)
        let isNew = !typed.isEmpty && !store.allTags.contains { $0.0.caseInsensitiveCompare(typed) == .orderedSame } && !item.tags.contains(typed)
        VStack(alignment: .leading, spacing: 0) {
            Flow {
                ForEach(item.tags, id: \.self) { t in
                    HStack(spacing: 4) {
                        Circle().fill(Palette.tag(t)).frame(width: 6, height: 6)
                        Text(t).font(.ui(12))
                        Button { item.tags.removeAll { $0 == t }; commit() } label: { Image(systemName: "xmark").font(.ui(8, weight: .bold)) }
                            .buttonStyle(.plain).foregroundStyle(Palette.text3)
                    }.padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Palette.lineSoft))
                }
                TextField(item.tags.isEmpty ? "Add a tag" : "", text: $text).textFieldStyle(.plain).font(.ui(12)).frame(minWidth: 60)
                    .focused($focused).onSubmit { add(hits.first?.0 ?? (isNew ? typed : nil)) }
            }
            .padding(5).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.field))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Palette.accent : Palette.line))
            if focused && (!hits.isEmpty || isNew) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(hits.enumerated()), id: \.element.0) { i, h in
                        Button { add(h.0) } label: {
                            HStack(spacing: 6) {
                                Circle().fill(Palette.tag(h.0)).frame(width: 7, height: 7)
                                Text(h.0)
                                Spacer()
                                Text("\(h.1) event" + (h.1 == 1 ? "" : "s")).font(.ui(11)).foregroundStyle(Palette.text3)
                            }.padding(.horizontal, 8).padding(.vertical, 4).background(i == 0 ? Palette.accentSoft : .clear).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if isNew {
                        Button { add(typed) } label: {
                            Text("+ New tag \u{201C}\(typed)\u{201D}").foregroundStyle(Palette.accent).padding(.horizontal, 8).padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading).background(hits.isEmpty ? Palette.accentSoft : .clear).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                .font(.ui(12)).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.pop).shadow(color: .black.opacity(0.14), radius: 8, y: 4))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
                .padding(.top, 3)
            }
        }
    }

    func add(_ t: String?) {
        guard let t, !item.tags.contains(t) else { return }
        item.tags.append(t); text = ""; commit()
    }
}

// Lays its children out in rows that wrap, for the tag pills.
struct Flow: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 220
        return CGSize(width: w, height: rows(subviews, w).last.map { $0.y + $0.h } ?? 0)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for r in rows(subviews, b.width) { for (i, x, s) in r.items { subviews[i].place(at: CGPoint(x: b.minX + x, y: b.minY + r.y), proposal: ProposedViewSize(s)) } }
    }
    private func rows(_ subs: Subviews, _ w: CGFloat) -> [(y: CGFloat, h: CGFloat, items: [(Int, CGFloat, CGSize)])] {
        var out: [(y: CGFloat, h: CGFloat, items: [(Int, CGFloat, CGSize)])] = [], x: CGFloat = 0, y: CGFloat = 0
        for (i, v) in subs.enumerated() {
            var s = v.sizeThatFits(.unspecified)
            s.width = min(s.width, w)
            if i == subs.count - 1 { s.width = max(s.width, min(w, max(60, w - x))) }  // the typing box takes the rest of the line
            if x > 0 && x + s.width > w { y += (out.last?.h ?? 0) + spacing; x = 0 }
            if x == 0 { out.append((y, 0, [])) }
            out[out.count - 1].items.append((i, x, s)); out[out.count - 1].h = max(out[out.count - 1].h, s.height)
            x += s.width + spacing
        }
        return out
    }
}

// MARK: Formatted notes

// The calendar keeps plain text: bullets as "- ", checklist items as "[ ] " / "[x] ", numbered lines as they are, links as "text (address)".
let bulletMark = "• ", openBox = "☐ ", doneBox = "☑ "

// `like`: the notes as saved before; a line left as it was keeps its original marks ("• ", "[X] ", "[] "), so synced notes are not rewritten.
func notesPlain(_ a: NSAttributedString, like old: String = "") -> String {
    let kept = Dictionary(old.components(separatedBy: "\n").map { (notesShown($0), $0) }, uniquingKeysWith: { a, _ in a })
    let m = NSMutableAttributedString(attributedString: a)
    m.enumerateAttribute(.link, in: NSRange(location: 0, length: m.length), options: .reverse) { v, r, _ in
        let url = (v as? URL)?.absoluteString ?? (v as? String) ?? ""
        if !url.isEmpty && m.attributedSubstring(from: r).string != url { m.insert(NSAttributedString(string: " (\(url))"), at: r.upperBound) }
    }
    return m.string.components(separatedBy: "\n").map { l in
        kept[l] ?? (l.hasPrefix(bulletMark) ? "- " + l.dropFirst(2) : l.hasPrefix(openBox) ? "[ ] " + l.dropFirst(2) : l.hasPrefix(doneBox) ? "[x] " + l.dropFirst(2) : l)
    }.joined(separator: "\n")
}

func notesShown(_ plain: String) -> String {
    plain.components(separatedBy: "\n").map { l in
        l.hasPrefix("- ") ? bulletMark + l.dropFirst(2) : l.hasPrefix("[ ] ") ? openBox + l.dropFirst(4)
            : l.lowercased().hasPrefix("[x] ") ? doneBox + l.dropFirst(4) : l.hasPrefix("[] ") ? openBox + l.dropFirst(3) : l
    }.joined(separator: "\n")
}

func notesFont(_ bold: Bool = false, _ italic: Bool = false) -> NSFont {
    var d = NSFont.systemFont(ofSize: 13 * Look.scale).fontDescriptor
    d = d.withDesign(["Rounded": .rounded, "Serif": .serif, "Mono": .monospaced][Look.font] ?? .default) ?? d
    var t: NSFontDescriptor.SymbolicTraits = []
    if bold { t.insert(.bold) }
    if italic { t.insert(.italic) }
    return NSFont(descriptor: d.withSymbolicTraits(t), size: 0) ?? .systemFont(ofSize: 13 * Look.scale)
}

// The formatting bar plus the box. Bold, italic and links are kept by Dateline on this Mac (Item.rich); lists live in the text itself.
struct NotesBox: View {
    @Binding var item: Item
    @Binding var editing: Bool
    let locked: Bool
    let commit: () -> Void
    @StateObject private var holder = Holder()  // made once per box, not on every redraw
    final class Holder: ObservableObject { let view = NotesTextView.make() }
    var view: NotesTextView { holder.view }
    var body: some View {
        VStack(spacing: 0) {
            if !locked {
                HStack(spacing: 2) {
                    tool(Text("B").fontWeight(.bold), "Bold (Command B)") { view.toggle(bold: true) }
                    tool(Text("I").italic(), "Italic (Command I)") { view.toggle(bold: false) }
                    Palette.line.frame(width: 1, height: 14).padding(.horizontal, 4)
                    tool(Image(systemName: "list.bullet"), "Bullet list") { view.list(bulletMark) }
                    tool(Image(systemName: "list.number"), "Numbered list") { view.list("1. ") }
                    tool(Image(systemName: "checklist"), "Checklist") { view.list(openBox) }
                    tool(Image(systemName: "link"), "Link (Command K)") { view.link() }
                    Spacer()
                }.padding(.horizontal, 4).padding(.vertical, 3).overlay(alignment: .bottom) { Palette.line.frame(height: 1) }
            }
            NotesEditor(view: view, item: $item, editing: $editing, locked: locked, commit: commit).frame(minHeight: 110)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.field)).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    func tool<V: View>(_ label: V, _ help: String, _ act: @escaping () -> Void) -> some View {
        Button { act(); if !editing { commit() } } label: { label.font(.ui(12)).foregroundStyle(Palette.text2).frame(width: 24, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(help)
    }
}

struct NotesEditor: NSViewRepresentable {
    let view: NotesTextView
    @Binding var item: Item
    @Binding var editing: Bool
    let locked: Bool
    let commit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let s = NSScrollView()
        s.hasVerticalScroller = true; s.drawsBackground = false; s.borderType = .noBorder
        view.isEditable = !locked
        view.changed = { a in
            item.notes = notesPlain(a, like: item.notes)
            item.rich = hasStyle(a) ? try? a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) : nil
        }
        view.began = { editing = true }
        view.ended = { editing = false; commit() }
        view.load(item)
        s.documentView = view
        return s
    }

    func updateNSView(_ s: NSScrollView, context: Context) {
        // Someone else changed the notes (Apple Calendar, undo) while the box was not being typed in.
        // Compared in the box's own form, so "[] " or "[X] " typed on the phone does not reload it on every redraw.
        if !editing && notesPlain(view.textStorage ?? NSAttributedString()) != notesPlain(NSAttributedString(string: notesShown(item.notes))) { view.load(item) }
    }

    // Bold, italic or a link anywhere: worth keeping the formatted copy.
    func hasStyle(_ a: NSAttributedString) -> Bool {
        var found = false
        a.enumerateAttributes(in: NSRange(location: 0, length: a.length)) { at, _, stop in
            let t = (at[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            if at[.link] != nil || t.contains(.bold) || t.contains(.italic) { found = true; stop.pointee = true }
        }
        return found
    }
}

final class NotesTextView: NSTextView, NSTextViewDelegate {
    var changed: (NSAttributedString) -> Void = { _ in }
    var began: () -> Void = {}, ended: () -> Void = {}

    static func make() -> NotesTextView {
        let v = NotesTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 110))
        v.isRichText = true; v.allowsUndo = true; v.drawsBackground = false
        v.textContainerInset = NSSize(width: 4, height: 6)
        v.isVerticallyResizable = true; v.autoresizingMask = [.width]
        v.textContainer?.widthTracksTextView = true
        v.isAutomaticQuoteSubstitutionEnabled = false; v.isAutomaticDashSubstitutionEnabled = false
        v.delegate = v
        return v
    }

    var base: [NSAttributedString.Key: Any] { [.font: notesFont(), .foregroundColor: NSColor.labelColor] }

    func load(_ it: Item) {
        let a = it.rich.flatMap { try? NSMutableAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) }
            ?? NSMutableAttributedString(string: notesShown(it.notes), attributes: base)
        let all = NSRange(location: 0, length: a.length)
        a.addAttribute(.foregroundColor, value: NSColor.labelColor, range: all)  // RTF keeps a fixed color; follow light and dark instead
        // Re-make each font in the current Look font and size, keeping bold and italic.
        a.enumerateAttribute(.font, in: all) { v, r, _ in
            let t = (v as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            a.addAttribute(.font, value: notesFont(t.contains(.bold), t.contains(.italic)), range: r)
        }
        textStorage?.setAttributedString(a)
        typingAttributes = base
    }

    func textDidBeginEditing(_ n: Notification) { began() }
    func textDidEndEditing(_ n: Notification) { ended() }
    func textDidChange(_ n: Notification) { changed(textStorage ?? NSAttributedString()) }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, e.modifierFlags.intersection([.command, .option, .control, .shift]) == .command else { return super.performKeyEquivalent(with: e) }
        switch e.charactersIgnoringModifiers {
        case "b": toggle(bold: true)
        case "i": toggle(bold: false)
        case "k": link()
        default: return super.performKeyEquivalent(with: e)
        }
        return true
    }

    // Bold or italic on the selection, or for what is typed next when nothing is selected.
    func toggle(bold: Bool) {
        guard isEditable, let ts = textStorage else { return }
        let trait: NSFontDescriptor.SymbolicTraits = bold ? .bold : .italic
        func has(_ f: Any?) -> Bool { (f as? NSFont)?.fontDescriptor.symbolicTraits.contains(trait) ?? false }
        func flip(_ f: Any?, _ on: Bool) -> NSFont {
            let t = (f as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            return notesFont(bold ? on : t.contains(.bold), bold ? t.contains(.italic) : on)
        }
        let r = selectedRange()
        if r.length == 0 { typingAttributes[.font] = flip(typingAttributes[.font], !has(typingAttributes[.font])); return }
        var all = true
        ts.enumerateAttribute(.font, in: r) { v, _, _ in if !has(v) { all = false } }
        guard shouldChangeText(in: r, replacementString: nil) else { return }
        ts.enumerateAttribute(.font, in: r) { v, sub, _ in ts.addAttribute(.font, value: flip(v, !all), range: sub) }
        didChangeText()
    }

    // The lines the selection touches.
    var lineRange: NSRange { (string as NSString).lineRange(for: selectedRange()) }

    // Turns the selected lines into a list of this kind, or back to plain lines when they already are one.
    func list(_ mark: String) {
        guard isEditable else { return }
        let r = lineRange, s = string as NSString
        let lines = s.substring(with: r).components(separatedBy: "\n")
        let ends = lines.count > 1 && lines.last == ""  // the range takes the last line's Return with it
        let body = ends ? Array(lines.dropLast()) : lines
        let marks = [bulletMark, openBox, doneBox]
        func strip(_ l: String) -> String {
            if let m = marks.first(where: l.hasPrefix) { return String(l.dropFirst(m.count)) }
            if let n = numbered(l) { return String(l.dropFirst(n.count)) }
            return l
        }
        let already = !body.isEmpty && body.allSatisfy { mark == "1. " ? numbered($0) != nil : mark == openBox ? $0.hasPrefix(openBox) || $0.hasPrefix(doneBox) : $0.hasPrefix(mark) }
        let out = body.enumerated().map { i, l in already ? strip(l) : (mark == "1. " ? "\(i + 1). " : mark) + strip(l) }.joined(separator: "\n") + (ends ? "\n" : "")
        replace(r, with: out)
        setSelectedRange(NSRange(location: r.location + (out as NSString).length - (ends ? 1 : 0), length: 0))
    }

    // "12. " at the start of a line.
    func numbered(_ l: String) -> String? {
        let digits = l.prefix { $0.isASCII && $0.isNumber }.prefix(4)  // plain 0 to 9 only, so the next number always reads back
        return !digits.isEmpty && l.dropFirst(digits.count).hasPrefix(". ") ? digits + ". " : nil
    }

    func replace(_ r: NSRange, with text: String) {
        guard shouldChangeText(in: r, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: r, with: NSAttributedString(string: text, attributes: base))
        didChangeText()
    }

    // Typing "- " or "[] " at the start of a line starts a list; Return carries the list on, and Return on an empty item ends it.
    func textView(_ tv: NSTextView, shouldChangeTextIn r: NSRange, replacementString t: String?) -> Bool {
        guard let t, r.length == 0 else { return true }
        let s = string as NSString, line = s.lineRange(for: NSRange(location: r.location, length: 0))
        let before = s.substring(with: NSRange(location: line.location, length: r.location - line.location))
        if t == " " && (before == "-" || before == "*") { replace(NSRange(location: line.location, length: before.utf16.count), with: bulletMark); return false }
        if t == " " && before == "[]" { replace(NSRange(location: line.location, length: 2), with: openBox); return false }
        guard t == "\n" else { return true }
        let mark = [bulletMark, openBox, doneBox].first(where: before.hasPrefix) ?? numbered(before)
        guard let mark else { return true }
        if before == mark {  // empty item: end the list
            replace(NSRange(location: line.location, length: (mark as NSString).length), with: "")
            return false
        }
        let next = mark == doneBox ? openBox : numbered(mark).map { "\((Int($0.dropLast(2)) ?? 0) + 1). " } ?? mark
        replace(r, with: "\n" + next)
        setSelectedRange(NSRange(location: r.location + 1 + (next as NSString).length, length: 0))
        return false
    }

    // A click on a checkbox ticks it.
    override func mouseDown(with e: NSEvent) {
        let i = characterIndexForInsertion(at: convert(e.locationInWindow, from: nil))
        let s = string as NSString
        if isEditable, s.length > 0 {
            let at = min(i, s.length - 1), line = s.lineRange(for: NSRange(location: at, length: 0))
            let head = s.substring(with: NSRange(location: line.location, length: min(2, line.length)))
            if (head == openBox || head == doneBox) && at - line.location <= 1 {
                window?.makeFirstResponder(self)  // so leaving the box saves the tick
                replace(NSRange(location: line.location, length: 2), with: head == openBox ? doneBox : openBox)
                return
            }
        }
        super.mouseDown(with: e)
    }

    // Command K: links the selected words. The address comes from what is copied, or is typed in.
    func link() {
        guard isEditable else { return }
        var r = selectedRange()
        if r.length == 0 { r = selectionRange(forProposedRange: r, granularity: .selectByWord) }
        guard r.length > 0 else { NSSound.beep(); return }
        let word = (string as NSString).substring(with: r)
        let copied = NSPasteboard.general.string(forType: .string).flatMap { $0.hasPrefix("http") ? $0 : nil }
        let field = NSTextField(string: word.hasPrefix("http") ? word : copied ?? "https://")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let a = NSAlert()
        a.messageText = "Link \u{201C}\(word)\u{201D} to"
        a.accessoryView = field
        a.addButton(withTitle: "Link"); a.addButton(withTitle: "Cancel"); a.addButton(withTitle: "Remove link")
        a.window.initialFirstResponder = field
        let answer = a.runModal()
        guard answer != .alertSecondButtonReturn, shouldChangeText(in: r, replacementString: nil) else { return }
        if answer == .alertThirdButtonReturn { textStorage?.removeAttribute(.link, range: r) }
        else if let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespaces)), url.scheme != nil { textStorage?.addAttribute(.link, value: url, range: r) }
        didChangeText()
    }
}
