import AppKit
import Foundation
import Observation

// MARK: - A card from another app

/// A card another app on this Mac put in the stack through the card socket
/// (`CardServer`, protocol in docs/cards.md). KingProgress knows nothing
/// about what it is about: it draws whatever the client sent, in the same
/// chrome as a run, and tells the client what was clicked.
struct ExternalCard: Identifiable {
    /// The connection the card came in on. Zero is the demo, which has none.
    let client: Int
    /// The id the client gave the card, and the one it hears back. Only
    /// unique per client: two apps may both have a card called "1".
    let cardID: String
    var title: String
    var subtitle: String?
    var body: String?
    /// What the card is about happened then; the card shows how long ago.
    var date: Date
    /// One colour for the left edge, or several to split it.
    var accent: [UInt32]
    var avatar: CardAvatar?
    /// A small line icon before the title, for a card without an avatar.
    var glyph: CardIcon?
    var rows: [CardRow]
    var caption: String?
    var captionDot: UInt32?
    var actions: [CardAction]
    /// Makes it a one-line card: a check, what happened, and an undo.
    var strip: CardStrip?
    /// Seconds before the card leaves on its own; zero keeps it until it is
    /// dismissed or the client takes it back.
    var linger: TimeInterval
    /// Tooltip for clicking the card.
    var help: String?
    var language: CardLanguage
    /// When the card first showed up. A replacement keeps it, and with it
    /// its place in the stack.
    var arrivedAt: Date
    /// When the card leaves on its own. Nil while it waits under the cursor,
    /// and for a card that stays.
    var expiresAt: Date?
    /// What was left of the linger when the cursor came onto the card.
    var pausedLeft: TimeInterval?

    var key: String { "\(client):\(cardID)" }
    var id: String { key }

    /// How much of the linger is left, from 1 down to 0. Nil for a card
    /// that stays until it is dismissed, which gets no bar.
    func lingerFraction(at now: Date) -> Double? {
        guard linger > 0 else {
            return nil
        }
        let left = pausedLeft ?? expiresAt.map { $0.timeIntervalSince(now) } ?? linger
        return max(0, min(1, left / linger))
    }
}

enum CardAvatar {
    /// A website's logo, say. Drawn on a light tile.
    case image(NSImage)
    case initials(String)
}

struct CardRow {
    var title: String
    var subtitle: String?
    var avatar: CardAvatar?
}

struct CardAction {
    let id: String
    var title: String
    var icon: CardIcon?
}

struct CardStrip {
    var text: String
    var detail: String?
    var button: CardButton?
}

struct CardButton {
    let id: String
    var title: String
}

/// The line icons a client can ask for by name, as an action's icon or a
/// card's glyph.
enum CardIcon: String {
    case archive, check, reply, open, trash, spam, envelope, bell
}

/// The words a card's age is told in. A client picks one in its hello.
enum CardLanguage {
    case en, nl

    init(code: String) {
        self = code.lowercased().hasPrefix("nl") ? .nl : .en
    }

    /// How long ago `date` was, in as few characters as the language
    /// allows: "now", "12m", "2h"; "nu", "12 min", "2 u". Past a day the
    /// date itself says more.
    func age(of date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)

        if seconds < 60 {
            return self == .nl ? "nu" : "now"
        }
        if seconds < 60 * 60 {
            let minutes = Int(seconds / 60)
            return self == .nl ? "\(minutes) min" : "\(minutes)m"
        }
        if seconds < 24 * 60 * 60 {
            let hours = Int(seconds / 3600)
            return self == .nl ? "\(hours) u" : "\(hours)h"
        }
        let locale = Locale(identifier: self == .nl ? "nl_NL" : "en_US")
        return date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
    }
}

/// What KingProgress tells a client about one of its cards.
enum CardEvent {
    /// The card itself was clicked. It stays; the client usually takes it
    /// back once it has opened whatever the card is about.
    case open(String)
    /// One of the card's buttons, by the id the client gave it.
    case action(String, String)
    /// Closed with the ×, by Clear all, or because its time was up.
    case dismissed(String)

    var message: [String: String] {
        switch self {
        case .open(let id): ["type": "open", "id": id]
        case .action(let id, let action): ["type": "action", "id": id, "action": action]
        case .dismissed(let id): ["type": "dismissed", "id": id]
        }
    }
}

// MARK: - Reading a card off the wire

extension ExternalCard {
    static let defaultLinger: TimeInterval = 20
    static let defaultAccent: UInt32 = 0x7d8590

