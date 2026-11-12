import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Offline skin manager for iOS. The active PNG and model are read by the game's offline-skin loader.
/// The library keeps independent copies so importing a new skin never destroys an older one.
struct SkinStudioPage: View {
    @State private var model = UserDefaults.standard.string(forKey: "skin-model") ?? "classic"
    @State private var skinURL: URL? = Self.currentSkin
    @State private var preview: UIImage? = Self.currentSkin.flatMap { UIImage(contentsOfFile: $0.path) }
    @State private var entries: [SkinEntry] = []
    @State private var picking = false
    @State private var message: String?
    @State private var nameDraft = ""
    @State private var askingName = false
    @State private var onlineName = ""
    @State private var onlineSource = "Ely.by"
    @State private var downloadingOnlineSkin = false

    private static var skinDirectory: URL {
        GameFolder.documents.appendingPathComponent("skins", isDirectory: true)
    }
    private static var libraryDirectory: URL {
        skinDirectory.appendingPathComponent("library", isDirectory: true)
    }
    private static var currentSkin: URL? {
        let url = skinDirectory.appendingPathComponent("current.png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Skin Studio").font(.system(.largeTitle, design: .rounded).bold())
                Text("Import, save and switch Minecraft Java skins.")
                    .font(.subheadline).foregroundStyle(Theme.textMuted)
            }

