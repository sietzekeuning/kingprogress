import SwiftUI

struct LoginView: View {
    let monitor: RunMonitor
    let clipboard: ClipboardWatcher
    let openURL: (URL) -> Void
    let fit: (CGFloat) -> Void

    @State private var device: DeviceCode?
    @State private var token = ""
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var copied = false
    @State private var pasted = false
    @State private var showToken = true
    @FocusState private var tokenFocused: Bool

    private var hasClientId: Bool {
        !monitor.settings.clientId.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            BrandIcon(size: 36)
                .foregroundStyle(Theme.blue)
                .opacity(0.9)
                .padding(.bottom, 14)

            Text("Connect KingProgress")
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.17)
                .foregroundStyle(Theme.bright)

            Text("It watches your workflow runs and shows a card the moment one starts.")
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(Theme.muted2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
                .padding(.top, 6)
                .padding(.bottom, 22)

            // Device flow: only offered when this build has an OAuth App id.
            if hasClientId, device == nil {
                Button(busy ? "Contacting GitHub…" : "Sign in with GitHub", action: beginDeviceLogin)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy)

                Button(showToken ? "Hide token option" : "Use a personal access token instead") {
                    showToken.toggle()
                }
                .buttonStyle(LinkButtonStyle())
            }

            if let device {
                deviceBlock(device)
            }

            if showToken, device == nil {
                tokenBlock
            }

            if let error {
                Text(error)
                    .font(.system(size: 11.5))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
                    .padding(.top, 16)
            }

            if let notice {
                Text(notice)
                    .font(.system(size: 11.5))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.muted2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
                    .padding(.top, 16)
            }
        }
        .padding(EdgeInsets(top: 52, leading: 26, bottom: 30, trailing: 26))
        .frame(maxWidth: .infinity)
        .background(
            RadialGradient(colors: [Color(hex: 0x161d27), Theme.bg], center: UnitPoint(x: 0.5, y: 0), startRadius: 0, endRadius: 420)
        )
        .reportHeight()
        .onPreferenceChange(ContentHeightKey.self) { height in
            Task { @MainActor in fit(max(300, min(height, 700))) }
        }
        .onAppear(perform: start)
        .onDisappear {
            clipboard.stop()
            monitor.onDeviceLogin = nil
        }
    }

    // MARK: - Blocks

    private func deviceBlock(_ device: DeviceCode) -> some View {
        VStack(spacing: 0) {
            Text("Enter this code on GitHub:")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted2)

            Text(device.userCode)
                .font(.system(size: 22, design: .monospaced))
                .tracking(4.8)
                .foregroundStyle(Theme.bright)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.blue.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.blue.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .padding(.top, 10)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
                .onTapGesture(perform: copyCode)

            hint(Text("\(copied ? "Copied." : "Click the code to copy it.") The browser should already be open on \(device.verificationUri.replacingOccurrences(of: "https://", with: ""))."))

            Button("Cancel", action: cancelDeviceLogin)
                .buttonStyle(LinkButtonStyle())
        }
        .frame(maxWidth: 320)
    }

    private var tokenBlock: some View {
        VStack(spacing: 0) {
            Button("Create a token on GitHub") {
                openURL(GitHubAuth.tokenCreationURL())
                notice = "Waiting for you to copy the token…"
            }
            .buttonStyle(PrimaryButtonStyle())

            hint(
                Text("Opens GitHub with ")
                    + Text("repo").font(.system(size: 10.5, design: .monospaced))
                    + Text(" and ")
                    + Text("workflow").font(.system(size: 10.5, design: .monospaced))
                    + Text(" already ticked. Pick an expiry, click ")
                    + Text("Generate token").bold()
                    + Text(", then copy it — KingProgress picks it up from your clipboard by itself.")
            )

            HStack(spacing: 6) {
                SecureField("…or paste it here", text: $token)
                    .focused($tokenFocused)
                    .modifier(FieldChrome(focused: tokenFocused, armed: pasted, large: true))
                    .onSubmit { connect() }

                Button(busy ? "…" : "Connect") {
                    connect()
                }
                .buttonStyle(GoButtonStyle())
                .disabled(token.isEmpty || busy)
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: 320)
    }

    private func hint(_ text: Text) -> some View {
        text
            .font(.system(size: 11))
            .lineSpacing(3)
            .foregroundStyle(Theme.muted2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
    }

    // MARK: - Actions

    private func start() {
        showToken = !hasClientId

        // The clipboard is watched while this screen is open, so a freshly
        // copied token signs you in without any further clicking.
        clipboard.start { detected in
            if busy {
                return
            }
            token = detected
            pasted = true
            notice = "Token found on your clipboard — connecting…"
            connect(detected)
        }

        monitor.onDeviceLogin = { result in
            if case .failure(let failure) = result {
                device = nil
                error = failure.localizedDescription
            }
        }
    }

    private func connect(_ candidate: String? = nil) {
        let value = (candidate ?? token).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.isEmpty, !busy else {
            return
        }

        busy = true
        error = nil

        Task {
            do {
                let account = try await monitor.applyToken(value)
                notice = "Signed in as \(account.login)."
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }

    private func beginDeviceLogin() {
        busy = true
        error = nil

        Task {
            do {
                let device = try await monitor.startDeviceLogin()
                self.device = device
                if let url = URL(string: device.verificationUri) {
                    openURL(url)
                }
                copyCode()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func cancelDeviceLogin() {
        monitor.cancelDeviceLogin()
        device = nil
    }

    private func copyCode() {
        guard let device else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(device.userCode, forType: .string)
        copied = true
    }
}

// MARK: - Button styles

private struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let lit = hovering && isEnabled
        return configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.bright)
            .frame(maxWidth: 320)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(
                LinearGradient(
                    colors: lit ? [Color(hex: 0x333d4a), Color(hex: 0x262f39)] : [Color(hex: 0x2b3440), Color(hex: 0x212932)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(lit ? 0.2 : 0.12)))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.6)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct LinkButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.blue)
            .underline(hovering)
            .padding(4)
            .padding(.top, 12)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

private struct GoButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering && isEnabled ? Theme.greenHover : Theme.green))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
    }
}
