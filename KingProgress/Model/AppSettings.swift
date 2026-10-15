import AppKit
import Observation

/// How the cards are drawn. Classic is the solid GitHub-dark look the
/// Electron version had; glass is a frosted pane that blurs whatever is
/// behind it.
enum CardTheme: String, CaseIterable, Codable {
    case classic
    case glass

    var label: String {
        switch self {
        case .classic: "Classic"
        case .glass: "Glass"
        }
    }

    var note: String {
        switch self {
        case .classic:
            return "Solid dark cards, the way KingProgress has always looked."
        case .glass:
            if #available(macOS 26, *) {
                return "Liquid Glass, like the rest of your Mac. Follows the system's light or dark appearance."
            }
            return "Frosted, see-through cards that blur whatever is behind them. Follows the system's light or dark appearance."
        }
    }
}

/// The corner of the screen the stack of cards calls home. Top right is
/// where it has always been; bottom right keeps it out of the way of the
/// system's own notification banners, which land in the top right too.
enum StackCorner: String, CaseIterable, Codable {
    case topRight
    case bottomRight

    var label: String {
        switch self {
        case .topRight: "Top right"
        case .bottomRight: "Bottom right"
        }
    }

    /// Whether the stack hangs from the top of the screen or stands on
    /// its bottom. Either way the newest card is on top.
    var isTop: Bool { self == .topRight }
}

/// Everything KingProgress remembers between launches. Plain values go to
/// UserDefaults; the token goes to the keychain.
@MainActor
@Observable
final class AppSettings {
    // Device flow needs a client id but no secret, so it is safe to ship.
    // Leave it empty and KingProgress falls back to a pasted personal access
    // token; set it to your own OAuth App (with "Enable Device Flow" ticked)
    // to get the "Sign in with GitHub" button.
    static let builtInClientId = ""

    /// How many recently updated repositories to follow when none are ticked.
    static let autoRepoCount = 5

    private let defaults = UserDefaults.standard
    private static let tokenAccount = "github-token"

    private(set) var watchedRepos: [String]
    private(set) var actorFilter: ActorFilter
    private(set) var account: Account?
    private(set) var openAtLogin: Bool
    private(set) var cardTheme: CardTheme
    /// Show the subject of the commit each run is building on its card.
    private(set) var showCommitMessage: Bool
    /// Which corner of the screen the stack of cards calls home.
    private(set) var stackCorner: StackCorner
    /// How far the stack of cards has been dragged from its home in
    /// `stackCorner`, in screen points (x to the right, y up). Zero is home.
    private(set) var popupOffset: CGSize
    /// Let other apps on this Mac put their own cards in the stack, through
    /// the card socket.
    private(set) var showExternalCards: Bool
    /// Let other apps on this Mac read the status of the runs in the
    /// watched repositories, through runs.json.
    private(set) var shareRunStatus: Bool

    init() {
        watchedRepos = defaults.stringArray(forKey: "watchedRepos") ?? []
        actorFilter = defaults.data(forKey: "actorFilter").flatMap { try? JSONDecoder().decode(ActorFilter.self, from: $0) } ?? .everyone
        account = defaults.data(forKey: "account").flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
        // On by default. KingProgress is only useful while it is running, and
        // it lives in the menu bar where a forgotten copy costs nothing - so
        // the honest default is the one where it is simply there after a
        // restart. The setting turns it off.
        openAtLogin = defaults.object(forKey: "openAtLogin") as? Bool ?? true
        cardTheme = defaults.string(forKey: "cardTheme").flatMap(CardTheme.init(rawValue:)) ?? .classic
        showCommitMessage = defaults.object(forKey: "showCommitMessage") as? Bool ?? true
        let offset = CGSize(width: defaults.double(forKey: "popupOffsetX"), height: defaults.double(forKey: "popupOffsetY"))
        if let corner = defaults.string(forKey: "stackCorner").flatMap(StackCorner.init(rawValue:)) {
            stackCorner = corner
            popupOffset = offset
        } else if offset.height < -(NSScreen.screens.first?.visibleFrame.height ?? 900) / 2 {
            // Before there was a choice of corner, the way to the bottom of
            // the screen was to drag the stack there, where it hung off the
            // edge with only its newest card in sight. That stack is a
            // bottom-right one: it stands on the bottom edge, all of it
            // showing, and is home there.
            stackCorner = .bottomRight
            popupOffset = CGSize(width: offset.width, height: 0)
        } else {
            stackCorner = .topRight
            popupOffset = offset
        }
        showExternalCards = defaults.object(forKey: "showExternalCards") as? Bool ?? true
        shareRunStatus = defaults.object(forKey: "shareRunStatus") as? Bool ?? true
    }

    var token: String? {
        get { Keychain.read(Self.tokenAccount) }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.write(newValue, account: Self.tokenAccount)
            } else {
                Keychain.delete(Self.tokenAccount)
            }
        }
    }

    /// `defaults write com.kingprogress.app githubClientId <id>` overrides the built-in one.
    var clientId: String {
        (defaults.string(forKey: "githubClientId") ?? Self.builtInClientId).trimmingCharacters(in: .whitespaces)
    }

    func setWatchedRepos(_ repos: [String]) {
        watchedRepos = repos.filter { $0.contains("/") }
        defaults.set(watchedRepos, forKey: "watchedRepos")
    }

    func setActorFilter(_ filter: ActorFilter) {
        let logins = filter.logins.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        actorFilter = ActorFilter(mode: filter.mode, logins: logins)
        defaults.set(try? JSONEncoder().encode(actorFilter), forKey: "actorFilter")
    }

    func setAccount(_ account: Account?) {
        self.account = account
        if let account {
            defaults.set(try? JSONEncoder().encode(account), forKey: "account")
        } else {
            defaults.removeObject(forKey: "account")
        }
    }

    func setOpenAtLogin(_ enabled: Bool) {
        openAtLogin = enabled
        defaults.set(enabled, forKey: "openAtLogin")
    }

    func setCardTheme(_ theme: CardTheme) {
        cardTheme = theme
        defaults.set(theme.rawValue, forKey: "cardTheme")
    }

    func setShowCommitMessage(_ enabled: Bool) {
        showCommitMessage = enabled
        defaults.set(enabled, forKey: "showCommitMessage")
    }

    /// For snapshots: draw the cards in a theme without remembering it, so
    /// the copy of KingProgress the user runs is not switched along with it.
    func previewCardTheme(_ theme: CardTheme) {
        cardTheme = theme
    }

    func setShowExternalCards(_ enabled: Bool) {
        showExternalCards = enabled
        defaults.set(enabled, forKey: "showExternalCards")
    }

    func setShareRunStatus(_ enabled: Bool) {
        shareRunStatus = enabled
        defaults.set(enabled, forKey: "shareRunStatus")
    }

    /// Picking a corner sends the stack there, wherever it was dragged to:
    /// an offset from the old corner means nothing from the new one.
    func setStackCorner(_ corner: StackCorner) {
        guard corner != stackCorner else {
            return
        }
        setStackPosition(corner, offset: .zero)
    }

    func setPopupOffset(_ offset: CGSize) {
        setStackPosition(stackCorner, offset: offset)
    }

    /// The corner and the offset are stored together: an offset means
    /// nothing without the corner it is measured from.
    func setStackPosition(_ corner: StackCorner, offset: CGSize) {
        stackCorner = corner
        popupOffset = offset
        defaults.set(corner.rawValue, forKey: "stackCorner")
        defaults.set(Double(offset.width), forKey: "popupOffsetX")
        defaults.set(Double(offset.height), forKey: "popupOffsetY")
    }
}