    /// A card as a client sent it. Nil without an id or a title; everything
    /// else is optional, and whatever is not understood is left out rather
    /// than costing the client its card.
    init?(json: [String: Any], client: Int, language: CardLanguage, now: Date = Date()) {
        guard let cardID = json["id"] as? String, !cardID.isEmpty,
              let title = json["title"] as? String, !title.isEmpty
        else {
            return nil
        }

        self.client = client
        self.cardID = cardID
        self.title = title
        subtitle = nonEmpty(json["subtitle"])
        body = nonEmpty(json["body"])
        date = number(json["date"]).map(Date.init(timeIntervalSince1970:)) ?? now

        // A single colour is forgiven for not being wrapped in a list.
        let accents = (json["accent"] as? [Any] ?? [json["accent"] as Any]).compactMap { ($0 as? String).flatMap(hexColor) }
        accent = accents.isEmpty ? [Self.defaultAccent] : accents

        avatar = cardAvatar(json["avatar"])
        glyph = (json["glyph"] as? String).flatMap(CardIcon.init(rawValue:))
        rows = (json["rows"] as? [[String: Any]] ?? []).compactMap { row in
            guard let title = nonEmpty(row["title"]) else { return nil }
            return CardRow(title: title, subtitle: nonEmpty(row["subtitle"]), avatar: cardAvatar(row["avatar"]))
        }
        caption = nonEmpty(json["caption"])
        captionDot = (json["captionDot"] as? String).flatMap(hexColor)
        actions = (json["actions"] as? [[String: Any]] ?? []).compactMap { action in
            guard let id = nonEmpty(action["id"]), let title = nonEmpty(action["title"]) else { return nil }
            return CardAction(id: id, title: title, icon: (action["icon"] as? String).flatMap(CardIcon.init(rawValue:)))
        }

        if let strip = json["strip"] as? [String: Any] {
            let button = (strip["button"] as? [String: Any]).flatMap { button -> CardButton? in
                guard let id = nonEmpty(button["id"]), let title = nonEmpty(button["title"]) else { return nil }
                return CardButton(id: id, title: title)
            }
            self.strip = CardStrip(text: nonEmpty(strip["text"]) ?? title, detail: nonEmpty(strip["detail"]), button: button)
        } else {
            strip = nil
        }

        linger = max(0, number(json["linger"]) ?? Self.defaultLinger)
        help = nonEmpty(json["help"])
        self.language = language
        arrivedAt = now
    }
}

private func nonEmpty(_ value: Any?) -> String? {
    guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    return string
}

private func number(_ value: Any?) -> Double? {
    switch value {
    case let value as Double: value
    case let value as Int: Double(value)
    case let value as NSNumber: value.doubleValue
    default: nil
    }
}

/// "#FF5A5F", "FF5A5F" or "#F55".
private func hexColor(_ string: String) -> UInt32? {
    var hex = string.trimmingCharacters(in: .whitespaces)
    if hex.hasPrefix("#") {
        hex.removeFirst()
    }
    if hex.count == 3 {
        hex = hex.map { "\($0)\($0)" }.joined()
    }
    guard hex.count == 6 else {
        return nil
    }
    return UInt32(hex, radix: 16)
}

private func cardAvatar(_ value: Any?) -> CardAvatar? {
    guard let avatar = value as? [String: Any] else {
        return nil
    }
    if let base64 = avatar["image"] as? String,
       let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
       let image = NSImage(data: data) {
        return .image(image)
    }
    if let initials = nonEmpty(avatar["initials"]) {
        return .initials(String(initials.prefix(3)))
    }
    return nil
}

// MARK: - The cards on screen

/// The cards other apps have put in the stack, newest first. The socket
/// fills it, the stack draws it, and whatever happens to a card goes back
/// to the app it came from through `onEvent`.
@MainActor
@Observable
final class ExternalCards {
    /// Leaving a card that waited under the cursor gives it at least this
    /// long again, so it does not vanish the moment the cursor moves off.
    static let minimumResume: TimeInterval = 3

    let verbose = ProcessInfo.processInfo.environment["KINGPROGRESS_VERBOSE"] == "1"

    /// The cards, newest first.
    private(set) var items: [ExternalCard] = []

    /// Fires after a card came or went, for the popup window.
    @ObservationIgnored var onChanged: (() -> Void)?
    /// Something happened to a card that its client should hear about.
    @ObservationIgnored var onEvent: ((CardEvent, Int) -> Void)?

    @ObservationIgnored private var lingerTimer: Timer?

