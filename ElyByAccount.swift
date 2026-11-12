import SwiftUI

/// An Ely.by account (authserver.ely.by, Yggdrasil): sign in with a username or email and a password, plus the
/// two-factor code when the account has one. The password is never kept. The access and client tokens live in the
/// Keychain, and the game gets only the access token, as `user_type: "elyby"`, so it joins servers through Ely.by's
/// session server (crates/horizon-client-render/src/auth.rs). Only one of Microsoft and Ely.by is active at a time:
/// HomeView keeps them apart (choosing a Microsoft account signs Ely.by out).
@MainActor
final class ElyByAccount: ObservableObject {
    struct Profile: Codable, Equatable {
        let name: String
        let uuid: String
    }
    enum State: Equatable {
        case idle, working, needsCode, failed(String)
    }
    @Published private(set) var profile: Profile?
    @Published private(set) var state = State.idle
    private let defaults: UserDefaults
    private let vault: AccountVault
    private let session: URLSession
    private let bridge: (String) async -> [String: Any]
    private var signing: Task<Void, Never>?
    private var renewal: Task<String, Error>?
    nonisolated static let base = "https://authserver.ely.by"
    private static let vaultKey = "elyby"
    private static let profileKey = "elybyProfile.v1"

    init(defaults: UserDefaults = .standard, vault: AccountVault = KeychainAccountVault(),
         session: URLSession = .shared,
         bridge: @escaping (String) async -> [String: Any] = { await Bridge.send($0) }) {
        self.defaults = defaults; self.vault = vault; self.session = session; self.bridge = bridge
        if let data = defaults.data(forKey: Self.profileKey),
           let saved = try? JSONDecoder().decode(Profile.self, from: data) {
            profile = saved
        }
    }

    // MARK: Signing in and out

    /// `code` is the two-factor code, empty on the first try. Ely.by wants it appended to the password after a colon.
    func signIn(username: String, password: String, code: String = "") {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !password.isEmpty else {
            state = .failed("Enter your Ely.by username or email and your password."); return
        }
        signing?.cancel()
        state = .working
        signing = Task {
            defer { signing = nil }
            do {
                let clientToken = (try? vault.read(Self.vaultKey))?.refresh ?? UUID().uuidString
                let sent = code.isEmpty ? password : password + ":" + code
                let (status, answer) = try await post("/auth/authenticate", [
                    "username": user, "password": sent, "clientToken": clientToken, "requestUser": false,
                ])
                try Task.checkCancellation()
                if status == 401 || status == 400 || status == 403 {
                    let message = (answer["errorMessage"] as? String ?? "").lowercased()
                    if code.isEmpty, message.contains("two factor") { state = .needsCode; return }
                    throw AccountError(code.isEmpty ? "Wrong username or password."
                                                    : "Wrong password or code. Check the code and try again.")
                }
                guard status == 200,
                      let token = answer["accessToken"] as? String, !token.isEmpty,
                      let chosen = answer["selectedProfile"] as? [String: Any],
                      let id = chosen["id"] as? String, let name = chosen["name"] as? String,
                      let uuid = Self.uuid(id), !name.isEmpty
                else { throw AccountError("Ely.by returned an incomplete answer. Try again.") }
                let returned = answer["clientToken"] as? String ?? clientToken
                try vault.write(AccountSecrets(refresh: returned, token: token, expires: .distantFuture),
                                for: Self.vaultKey)
                let saved = Profile(name: name, uuid: uuid)
                defaults.set(try JSONEncoder().encode(saved), forKey: Self.profileKey)
                profile = saved; state = .idle; Haptics.done()
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription); Haptics.failed()
            }
        }
    }

    func cancel() { signing?.cancel(); signing = nil; state = .idle }

    /// Forget the account on this device and tell Ely.by to drop the token (best effort).
    func signOut() {
        cancel()
        let secrets = try? vault.read(Self.vaultKey)
        try? vault.remove(Self.vaultKey)
        defaults.removeObject(forKey: Self.profileKey)
        profile = nil
        if let secrets {
            Task { _ = try? await post("/auth/invalidate", ["accessToken": secrets.token, "clientToken": secrets.refresh]) }
        }
    }

    // MARK: Handing the account to the game

    /// Validate the saved token, renew it if Ely.by no longer accepts it, then give the game the session.
    func handOver() async throws {
        guard let account = profile else { return }
        let token = try await currentToken()
        let data = try JSONSerialization.data(withJSONObject: [
            "name": account.name, "uuid": account.uuid, "access_token": token, "user_type": "elyby",
        ])
        let answer = await bridge("launcher-session " + String(decoding: data, as: UTF8.self))
        guard answer["ok"] as? Bool == true, answer["error"] == nil else {
            throw AccountError("The game could not accept your Ely.by account. Try Play again.")
        }
    }

    private func currentToken() async throws -> String {
        if let renewal { return try await renewal.value }
        guard let secrets = try vault.read(Self.vaultKey) else {
            throw AccountError("Sign in again to use your Ely.by account.", reauthenticate: true)
        }
        let task = Task { @MainActor () -> String in
            let (status, _) = try await self.post("/auth/validate", ["accessToken": secrets.token])
            if status == 200 { return secrets.token }
            let (code, answer) = try await self.post("/auth/refresh", [
                "accessToken": secrets.token, "clientToken": secrets.refresh, "requestUser": false,
            ])
            if code == 200, let fresh = answer["accessToken"] as? String, !fresh.isEmpty {
                try self.vault.write(AccountSecrets(refresh: answer["clientToken"] as? String ?? secrets.refresh,
                                                     token: fresh, expires: .distantFuture), for: Self.vaultKey)
                return fresh
            }
            if code == 400 || code == 401 || code == 403 {
                throw AccountError("Your Ely.by session expired. Sign in again.", reauthenticate: true)
            }
            throw AccountError("Ely.by could not renew the session. Check your connection and try again.")
        }
        renewal = task
        defer { renewal = nil }
        return try await task.value
    }

    // MARK: Network

    /// POST JSON and return the status and the JSON object, if any: `validate` and `invalidate` answer with an
    /// empty body, which is a success. Nothing the service says is logged.
    private func post(_ path: String, _ body: [String: Any]) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: Self.base + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try Task.checkCancellation()
        let result: (Data, URLResponse)
        do { result = try await session.data(for: request) }
        catch {
            try Task.checkCancellation()
            throw AccountError("Could not reach Ely.by. Check your connection and try again.")
        }
        try Task.checkCancellation()
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any] ?? [:]
        if status >= 500 { throw AccountError("Ely.by is unavailable (\(status)). Try again later.") }
        return (status, object)
    }

    /// A 32-digit hex UUID, with or without dashes, lowercased without them.
    private static func uuid(_ text: String) -> String? {
        let plain = text.replacingOccurrences(of: "-", with: "").lowercased()
        return plain.count == 32 && plain.allSatisfy({ $0.isHexDigit }) ? plain : nil
    }
}

