import SwiftUI

struct SettingsView: View {
    let monitor: RunMonitor
    let updates: UpdateController

    @State private var repos: [RepoSummary] = []
    @State private var loading = true
    @State private var query = ""
    @State private var loginDraft = ""
    @State private var openAtLogin = true
    @State private var repoListHeight: CGFloat = 0
    @FocusState private var focus: Field?

    private enum Field {
        case search, login
    }

    private var settings: AppSettings { monitor.settings }
    private var update: UpdateModel { updates.model }
    private var watched: Set<String> { Set(settings.watchedRepos) }
    private var actorFilter: ActorFilter { settings.actorFilter }

    var body: some View {
        VStack(spacing: 0) {
            if let account = monitor.account {
                section { accountSection(account) }
                divider
            }

            section { triggeredBy }
            divider
            section { repositories }
            divider
            section { startup }
            divider
            section { version }
        }
        .padding(EdgeInsets(top: 4, leading: 14, bottom: 16, trailing: 14))
        .onAppear { openAtLogin = settings.openAtLogin }
        .task {
            repos = await monitor.listRepos()
            loading = false
        }
    }

    // MARK: - Layout helpers

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }

    private var divider: some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
    }

    private func heading(_ title: String, count: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.66)
                .foregroundStyle(Theme.muted)
            Spacer()
            if let count {
                Text(count)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(.bottom, 8)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .lineSpacing(3)
            .foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
    }

    // MARK: - Account

    private func accountSection(_ account: Account) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: URL(string: account.avatarUrl)) { image in
                image.resizable()
            } placeholder: {
                Circle().fill(Theme.border)
            }
            .frame(width: 30, height: 30)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 0) {
                Text(account.login)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.bright)
                Text(scopeLabel(account))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.muted)
            }

            Spacer()

            Button("Sign out") {
                monitor.signOut()
            }
            .buttonStyle(GhostButtonStyle())
        }
    }

    private func scopeLabel(_ account: Account) -> String {
        if account.scopes.isEmpty {
            return "fine-grained token"
        }
        let missing = ["repo", "workflow"].filter { !account.scopes.contains($0) }
        return missing.isEmpty ? "repo, workflow" : "missing scope: \(missing.joined(separator: ", "))"
    }

    // MARK: - Triggered by

    private var triggeredBy: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Triggered by")

            HStack(spacing: 3) {
                segment("Anyone", .all)
                segment("Only me", .me)
                segment("Specific people", .only)
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))

            if actorFilter.mode == .only {
                VStack(alignment: .leading, spacing: 6) {
                    if actorFilter.logins.isEmpty {
                        Text("No one yet — nothing will show up.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.dim)
                    } else {
                        FlowLayout(spacing: 4) {
                            ForEach(actorFilter.logins, id: \.self) { login in
                                chip(login)
                            }
                        }
                    }

                    TextField("GitHub username, then Enter", text: $loginDraft)
                        .focused($focus, equals: .login)
                        .modifier(FieldChrome(focused: focus == .login))
                        .onSubmit(addLogin)
                }
                .padding(.top, 8)
            }

            note(actorNote)
        }
    }

    private func segment(_ label: String, _ mode: ActorMode) -> some View {
        let on = actorFilter.mode == mode
        return Button(label) {
            monitor.setActorFilter(ActorFilter(mode: mode, logins: actorFilter.logins))
        }
        .buttonStyle(SegmentStyle(on: on))
    }

    private func chip(_ login: String) -> some View {
        HStack(spacing: 4) {
            Text(login)
            Button {
                monitor.setActorFilter(ActorFilter(mode: actorFilter.mode, logins: actorFilter.logins.filter { $0 != login }))
            } label: {
                Text("×")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted2)
                    .padding(.horizontal, 2)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.text)
        .padding(EdgeInsets(top: 2, leading: 7, bottom: 2, trailing: 4))
        .background(Capsule().fill(Theme.border))
    }

    private func addLogin() {
        var value = loginDraft.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("@") {
            value.removeFirst()
        }
        if !value.isEmpty, !actorFilter.logins.contains(value) {
            monitor.setActorFilter(ActorFilter(mode: actorFilter.mode, logins: actorFilter.logins + [value]))
        }
        loginDraft = ""
    }

    private var actorNote: String {
        switch actorFilter.mode {
        case .all: "Every run in the repositories below shows up."
        case .me: "Only runs triggered by \(monitor.myLogin ?? "you")."
        case .only: "Only runs triggered by the people listed above."
        }
    }

    // MARK: - Repositories

    private var repositories: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Repositories", count: watched.isEmpty ? "auto" : "\(watched.count) watched")

            HStack(spacing: 6) {
                TextField("Search repositories", text: $query)
                    .focused($focus, equals: .search)
                    .modifier(FieldChrome(focused: focus == .search))

                if !watched.isEmpty {
                    Button("Reset") {
                        monitor.setWatchedRepos([])
                    }
                    .buttonStyle(GhostButtonStyle(small: true))
                }
            }
            .padding(.bottom, 8)

            if watched.isEmpty {
                note("Watching your \(AppSettings.autoRepoCount) most recently updated repositories. Tick any below to choose yourself.")
                    .padding(.top, 0)
                    .padding(.bottom, 8)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filteredRepos) { repo in
                        RepoRow(repo: repo, checked: watched.contains(repo.fullName)) {
                            toggleRepo(repo.fullName)
                        }
                    }

                    if loading {
                        note("Loading repositories…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                    } else if filteredRepos.isEmpty {
                        note("Nothing matches “\(query)”.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                    }
                }
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: RepoListHeightKey.self, value: proxy.size.height)
                })
            }
            .onPreferenceChange(RepoListHeightKey.self) { height in
                Task { @MainActor in repoListHeight = height }
            }
            .frame(height: min(260, repoListHeight))
            .padding(.horizontal, -6)
        }
    }

    private var filteredRepos: [RepoSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = needle.isEmpty ? repos : repos.filter { $0.fullName.lowercased().contains(needle) }

        // Watched repos float to the top so a long list stays manageable.
        return list.sorted { a, b in
            let aOn = watched.contains(a.fullName)
            let bOn = watched.contains(b.fullName)
            return aOn && !bOn
        }
    }

    private func toggleRepo(_ fullName: String) {
        var next = watched
        if next.contains(fullName) {
            next.remove(fullName)
        } else {
            next.insert(fullName)
        }
        // Keep the user's order so the list does not reshuffle under them.
        let ordered = settings.watchedRepos.filter { next.contains($0) } + (next.contains(fullName) && !settings.watchedRepos.contains(fullName) ? [fullName] : [])
        monitor.setWatchedRepos(ordered)
    }

    // MARK: - Startup

    private var startup: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Startup")

            HStack(spacing: 10) {
                Text("Open KingProgress when I log in")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text)
                Spacer()
                SwitchView(on: openAtLogin)
            }
            .contentShape(Rectangle())
            .onTapGesture { setOpenAtLogin(!openAtLogin) }

            note(openAtLogin
                ? "KingProgress comes back in the menu bar after a restart, without a window in the way."
                : "You start KingProgress yourself. Runs you miss while it is closed stay missed.")
        }
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        // Optimistic, so the switch moves under the finger; put it back if
        // the OS refused the change.
        withAnimation(.easeOut(duration: 0.15)) { openAtLogin = enabled }
        settings.setOpenAtLogin(enabled)

        guard LaunchAtLogin.isInstalled else {
            return
        }

        do {
            try LaunchAtLogin.set(enabled)
        } catch {
            withAnimation(.easeOut(duration: 0.15)) { openAtLogin = !enabled }
            settings.setOpenAtLogin(!enabled)
        }
    }

    // MARK: - Version

    private var version: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Version", count: update.currentVersion)

            HStack(spacing: 10) {
                Text(updateLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)

                Spacer()

                if update.status == .ready {
                    Button("Restart now") {
                        updates.installUpdate()
                    }
                    .buttonStyle(GhostButtonStyle(small: true))
                } else {
                    Button("Check now") {
                        updates.checkNow()
                    }
                    .buttonStyle(GhostButtonStyle(small: true))
                    .disabled(update.status == .checking || !updates.canCheck)
                    .opacity(update.status == .checking || !updates.canCheck ? 0.5 : 1)
                }
            }

            if update.status == .downloading {
                IndeterminateBar()
                    .padding(.top, 8)
            }

            note(updateNote)
        }
    }

    private var updateLine: String {
        switch update.status {
        case .checking: "Checking for a newer version…"
        case .downloading: "Downloading \(update.newVersion ?? "the update")…"
        case .ready: "KingProgress \(update.newVersion ?? "") is ready to install."
        case .error: "Could not check for updates."
        case .idle: "KingProgress is up to date."
        }
    }

    private var updateNote: String {
        switch update.status {
        case .ready:
            return "It installs on the next restart, whether you do it now or quit later."
        case .error:
            return "\(update.message ?? "KingProgress could not reach GitHub.") It tries again in a few hours."
        case .idle where update.checkedAt != nil:
            let time = update.checkedAt!.formatted(date: .omitted, time: .shortened)
            return "Checked at \(time). KingProgress checks a few times a day and installs new versions on restart."
        default:
            return "KingProgress checks GitHub a few times a day and installs new versions on restart."
        }
    }
}

