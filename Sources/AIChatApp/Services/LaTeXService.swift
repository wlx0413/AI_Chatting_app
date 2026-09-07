import Foundation
import CoreGraphics

/// Detects a local LaTeX toolchain and compiles `.tex` sources to PDF.
///
/// The app is not sandboxed, so it can spawn the TeX binaries directly.
/// Gating is two-layered: the user must opt in per profile
/// (`APIServerConfig.latexEnabled`) **and** a toolchain must exist — otherwise
/// the `compile_latex` tool is not registered at all, so the model never sees a
/// capability that cannot be honoured.
///
/// Safety boundary: everything is written inside `~/Documents/AIChatApp/LaTeX/`.
/// The model supplies the document body and a filename stem only, never a path,
/// so it cannot write outside that directory.
enum LaTeXService {

    // MARK: - Environment detection

    /// Directories MacTeX / TeX Live / Homebrew install engines into.
    private static let searchPaths = [
        "/Library/TeX/texbin",
        "/usr/local/texlive/2025/bin/universal-darwin",
        "/usr/local/texlive/2024/bin/universal-darwin",
        "/usr/local/texlive/2023/bin/universal-darwin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    ]

    /// Engines we accept, in preference order. XeLaTeX first: it handles CJK and
    /// system fonts out of the box, which matters for Chinese documents.
    private static let engineNames = ["xelatex", "pdflatex", "lualatex"]

    /// Resolved engine executables (empty when no toolchain is installed).
    ///
    /// Computed once per launch — installing TeX mid-session is rare, and this
    /// keeps tool-list construction cheap.
    static let availableEngines: [String: URL] = {
        var found: [String: URL] = [:]
        let fm = FileManager.default
        for engine in engineNames {
            for dir in searchPaths {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent(engine)
                if fm.isExecutableFile(atPath: candidate.path) {
                    found[engine] = candidate
                    break
                }
            }
        }
        return found
    }()

    /// `true` when at least one engine is installed.
    static var isAvailable: Bool { !availableEngines.isEmpty }

    /// The engine used when the model does not ask for a specific one.
    static var defaultEngine: String? {
        engineNames.first { availableEngines[$0] != nil }
    }

    /// Human-readable list for the tool description / settings UI.
    static var installedEngineList: String {
        engineNames.filter { availableEngines[$0] != nil }.joined(separator: ", ")
    }

    // MARK: - Output location

    /// `~/Documents/AIChatApp/LaTeX` — created on demand.
    static func outputDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = documents
            .appendingPathComponent("AIChatApp", isDirectory: true)
            .appendingPathComponent("LaTeX", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Compilation

    /// Result of one compile attempt.
    struct CompileResult {
        /// The written `.tex` source.
        let sourceURL: URL

        /// The produced PDF (nil when compilation failed).
        let pdfURL: URL?

        /// Page count when the PDF could be inspected.
        let pageCount: Int?

        /// Engine log, already trimmed to the interesting part.
        let log: String

        /// Whether a PDF was produced.
        var succeeded: Bool { pdfURL != nil }
    }

    /// Writes `source` and compiles it, returning both paths.
    ///
    /// - Parameters:
    ///   - source: Full LaTeX document (must include a documentclass).
    ///   - filenameStem: Base name without extension; sanitized.
    ///   - engine: `xelatex` / `pdflatex` / `lualatex`; falls back to the default.
    static func compile(
        source: String,
        filenameStem: String,
        engine requestedEngine: String? = nil
    ) throws -> CompileResult {
        guard let engineName = requestedEngine.flatMap({ availableEngines[$0] != nil ? $0 : nil })
                ?? defaultEngine,
              let executable = availableEngines[engineName] else {
            throw LaTeXError.noToolchain
        }

        let stem = sanitizedStem(filenameStem)
        // Each job gets its own directory so aux files never collide and the
        // user finds "the PDF plus its source" together.
        let jobDir = try outputDirectory()
            .appendingPathComponent("\(stem)-\(timestamp())", isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)

        let texURL = jobDir.appendingPathComponent("\(stem).tex")
        try source.write(to: texURL, atomically: true, encoding: .utf8)

        // Two passes so \ref / \cite / ToC resolve — but only when the document
        // actually cross-references anything, and only if pass 1 produced a PDF.
        var log = try runEngine(executable, stem: stem, in: jobDir)
        let pdfURL = jobDir.appendingPathComponent("\(stem).pdf")
        var pdfExists = FileManager.default.fileExists(atPath: pdfURL.path)

        if pdfExists && sourceNeedsSecondPass(source) {
            log = try runEngine(executable, stem: stem, in: jobDir)
            pdfExists = FileManager.default.fileExists(atPath: pdfURL.path)
        }

        return CompileResult(
            sourceURL: texURL,
            pdfURL: pdfExists ? pdfURL : nil,
            pageCount: pdfExists ? pdfPageCount(pdfURL) : nil,
            log: condensedLog(log, succeeded: pdfExists)
        )
    }

    // MARK: - Process plumbing

    /// Runs one engine pass in `directory` and returns its combined output.
    private static func runEngine(
        _ executable: URL,
        stem: String,
        in directory: URL
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.arguments = [
            // Never stop for input — a missing package would otherwise hang the
            // app forever waiting on stdin.
            "-interaction=nonstopmode",
            "-halt-on-error",
            "-file-line-error",
            "\(stem).tex",
        ]
        // TeX needs its own bin dir on PATH to find kpsewhich et al.
        var environment = ProcessInfo.processInfo.environment
        let binDir = executable.deletingLastPathComponent().path
        environment["PATH"] = "\(binDir):\(environment["PATH"] ?? "/usr/bin:/bin")"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        // Read before waiting: a full pipe buffer would deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Result parsing (for the UI card)

    /// Extracts produced files from a tool result so the chat can render a
    /// clickable card, reusing the same `ChatSource` plumbing as web sources.
    ///
    /// The tool result carries a machine-readable `ARTIFACT: file://…` line
    /// precisely so this parser never has to guess.
    static func parseArtifacts(from result: String) -> [ChatSource] {
        var sources: [ChatSource] = []
        for line in result.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("ARTIFACT:") else { continue }
            let raw = String(trimmed.dropFirst("ARTIFACT:".count))
                .trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: raw), url.isFileURL else { continue }
            sources.append(ChatSource(
                title: url.lastPathComponent,
                url: url.absoluteString
            ))
        }
        return sources
    }

    // MARK: - Helpers

    /// Only run a second pass when the document actually has cross-references.
    private static func sourceNeedsSecondPass(_ source: String) -> Bool {
        for marker in ["\\ref", "\\cite", "\\tableofcontents", "\\pageref"] {
            if source.contains(marker) { return true }
        }
        return false
    }

    /// Keeps the model's context small: on success just the tail, on failure the
    /// `file:line:error` lines that actually explain the problem.
    private static func condensedLog(_ log: String, succeeded: Bool) -> String {
        let lines = log.components(separatedBy: .newlines)
        if succeeded {
            return lines.suffix(5).joined(separator: "\n")
        }
        let errors = lines.filter {
            $0.contains(".tex:") || $0.hasPrefix("!") || $0.lowercased().contains("emergency stop")
        }
        let selected = errors.isEmpty ? Array(lines.suffix(25)) : Array(errors.prefix(25))
        return selected.joined(separator: "\n")
    }

    /// Reads the page count straight from the PDF (no PDFKit import needed).
    private static func pdfPageCount(_ url: URL) -> Int? {
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        return document.numberOfPages
    }

    /// Strips path separators and exotic characters from a model-supplied name,
    /// so the tool can never escape the output directory.
    private static func sanitizedStem(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return trimmed.isEmpty ? "document" : String(trimmed.prefix(48))
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Errors surfaced to the model as plain text.
    enum LaTeXError: LocalizedError {
        case noToolchain

        var errorDescription: String? {
            switch self {
            case .noToolchain:
                return "No LaTeX engine found on this machine."
            }
        }
    }
}