    /// A new card, or a new version of one already on screen. The new
    /// version keeps the old one's place, and its countdown starts over: it
    /// has something new to say.
    func show(_ card: ExternalCard) {
        var card = card
        let now = Date()

        if let old = items.first(where: { $0.key == card.key }) {
            card.arrivedAt = old.arrivedAt
            // Under the cursor it keeps waiting, with the full time ahead.
            if card.linger > 0, old.pausedLeft != nil {
                card.pausedLeft = card.linger
            }
        }
        if card.linger > 0, card.pausedLeft == nil {
            card.expiresAt = now.addingTimeInterval(card.linger)
        }

        items.removeAll { $0.key == card.key }
        items.append(card)
        log("card \(card.key) shown: \(card.title)")
        publish()
    }

    /// The client took a card back. It slides out without a word back.
    func remove(cardID: String, client: Int) {
        let key = "\(client):\(cardID)"
        guard items.contains(where: { $0.key == key }) else {
            return
        }
        items.removeAll { $0.key == key }
        log("card \(key) removed by its client")
        publish()
    }

    /// A client went away. Its cards go with it: nobody is left to answer
    /// their buttons.
    func removeAll(client: Int) {
        guard items.contains(where: { $0.client == client }) else {
            return
        }
        items.removeAll { $0.client == client }
        log("cards of client \(client) removed")
        publish()
    }

    /// Cards from other apps were switched off.
    func removeAll() {
        guard !items.isEmpty else {
            return
        }
        items.removeAll()
        publish()
    }

    func dismiss(_ key: String) {
        guard let card = items.first(where: { $0.key == key }) else {
            return
        }
        items.removeAll { $0.key == key }
        tell(.dismissed(card.cardID), card)
        publish()
    }

    func dismissAll() {
        let cards = items
        items.removeAll()
        for card in cards {
            tell(.dismissed(card.cardID), card)
        }
        publish()
    }

    func open(_ key: String) {
        guard let card = items.first(where: { $0.key == key }) else { return }
        tell(.open(card.cardID), card)
    }

    func perform(_ action: String, on key: String) {
        guard let card = items.first(where: { $0.key == key }) else { return }
        tell(.action(card.cardID, action), card)
    }

    // MARK: - Linger
    //
    // A card leaves on its own once its linger is up, unless the cursor is
    // on it: someone reading a card does not want it pulled away mid-sentence.

    func setHovering(_ key: String, _ over: Bool) {
        guard let index = items.firstIndex(where: { $0.key == key }), items[index].linger > 0 else {
            return
        }

        if over {
            guard let expiresAt = items[index].expiresAt else { return }
            items[index].pausedLeft = max(0, expiresAt.timeIntervalSinceNow)
            items[index].expiresAt = nil
        } else {
            guard let left = items[index].pausedLeft else { return }
            items[index].expiresAt = Date().addingTimeInterval(max(left, Self.minimumResume))
            items[index].pausedLeft = nil
        }
        updateLingerTimer()
    }

    /// The cursor is on none of the cards. A safety net under the hover
    /// tracking: if a card never heard the cursor leave, it would wait
    /// forever.
    func resumeAll() {
        for index in items.indices where items[index].pausedLeft != nil {
            items[index].expiresAt = Date().addingTimeInterval(max(items[index].pausedLeft ?? 0, Self.minimumResume))
            items[index].pausedLeft = nil
        }
        updateLingerTimer()
    }

    private func pruneExpired() {
        let now = Date()
        let expired = items.filter { $0.expiresAt.map { $0 <= now } ?? false }

        guard !expired.isEmpty else {
            return
        }
        items.removeAll { card in expired.contains { $0.key == card.key } }
        for card in expired {
            tell(.dismissed(card.cardID), card)
        }
        publish()
    }