// MARK: - The card

/// The Ely.by account on the account sheet: who is signed in, or the way to sign in.
struct ElyByCard: View {
    @ObservedObject var account: ElyByAccount
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key.fill").foregroundStyle(Theme.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ELY.BY ACCOUNT").font(Theme.mono(8)).foregroundStyle(Theme.textMuted)
                    Text(account.profile?.name ?? "Not signed in").font(Theme.sans(15, .semiBold))
                        .foregroundStyle(Theme.text)
                }
                Spacer()
                if account.profile != nil {
                    Button("Sign out") { account.signOut() }
                        .font(Theme.sans(12, .semiBold)).foregroundStyle(Theme.textMuted)
                        .frame(minHeight: 44)
                }
            }
            if account.profile == nil {
                TextField("Username or email", text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textContentType(.username).keyboardType(.emailAddress)
                    .disabled(account.state == .working)
                    .accessibilityIdentifier("elyby-username")
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .disabled(account.state == .working)
                    .accessibilityIdentifier("elyby-password")
                if account.state == .needsCode {
                    Text("This account uses two-factor authentication. Enter the code from your app.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Two-factor code", text: $code)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        .accessibilityIdentifier("elyby-code")
                }
                switch account.state {
                case .working:
                    HStack(spacing: 8) {
                        ProgressView().tint(Theme.accentText)
                        Text("Signing in to Ely.by…").font(Theme.sans(12)).foregroundStyle(Theme.textMuted)
                    }
                    SecondaryButton(title: "Cancel") { account.cancel() }
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.sans(12)).foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                    signInButton
                default:
                    signInButton
                }
                Text("For servers that use Ely.by accounts. Microsoft servers need a Microsoft account.")
                    .font(Theme.sans(11)).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(14)
        .card()
        .onChange(of: account.profile) { profile in
            if profile != nil { username = ""; password = ""; code = "" }
        }
    }

    private var signInButton: some View {
        SecondaryButton(title: account.state == .needsCode ? "Sign in with code" : "Sign in with Ely.by",
                        icon: "key.fill") {
            account.signIn(username: username, password: password, code: code)
        }
    }
}