            HStack(spacing: 16) {
                skinPreview
                VStack(alignment: .leading, spacing: 8) {
                    Text(skinURL == nil ? "No custom skin" : "Active skin").font(.headline)
                    Text(skinURL?.lastPathComponent ?? "Import a 64×64 or 64×32 PNG")
                        .font(.caption).foregroundStyle(Theme.textMuted).lineLimit(2)
                    Button { picking = true } label: {
                        Label("Import PNG", systemImage: "square.and.arrow.down")
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(16).card()

            VStack(alignment: .leading, spacing: 12) {
                Label("Online skin sources", systemImage: "globe").font(.headline)
                Text("Look up a Java skin by username. No account sign-in required.")
                    .font(.caption).foregroundStyle(Theme.textMuted)
                Picker("Online source", selection: $onlineSource) {
                    Text("Ely.by").tag("Ely.by")
                    Text("Mojang").tag("Mojang")
                }.pickerStyle(.segmented)
                HStack(spacing: 8) {
                    TextField("Minecraft Java username", text: $onlineName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button("Fetch") { Task { await importOnlineSkin() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(onlineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || downloadingOnlineSkin)
                }
                if downloadingOnlineSkin { ProgressView("Downloading skin…") }
            }.padding(16).card()

            VStack(alignment: .leading, spacing: 12) {
                Text("Arm model").font(.headline)
                Picker("Arm model", selection: $model) {
                    Text("Classic").tag("classic")
                    Text("Slim").tag("slim")
                }.pickerStyle(.segmented)
                Text(model == "slim" ? "Slim uses three-pixel-wide arms (Alex)." : "Classic uses four-pixel-wide arms (Steve).")
                    .font(.caption).foregroundStyle(Theme.textMuted)
            }.padding(16).card()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Skin library", systemImage: "square.stack").font(.headline)
                    Spacer()
                    Text("\(entries.count) saved").font(.caption).foregroundStyle(Theme.textMuted)
                }
                if entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.square").font(.system(size: 34)).foregroundStyle(Theme.textFaint)
                        Text("No saved skins").font(.subheadline.weight(.semibold))
                        Text("Import a PNG to add the first skin to your library.")
                            .font(.caption).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).frame(minHeight: 130)
                } else {
                    ForEach(entries) { entry in
                        HStack(spacing: 12) {
                            if let image = UIImage(contentsOfFile: entry.url.path) {
                                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                                    .frame(width: 54, height: 54)
                                    .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 10))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(entry.model == "slim" ? "Slim / Alex" : "Classic / Steve")
                                    .font(.caption).foregroundStyle(Theme.textMuted)
                            }
                            Spacer()
                            if UserDefaults.standard.string(forKey: "active-skin-name") == entry.name {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                                    .accessibilityLabel("Active skin")
                            } else {
                                Button("Use") { activate(entry) }.buttonStyle(.bordered)
                            }
                            Menu {
                                Button("Use skin", systemImage: "checkmark") { activate(entry) }
                                Button("Delete", systemImage: "trash", role: .destructive) { delete(entry) }
                            } label: {
                                Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(Theme.textMuted)
                            }
                        }
                        .padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }.padding(16).card()

            if let message {
                Text(message).font(.footnote).foregroundStyle(Theme.warn)
            }
        }
        .padding(20)
        .frame(maxWidth: 700, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Theme.background)
        .navigationTitle("Skins")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.png], allowsMultipleSelection: false) { result in
            importSkin(result)
        }
        .onAppear {
            loadLibrary()
            if let modelFile = try? String(contentsOf: Self.skinDirectory.appendingPathComponent("current-model.txt"), encoding: .utf8),
               modelFile == "classic" || modelFile == "slim" {
                model = modelFile
            }
        }
        .onChange(of: model) { value in
            UserDefaults.standard.set(value, forKey: "skin-model")
            try? FileManager.default.createDirectory(at: Self.skinDirectory, withIntermediateDirectories: true)
            try? value.write(to: Self.skinDirectory.appendingPathComponent("current-model.txt"), atomically: true, encoding: .utf8)
        }
    }

    @ViewBuilder private var skinPreview: some View {
        if let preview {
            Image(uiImage: preview).interpolation(.none).resizable().scaledToFit()
                .frame(width: 104, height: 104)
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel("Skin texture preview")
        } else {
            Image(systemName: "person.crop.square.filled.and.at.rectangle")
                .font(.system(size: 64)).foregroundStyle(Theme.textFaint)
                .frame(width: 104, height: 104).background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @MainActor private func importOnlineSkin() async {
        let username = onlineName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, username.count <= 16,
              username.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            message = "Enter a valid Minecraft username (up to 16 letters, numbers or underscores)."
            return
        }
        downloadingOnlineSkin = true
        defer { downloadingOnlineSkin = false }
        do {
            let result: (Data, String)
            if onlineSource == "Ely.by" {
                result = try await fetchElySkin(username: username)
            } else {
                result = try await fetchMojangSkin(username: username)
            }
            try saveOnlineSkin(result.0, name: "\(onlineSource)-\(username)", model: result.1)
            message = "\(onlineSource) skin imported and activated. Rejoin your world or server to apply it."
        } catch {
            message = "\(onlineSource) skin: \(error.localizedDescription)"
        }
    }

    private func fetchElySkin(username: String) async throws -> (Data, String) {
        let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        let metadataURL = URL(string: "https://skinsystem.ely.by/textures/\(encoded)")!
        var request = URLRequest(url: metadataURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (metadataData, metadataResponse) = try await URLSession.shared.data(for: request)
        guard (metadataResponse as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
              let skin = json["SKIN"] as? [String: Any],
              let rawURL = skin["url"] as? String, let imageURL = URL(string: rawURL), imageURL.scheme == "https"
        else { throw AccountError("Ely.by has no skin for that username.") }
        let (data, response) = try await URLSession.shared.data(from: imageURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AccountError("Ely.by skin image could not be downloaded.")
        }
        let model = ((skin["metadata"] as? [String: Any])?["model"] as? String)?.lowercased() == "slim" ? "slim" : "classic"
        return (data, model)
    }

    private func fetchMojangSkin(username: String) async throws -> (Data, String) {
        let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        let profileURL = URL(string: "https://api.mojang.com/users/profiles/minecraft/\(encoded)")!
        let (profileData, profileResponse) = try await URLSession.shared.data(from: profileURL)
        guard (profileResponse as? HTTPURLResponse)?.statusCode == 200,
              let profile = try JSONSerialization.jsonObject(with: profileData) as? [String: Any],
              let uuid = profile["id"] as? String, !uuid.isEmpty else {
            throw AccountError("Mojang could not find that Java username.")
        }

        let sessionURL = URL(string: "https://sessionserver.mojang.com/session/minecraft/profile/\(uuid)")!
        let (sessionData, sessionResponse) = try await URLSession.shared.data(from: sessionURL)
        guard (sessionResponse as? HTTPURLResponse)?.statusCode == 200,
              let session = try JSONSerialization.jsonObject(with: sessionData) as? [String: Any],
              let properties = session["properties"] as? [[String: Any]],
              let texturesProperty = properties.first(where: { ($0["name"] as? String) == "textures" }),
              let encodedTextures = texturesProperty["value"] as? String,
              let decodedTextures = Data(base64Encoded: encodedTextures),
              let textures = try JSONSerialization.jsonObject(with: decodedTextures) as? [String: Any],
              let textureMap = textures["textures"] as? [String: Any],
              let skin = textureMap["SKIN"] as? [String: Any],
              let rawURL = skin["url"] as? String,
              var components = URLComponents(string: rawURL) else {
            throw AccountError("Mojang profile has no public skin.")
        }
        // Mojang texture metadata may return HTTP; require HTTPS for the download.
        components.scheme = "https"
        guard let imageURL = components.url, imageURL.host == "textures.minecraft.net" else {
            throw AccountError("Mojang returned an unsupported skin URL.")
        }
        let (data, imageResponse) = try await URLSession.shared.data(from: imageURL)
        guard (imageResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw AccountError("Mojang skin image could not be downloaded.")
        }
        let model = ((skin["metadata"] as? [String: Any])?["model"] as? String)?.lowercased() == "slim" ? "slim" : "classic"
        return (data, model)
    }

    private func saveOnlineSkin(_ data: Data, name: String, model: String) throws {
        guard let image = UIImage(data: data), let cg = image.cgImage,
              cg.width == 64 && (cg.height == 64 || cg.height == 32) else {
            throw AccountError("Downloaded image is not a supported 64×64 or 64×32 Minecraft skin.")
        }
        try FileManager.default.createDirectory(at: Self.libraryDirectory, withIntermediateDirectories: true)
        let destination = Self.uniqueURL(named: Self.safeFilename(name))
        try data.write(to: destination, options: .atomic)
        try model.write(to: Self.modelURL(for: destination), atomically: true, encoding: .utf8)
        let entry = SkinEntry(url: destination, name: destination.deletingPathExtension().lastPathComponent, model: model)
        activate(entry)
        loadLibrary()
    }

    private func importSkin(_ result: Result<[URL], Error>) {
        do {
            guard let source = try result.get().first else { return }
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: source)
            guard let image = UIImage(data: data), let cg = image.cgImage,
                  cg.width == 64 && (cg.height == 64 || cg.height == 32) else {
                message = "Skin PNG must be exactly 64×64 or 64×32 pixels."
                return
            }
            try FileManager.default.createDirectory(at: Self.libraryDirectory, withIntermediateDirectories: true)
            let base = source.deletingPathExtension().lastPathComponent
            let safeName = Self.safeFilename(base.isEmpty ? "Skin" : base)
            let destination = Self.uniqueURL(named: safeName)
            try data.write(to: destination, options: .atomic)
            let selectedModel = model
            try selectedModel.write(to: Self.modelURL(for: destination), atomically: true, encoding: .utf8)
            let entry = SkinEntry(url: destination, name: destination.deletingPathExtension().lastPathComponent, model: selectedModel)
            activate(entry)
            loadLibrary()
            message = "Skin added to your library and activated. It applies when you next join a world or server."
        } catch {
            message = "Could not import skin: \(error.localizedDescription)"
        }
    }

    private func activate(_ entry: SkinEntry) {
        do {
            try FileManager.default.createDirectory(at: Self.skinDirectory, withIntermediateDirectories: true)
            let data = try Data(contentsOf: entry.url)
            try data.write(to: Self.skinDirectory.appendingPathComponent("current.png"), options: .atomic)
            UserDefaults.standard.set(entry.name, forKey: "active-skin-name")
            try entry.model.write(to: Self.skinDirectory.appendingPathComponent("current-model.txt"), atomically: true, encoding: .utf8)
            model = entry.model
            skinURL = Self.currentSkin
            preview = UIImage(data: data)
            message = "\(entry.name) is now active. Rejoin the world or server to apply it."
        } catch {
            message = "Could not activate skin: \(error.localizedDescription)"
        }
    }

    private func delete(_ entry: SkinEntry) {
        let isActive = UserDefaults.standard.string(forKey: "active-skin-name") == entry.name
        do {
            try FileManager.default.removeItem(at: entry.url)
            try? FileManager.default.removeItem(at: Self.modelURL(for: entry.url))
            if isActive {
                UserDefaults.standard.removeObject(forKey: "active-skin-name")
                try? FileManager.default.removeItem(at: Self.skinDirectory.appendingPathComponent("current.png"))
                skinURL = nil
                preview = nil
            }
            loadLibrary()
            message = isActive ? "Active skin removed." : "Skin deleted from library."
        } catch {
            message = "Could not delete skin: \(error.localizedDescription)"
        }
    }

    private func loadLibrary() {
        try? FileManager.default.createDirectory(at: Self.libraryDirectory, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.libraryDirectory,
                        includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        entries = files.filter { $0.pathExtension.lowercased() == "png" }.compactMap { url in
            guard let image = UIImage(contentsOfFile: url.path), let cg = image.cgImage,
                  cg.width == 64 && (cg.height == 64 || cg.height == 32) else { return nil }
            let savedModel = (try? String(contentsOf: Self.modelURL(for: url), encoding: .utf8)) ?? "classic"
            return SkinEntry(url: url, name: url.deletingPathExtension().lastPathComponent,
                             model: savedModel == "slim" ? "slim" : "classic")
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func modelURL(for skin: URL) -> URL {
        skin.deletingPathExtension().appendingPathExtension("model")
    }

    private static func safeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "Skin" : cleaned).prefix(48))
    }

    private static func uniqueURL(named name: String) -> URL {
        var candidate = libraryDirectory.appendingPathComponent(name).appendingPathExtension("png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = libraryDirectory.appendingPathComponent("\(name)-\(suffix)").appendingPathExtension("png")
            suffix += 1
        }
        return candidate
    }
}

private struct SkinEntry: Identifiable {
    let url: URL
    let name: String
    let model: String
    var id: String { url.path }
}
