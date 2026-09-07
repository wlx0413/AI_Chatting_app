import Foundation
import CoreText

/// Manages a user-imported serif font family (e.g. the "Newsreader SC" merged
/// font: Newsreader Latin glyphs + Songti SC CJK glyphs).
///
/// The app itself stays small: fonts are NOT bundled. Users pick `.ttf`/`.otf`
/// files in Settings → Appearance; they are copied into
/// `~/Library/Application Support/AIChatApp/Fonts`, registered with Core Text
/// (user scope), and the family name is persisted. When present, the serif
/// preset uses the imported family; otherwise it falls back to the system
/// serif (New York + Songti SC cascade).
final class ImportedFontManager: ObservableObject {

    /// Shared instance (also read by `FontPreset` helpers).
    static let shared = ImportedFontManager()

    /// Family name of the currently imported serif font, if any.
    @Published private(set) var familyName: String?

    private let defaultsKey = "appearance.importedFontFamily"
    private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc"]

    /// Directory where imported font files live (Application Support).
    private var fontsDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("AIChatApp/Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        if let stored = UserDefaults.standard.string(forKey: defaultsKey), !stored.isEmpty {
            familyName = stored
        }
    }

    // MARK: - Launch-time activation

    /// Registers every font already present in Application Support (idempotent)
    /// and re-derives the family name when needed. Called from `App.init`.
    func activateInstalled() {
        let files = installedFontURLs()
        for url in files {
            CTFontManagerRegisterFontsForURL(url as CFURL, .user, nil)
        }
        if familyName == nil, let first = files.first, let name = familyName(of: first) {
            familyName = name
            UserDefaults.standard.set(name, forKey: defaultsKey)
        }
    }

    // MARK: - Import / remove

    /// Imports the given font files (copies + registers) and returns whether at
    /// least one valid font was installed.
    @discardableResult
    func install(urls: [URL]) -> Bool {
        // Replace any previous import wholesale.
        removeImportedFont()

        let fm = FileManager.default
        var installedName: String?
        for url in urls {
            guard Self.fontExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let dest = fontsDirectory.appendingPathComponent(url.lastPathComponent)
            do {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: url, to: dest)
                CTFontManagerRegisterFontsForURL(dest as CFURL, .user, nil)
                installedName = familyName(of: dest) ?? installedName
            } catch {
                continue
            }
        }

        guard let installedName, !installedName.isEmpty else { return false }
        familyName = installedName
        UserDefaults.standard.set(installedName, forKey: defaultsKey)
        return true
    }

    /// Unregisters and deletes all imported fonts.
    func removeImportedFont() {
        for url in installedFontURLs() {
            CTFontManagerUnregisterFontsForURL(url as CFURL, .user, nil)
            try? FileManager.default.removeItem(at: url)
        }
        familyName = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    // MARK: - Helpers

    private func installedFontURLs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: fontsDirectory, includingPropertiesForKeys: nil))
            .map { $0.filter { Self.fontExtensions.contains($0.pathExtension.lowercased()) } } ?? []
    }

    /// Reads the family name directly from a font file (no registration needed).
    private func familyName(of url: URL) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first else { return nil }
        return CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String
    }
}
