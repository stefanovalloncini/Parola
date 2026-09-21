import Foundation

/// What to do when the vault already holds a note with the name this delivery picked.
public enum ObsidianCollisionPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    case appendCounter
    case overwrite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appendCounter: return "Keep both"
        case .overwrite: return "Replace"
        }
    }
}

/// Writes a Markdown note into a folder of an Obsidian vault the user picked. Obsidian itself is
/// never launched: the vault is a folder, and a note in it shows up the next time Obsidian scans.
public struct ObsidianVaultFolderDestination: DeliveryDestination, Codable, Sendable, Equatable {
    public static let kind = DestinationKind.obsidianFolder

    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var autoSend: Bool
    public var categories: Set<EntryCategory>
    public var titleFormat: TitleFormat
    /// Security-scoped bookmark for the vault folder, made when the user picked it.
    public var vaultBookmark: Data
    /// The path the picker showed, for the settings row and for error messages.
    public var vaultPath: String
    public var subfolder: String
    public var filenameTemplate: String
    public var collision: ObsidianCollisionPolicy
    public var frontmatter: ObsidianFrontmatterOptions
    public var body: ObsidianBodyOptions
    public var wikilinks: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        autoSend: Bool = false,
        categories: Set<EntryCategory> = Set(EntryCategory.allCases),
        titleFormat: TitleFormat = .title,
        vaultBookmark: Data,
        vaultPath: String,
        subfolder: String = "",
        filenameTemplate: String = ObsidianVaultFolderDestination.defaultFilenameTemplate,
        collision: ObsidianCollisionPolicy = .appendCounter,
        frontmatter: ObsidianFrontmatterOptions = ObsidianFrontmatterOptions(),
        body: ObsidianBodyOptions = ObsidianBodyOptions(),
        wikilinks: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.autoSend = autoSend
        self.categories = categories
        self.titleFormat = titleFormat
        self.vaultBookmark = vaultBookmark
        self.vaultPath = vaultPath
        self.subfolder = subfolder
        self.filenameTemplate = filenameTemplate
        self.collision = collision
        self.frontmatter = frontmatter
        self.body = body
        self.wikilinks = wikilinks
    }

    public static let defaultFilenameTemplate = "{title}"

    public var noteOptions: ObsidianNoteOptions {
        ObsidianNoteOptions(frontmatter: frontmatter, body: body, wikilinks: wikilinks)
    }

    /// What the vault row shows: the folder's name, or the destination's own when the path is gone.
    public var vaultDisplayName: String {
        let last = (vaultPath as NSString).lastPathComponent
        return last.isEmpty ? name : last
    }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, autoSend, categories, titleFormat
        case vaultBookmark, vaultPath, subfolder, filenameTemplate, collision
        case frontmatter, body, wikilinks
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        autoSend = try c.decodeIfPresent(Bool.self, forKey: .autoSend) ?? false
        let rawCategories = try c.decodeIfPresent([String].self, forKey: .categories)
        categories = rawCategories.map { Set($0.compactMap(EntryCategory.init(rawValue:))) }
            ?? Set(EntryCategory.allCases)
        titleFormat = try c.decodeIfPresent(TitleFormat.self, forKey: .titleFormat) ?? .title
        vaultBookmark = try c.decodeIfPresent(Data.self, forKey: .vaultBookmark) ?? Data()
        vaultPath = try c.decodeIfPresent(String.self, forKey: .vaultPath) ?? ""
        subfolder = try c.decodeIfPresent(String.self, forKey: .subfolder) ?? ""
        filenameTemplate = try c.decodeIfPresent(String.self, forKey: .filenameTemplate)
            ?? Self.defaultFilenameTemplate
        collision = try c.decodeIfPresent(ObsidianCollisionPolicy.self, forKey: .collision) ?? .appendCounter
        frontmatter = try c.decodeIfPresent(ObsidianFrontmatterOptions.self, forKey: .frontmatter)
            ?? ObsidianFrontmatterOptions()
        body = try c.decodeIfPresent(ObsidianBodyOptions.self, forKey: .body) ?? ObsidianBodyOptions()
        wikilinks = try c.decodeIfPresent(Bool.self, forKey: .wikilinks) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(autoSend, forKey: .autoSend)
        // Sorted, so the stored config does not churn with the set's iteration order.
        try c.encode(categories.map(\.rawValue).sorted(), forKey: .categories)
        try c.encode(titleFormat, forKey: .titleFormat)
        try c.encode(vaultBookmark, forKey: .vaultBookmark)
        try c.encode(vaultPath, forKey: .vaultPath)
        try c.encode(subfolder, forKey: .subfolder)
        try c.encode(filenameTemplate, forKey: .filenameTemplate)
        try c.encode(collision, forKey: .collision)
        try c.encode(frontmatter, forKey: .frontmatter)
        try c.encode(body, forKey: .body)
        try c.encode(wikilinks, forKey: .wikilinks)
    }

    // MARK: - Delivery

    public func deliver(_ payload: DeliveryPayload) async throws -> DeliveryReceipt {
        let vault = try resolvedVaultURL()
        let scoped = vault.startAccessingSecurityScopedResource()
        defer { if scoped { vault.stopAccessingSecurityScopedResource() } }
        // A vault on a drive that is not mounted must not be recreated as an empty folder.
        guard FileManager.default.fileExists(atPath: vault.path) else {
            throw DeliveryError.vaultUnavailable(name, vault.path)
        }

        let directory = Self.folder(in: vault, subfolder: subfolder)
        let base = ObsidianNoteRenderer.filename(template: filenameTemplate, payload: payload)
        let note = ObsidianNoteRenderer.render(
            payload, options: noteOptions, title: titleFormat.title(for: payload)
        )

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = Self.target(in: directory, base: base, collision: collision)
            try Data(note.utf8).write(to: target, options: .atomic)
            return DeliveryReceipt(
                destinationID: id,
                destinationName: name,
                deliveredAt: Date(),
                location: target
            )
        } catch {
            throw DeliveryError.writeFailed(directory.path, error.localizedDescription)
        }
    }

    /// The vault folder the bookmark points at. A bookmark made without the security scope (a
    /// process that cannot mint one) still resolves, so this tries both. Through `NSURL`, whose
    /// stale flag is optional: a stale bookmark still resolves, and this type cannot re-mint one.
    func resolvedVaultURL() throws -> URL {
        guard !vaultBookmark.isEmpty else { throw DeliveryError.vaultUnavailable(name, vaultPath) }
        if let url = try? NSURL(
            resolvingBookmarkData: vaultBookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: nil
        ) as URL {
            return url
        }
        if let url = try? NSURL(
            resolvingBookmarkData: vaultBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: nil
        ) as URL {
            return url
        }
        throw DeliveryError.vaultUnavailable(name, vaultPath)
    }

    /// A bookmark for a folder the user picked. Security-scoped where the process can mint one,
    /// plain where it cannot — the app is not sandboxed, so a plain bookmark still resolves.
    public static func bookmark(for url: URL) throws -> Data {
        if let scoped = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            return scoped
        }
        return try url.bookmarkData(includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The URL that opens a written note in Obsidian.
    public static func openInObsidianURL(for location: URL) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?&#")
        guard let path = location.path.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "obsidian://open?path=\(path)")
    }

    /// The folder a note is written into. A subfolder is always relative to the vault: an absolute
    /// path or a `..` step would write outside the folder the user picked.
    static func folder(in vault: URL, subfolder: String) -> URL {
        var url = vault
        for raw in subfolder.split(separator: "/", omittingEmptySubsequences: true) {
            guard let component = ObsidianNoteRenderer.sanitisedPathComponent(String(raw)) else { continue }
            url.appendPathComponent(component, isDirectory: true)
        }
        return url
    }

    static func target(
        in directory: URL,
        base: String,
        collision: ObsidianCollisionPolicy,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let first = directory.appendingPathComponent("\(base).md")
        guard collision == .appendCounter, exists(first) else { return first }
        var counter = 2
        while counter < 1000 {
            let candidate = directory.appendingPathComponent("\(base) \(counter).md")
            if !exists(candidate) { return candidate }
            counter += 1
        }
        return directory.appendingPathComponent("\(base) \(UUID().uuidString).md")
    }
}