    /// A cheap local ticker, like the one that retires finished runs. Only
    /// runs while a card is counting down.
    private func updateLingerTimer() {
        let needed = items.contains { $0.expiresAt != nil }

        if needed, lingerTimer == nil {
            lingerTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pruneExpired() }
            }
        } else if !needed, let timer = lingerTimer {
            timer.invalidate()
            lingerTimer = nil
        }
    }

    private func publish() {
        // Newest first, by when each card first arrived. The key breaks a
        // tie, so two cards from the same instant do not swap places.
        items.sort { $0.arrivedAt == $1.arrivedAt ? $0.key < $1.key : $0.arrivedAt > $1.arrivedAt }
        updateLingerTimer()
        onChanged?()
    }

    private func tell(_ event: CardEvent, _ card: ExternalCard) {
        log("card \(card.key): \(event.message)")
        onEvent?(event, card.client)
    }

    private func log(_ message: String) {
        guard verbose else { return }
        FileHandle.standardError.write(Data("[kingprogress] \(message)\n".utf8))
    }

    // MARK: - Demo mode
    //
    // KINGPROGRESS_DEMO=1 and the snapshot also show a few cards like the
    // ones KingMail sends, so the mix of runs and mail can be seen. They go
    // through the same reading as a card off the socket.

    /// The key of the demo card the snapshot draws as if the cursor were on
    /// it, so its buttons show.
    static let demoHoverKey = "0:demo-mail"

    func startDemo() {
        let now = Date()
        let mailActions: [[String: Any]] = [
            ["id": "archive", "title": "Archiveren", "icon": "archive"],
            ["id": "spam", "title": "Spam", "icon": "spam"],
            ["id": "reply", "title": "Beantwoorden", "icon": "reply"],
        ]

        // The runs in the demo arrive at about 3 s and long before that, so
        // these land in between them. The lingers are picked so the
        // snapshot, at 19.5 s, catches every bar at a different point.
        let cards: [(at: Double, card: [String: Any])] = [
            (1.2, [
                "id": "demo-new", "title": "3 nieuwe berichten", "glyph": "envelope",
                "date": now.addingTimeInterval(-240).timeIntervalSince1970,
                "accent": ["#FF5A5F", "#F5A623", "#34C77B"],
                "rows": [
                    ["title": "Moneybird", "subtitle": "Factuur 2026-118 is betaald", "avatar": ["image": Self.demoLogo("M", 0x2d6fd8)]],
                    ["title": "TransIP", "subtitle": "Je factuur van oktober staat klaar", "avatar": ["image": Self.demoLogo("T", 0x0b58c9)]],
                    ["title": "Sportlink", "subtitle": "Wijziging speelschema 18 oktober", "avatar": ["image": Self.demoLogo("S", 0x7a3fc9)]],
                ],
                "caption": "In 3 accounts",
                "actions": [["id": "read-all", "title": "Alles gelezen", "icon": "check"], ["id": "open", "title": "Openen", "icon": "open"]],
                "linger": 30.5,
            ]),
            (1.6, [
                "id": "demo-undo", "title": "Gearchiveerd", "accent": ["#F5A623"],
                "strip": ["text": "Gearchiveerd", "detail": "Lunch vrijdag?", "button": ["id": "undo", "title": "Ongedaan maken"]],
                "linger": 50,
            ]),
            (2, [
                "id": "demo-initials", "title": "Bas Visser", "avatar": ["initials": "BV"],
                "date": now.addingTimeInterval(-120).timeIntervalSince1970,
                "subtitle": "Uitslag zaterdag en opstelling JO13",
                "body": "Wedstrijd zaterdag gaat door, aftrap 10:30. Verzamelen om 9:45 bij het clubhuis.",
                "accent": ["#34C77B"], "caption": "vv Waskemeer", "captionDot": "#34C77B",
                "actions": mailActions, "linger": 42, "help": "Openen in KingMail",
            ]),
            (17, [
                "id": "demo-mail", "title": "Marieke Postma", "avatar": ["image": Self.demoLogo("S", 0xd9480f)],
                "subtitle": "Re: Offerte webshop-koppeling",
                "body": "Dank voor de offerte. We willen graag door met de koppeling tussen de webshop en Exact Online, inclusief de voorraadsync.",
                "accent": ["#FF5A5F"], "caption": "King Websites", "captionDot": "#FF5A5F",
                "actions": mailActions, "linger": 30, "help": "Openen in KingMail",
            ]),
        ]

        for (at, json) in cards {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                MainActor.assumeIsolated {
                    guard let card = ExternalCard(json: json, client: 0, language: .nl) else { return }
                    self?.show(card)
                }
            }
        }
    }

    /// A stand-in for a website's logo: a letter on a coloured tile, as a
    /// base64 PNG, the way a client would send it.
    private static func demoLogo(_ letter: String, _ color: UInt32) -> String {
        let size = 64
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return ""
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let fill = NSColor(srgbRed: CGFloat((color >> 16) & 0xff) / 255, green: CGFloat((color >> 8) & 0xff) / 255, blue: CGFloat(color & 0xff) / 255, alpha: 1)
        fill.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()

        let text = NSAttributedString(string: letter, attributes: [
            .font: NSFont.systemFont(ofSize: 38, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let bounds = text.size()
        text.draw(at: NSPoint(x: (CGFloat(size) - bounds.width) / 2, y: (CGFloat(size) - bounds.height) / 2))
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .png, properties: [:])?.base64EncodedString() ?? ""
    }
}