// MARK: - Pieces

private struct RepoListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SegmentStyle: ButtonStyle {
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .foregroundStyle(on ? Theme.bright : Theme.muted2)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.raised : .clear))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: on)
    }
}

private struct RepoRow: View {
    let repo: RepoSummary
    let checked: Bool
    let toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { checked }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)

            Text(repo.fullName)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if repo.isPrivate {
                tag("private")
            } else if repo.isFork {
                tag("fork")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.panel : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5))
            .foregroundStyle(Theme.muted)
            .padding(.vertical, 1)
            .padding(.horizontal, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.border))
    }
}

private struct SwitchView: View {
    let on: Bool

    var body: some View {
        HStack {
            if on { Spacer(minLength: 0) }
            Circle()
                .fill(on ? Color.white : Theme.muted2)
                .frame(width: 11, height: 11)
            if !on { Spacer(minLength: 0) }
        }
        .padding(2)
        .frame(width: 30, height: 17)
        .background(Capsule().fill(on ? Theme.blueStrong : Theme.border))
        .overlay(Capsule().strokeBorder(on ? Theme.blueStrong : Theme.border2))
    }
}

private struct IndeterminateBar: View {
    @State private var sweeping = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule()
                    .fill(Theme.blueStrong)
                    .frame(width: proxy.size.width * 0.35)
                    .offset(x: sweeping ? proxy.size.width : -proxy.size.width * 0.35)
                    .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false), value: sweeping)
            }
        }
        .frame(height: 3)
        .clipShape(Capsule())
        .onAppear { sweeping = true }
    }
}

/// Lays chips out left to right, wrapping onto the next line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
