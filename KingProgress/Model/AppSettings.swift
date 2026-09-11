import Foundation
import Observation

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

    init() {
        watchedRepos = defaults.stringArray(forKey: "watchedRepos") ?? []
        actorFilter = defaults.data(forKey: "actorFilter").flatMap { try? JSONDecoder().decode(ActorFilter.self, from: $0) } ?? .everyone
        account = defaults.data(forKey: "account").flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
        // On by default. KingProgress is only useful while it is running, and
        // it lives in the menu bar where a forgotten copy costs nothing - so
        // the honest default is the one where it is simply there after a
        // restart. The setting turns it off.
        openAtLogin = defaults.object(forKey: "openAtLogin") as? Bool ?? true
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
}
