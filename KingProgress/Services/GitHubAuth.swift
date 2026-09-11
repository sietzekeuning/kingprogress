import Foundation

// GitHub authentication.
//
// Two routes, both without a client secret - this repository is public, so a
// secret could never ship with it:
//
//   1. Device flow (like `gh auth login`): needs an OAuth App client id, but no
//      secret. Only available once a client id is configured.
//   2. A personal access token the user pastes. The login screen opens GitHub
//      with the scopes pre-ticked and we pick the token up off the clipboard,
//      so in practice it is "click, click, done" as well.

struct AuthError: LocalizedError {
    let message: String
    let code: String

    init(_ message: String, code: String = "auth_error") {
        self.message = message
        self.code = code
    }

    var errorDescription: String? { message }
}

struct DeviceCode {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let interval: TimeInterval
    let expiresAt: Date
}

enum GitHubAuth {
    static let scopes = "repo workflow"

    private static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    private static let accessTokenURL = URL(string: "https://github.com/login/oauth/access_token")!

    private static func postForm(_ url: URL, _ body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(GitHubClient.userAgent, forHTTPHeaderField: "User-Agent")

        var components = URLComponents()
        components.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError("GitHub returned an unexpected response (\(status))", code: "bad_response")
        }

        return json
    }

    /// Step 1 of the device flow: ask GitHub for a code to show the user.
    static func requestDeviceCode(clientId: String) async throws -> DeviceCode {
        let data = try await postForm(deviceCodeURL, ["client_id": clientId, "scope": scopes])

        if let error = data["error"] as? String {
            // "Not Found" means the client id does not exist; "device_flow_disabled"
            // means the OAuth App exists but has device flow switched off.
            throw AuthError(
                error == "device_flow_disabled"
                    ? "This OAuth App does not have device flow enabled."
                    : "GitHub rejected the client id (\(error)).",
                code: error
            )
        }

        guard let deviceCode = data["device_code"] as? String,
              let userCode = data["user_code"] as? String,
              let verificationUri = data["verification_uri"] as? String
        else {
            throw AuthError("GitHub did not return a device code.", code: "bad_response")
        }

        let interval = (data["interval"] as? Double) ?? 5
        let expiresIn = (data["expires_in"] as? Double) ?? 900

        return DeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationUri: verificationUri,
            interval: interval,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    /// Step 2: poll until the user has approved in the browser. GitHub asks us
    /// to back off whenever it answers `slow_down`, so honour that.
    static func pollForDeviceToken(clientId: String, device: DeviceCode) async throws -> String {
        var wait = device.interval

        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(wait))

            if Task.isCancelled {
                break
            }

            if Date() > device.expiresAt {
                throw AuthError("The code expired before it was approved.", code: "expired_token")
            }

            let data = try await postForm(accessTokenURL, [
                "client_id": clientId,
                "device_code": device.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])

            if let token = data["access_token"] as? String {
                return token
            }

            switch data["error"] as? String {
            case "authorization_pending":
                break // the user is still busy in the browser
            case "slow_down":
                wait += 5
            case "expired_token":
                throw AuthError("The code expired before it was approved.", code: "expired_token")
            case "access_denied":
                throw AuthError("Access was denied in the browser.", code: "access_denied")
            case let other:
                throw AuthError("GitHub returned \"\(other ?? "unknown")\".", code: other ?? "unknown")
            }
        }

        throw AuthError("Sign-in was cancelled.", code: "cancelled")
    }

    /// Does this look like a GitHub token? Used to spot one on the clipboard.
    static func looksLikeToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.count > 255 || trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return false
        }

        return trimmed.range(of: #"^gh[posur]_[A-Za-z0-9]{16,}$"#, options: .regularExpression) != nil
            || trimmed.range(of: #"^github_pat_[A-Za-z0-9_]{20,}$"#, options: .regularExpression) != nil
            || trimmed.range(of: #"^[a-f0-9]{40}$"#, options: .regularExpression) != nil // classic pre-2021 tokens
    }

    /// The "new token" page with the right scopes and a description already filled in.
    static func tokenCreationURL() -> URL {
        let hostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        var components = URLComponents(string: "https://github.com/settings/tokens/new")!
        components.queryItems = [
            URLQueryItem(name: "scopes", value: scopes.split(separator: " ").joined(separator: ",")),
            URLQueryItem(name: "description", value: "KingProgress on \(hostname)"),
        ]
        return components.url!
    }
}
