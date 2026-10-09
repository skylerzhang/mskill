import Foundation
import CryptoKit

struct AgentDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let appNames: [String]
    let relativeRoots: [String]

    var executableNames: [String] {
        switch id {
        case "codex": ["codex"]
        case "claude": ["claude"]
        case "gemini": ["gemini"]
        case "opencode": ["opencode"]
        case "copilot": ["copilot"]
        default: []
        }
    }

    static let known: [AgentDefinition] = [
        .init(id: "codex", name: "Codex", symbol: "chevron.left.forwardslash.chevron.right", appNames: ["Codex.app", "ChatGPT.app"], relativeRoots: [".codex/skills"]),
        .init(id: "claude", name: "Claude Code", symbol: "sparkle", appNames: ["Claude.app"], relativeRoots: [".claude/skills"]),
        .init(id: "cursor", name: "Cursor", symbol: "cursorarrow.rays", appNames: ["Cursor.app"], relativeRoots: [".cursor/skills"]),
        .init(id: "gemini", name: "Gemini CLI", symbol: "diamond", appNames: [], relativeRoots: [".gemini/skills"]),
        .init(id: "opencode", name: "OpenCode", symbol: "terminal", appNames: ["OpenCode.app"], relativeRoots: [".config/opencode/skills"]),
        .init(id: "windsurf", name: "Windsurf", symbol: "wind", appNames: ["Windsurf.app"], relativeRoots: [".codeium/windsurf/skills"]),
        .init(id: "copilot", name: "GitHub Copilot", symbol: "person.crop.square", appNames: [], relativeRoots: [".copilot/skills"]),
        .init(id: "agents", name: "通用 Agents", symbol: "square.stack.3d.up", appNames: [], relativeRoots: [".agents/skills"])
    ]
}

struct CustomAgent: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var path: String

    init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

struct Agent: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let roots: [URL]
    let installed: Bool
    let isCustom: Bool
    var applicationURL: URL? = nil

    var primaryRoot: URL? { roots.first }
}

struct Skill: Identifiable, Hashable, Sendable {
    let id: String
    let agentID: String
    let folderName: String
    let name: String
    let summary: String
    let directory: URL
    let fingerprint: String
    var linkTarget: URL? = nil
}

struct BrokenLink: Identifiable, Hashable, Sendable {
    let agentID: String
    let location: URL
    let destination: String

    var id: String { "\(agentID):\(location.path)" }
}

struct ScanResult: Sendable {
    let agents: [Agent]
    let skills: [Skill]
    var brokenLinks: [BrokenLink] = []
}

enum SyncMode: String, CaseIterable, Sendable {
    case copy
    case link
}

enum SyncState: Equatable {
    case unavailable
    case missing
    case identical
    case linked
    case brokenLink
    case conflict
}

extension URL {
    /// 解析所有软链接后的真实路径；与 resolvingSymlinksInPath 不同，不会去掉 /private 前缀。
    var realFileURL: URL {
        guard let resolved = realpath(path, nil) else { return standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}

private enum LinkStatus: Equatable {
    case none
    case dangling
    case resolved(URL)

    init(at url: URL, fileManager: FileManager) {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil else { self = .none; return }
        self = fileManager.fileExists(atPath: url.path) ? .resolved(url.realFileURL) : .dangling
    }
}

struct SyncResult {
    let destination: URL
    let backup: URL?
}

enum SkillError: LocalizedError {
    case invalidSource
    case unavailableTarget
    case conflict
    case sameLocation
    case notBrokenLink

    var errorDescription: String? {
        switch self {
        case .invalidSource: "源 Skill 缺少 SKILL.md 或已被删除。"
        case .unavailableTarget: "目标 Agent 没有可用的 Skill 目录。"
        case .conflict: "目标已有不同内容的同名 Skill。"
        case .sameLocation: "源目录与目标目录相同。"
        case .notBrokenLink: "该路径不是失效的软链接，未做任何改动。"
        }
    }
}

struct SkillScanner {
    let home: URL
    let applications: URL
    let definitions: [AgentDefinition]
    let customAgents: [CustomAgent]
    var fileManager: FileManager = .default

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         applications: URL = URL(fileURLWithPath: "/Applications"),
         definitions: [AgentDefinition] = AgentDefinition.known,
         customAgents: [CustomAgent] = []) {
        self.home = home
        self.applications = applications
        self.definitions = definitions
        self.customAgents = customAgents
    }

    func scan() -> ScanResult {
        var agents: [Agent] = []
        let localApplications = applicationURLs()
        for definition in definitions {
            let roots = definition.relativeRoots.map { home.appending(path: $0, directoryHint: .isDirectory) }
            let hasRoot = roots.contains { fileManager.fileExists(atPath: $0.path) }
            let applicationURL = applicationURL(named: definition.appNames, in: localApplications)
            let executableDirectories = [home.appending(path: ".local/bin"), home.appending(path: ".bun/bin"),
                                         URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
            let hasExecutable = definition.executableNames.contains { name in
                executableDirectories.contains { fileManager.isExecutableFile(atPath: $0.appending(path: name).path) }
            }
            agents.append(.init(id: definition.id, name: definition.name, symbol: definition.symbol,
                                roots: roots, installed: hasRoot || applicationURL != nil || hasExecutable,
                                isCustom: false, applicationURL: applicationURL))
        }
        for custom in customAgents {
            let root = URL(fileURLWithPath: (custom.path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            agents.append(.init(id: custom.id.uuidString, name: custom.name, symbol: "folder",
                                roots: [root], installed: fileManager.fileExists(atPath: root.path), isCustom: true,
                                applicationURL: applicationURL(named: [custom.name + ".app"], in: localApplications)))
        }
        let knownRoots = Set(agents.flatMap(\.roots).flatMap { [$0.standardizedFileURL.path, $0.realFileURL.path] })
        agents.append(contentsOf: discoverOtherAgents(excluding: knownRoots).map { agent in
            var agent = agent
            agent.applicationURL = applicationURL(named: [agent.name + ".app"], in: localApplications)
            return agent
        })
        let scanned = agents.flatMap { agent in agent.roots.map { scanRoot($0, agentID: agent.id) } }
        let skills = scanned.flatMap(\.skills)
        return ScanResult(agents: agents,
                          skills: skills.sorted { ($0.name.localizedLowercase, $0.agentID) < ($1.name.localizedLowercase, $1.agentID) },
                          brokenLinks: scanned.flatMap(\.brokenLinks).sorted { $0.location.path < $1.location.path })
    }

    private func applicationURLs() -> [URL] {
        var found: [URL] = []
        func collect(_ directory: URL, depth: Int) {
            guard let entries = try? fileManager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for entry in entries.sorted(by: { $0.path < $1.path }) {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if entry.pathExtension.lowercased() == "app" {
                    found.append(entry)
                } else if depth < 2 {
                    collect(entry, depth: depth + 1)
                }
            }
        }
        collect(applications, depth: 0)
        collect(home.appending(path: "Applications"), depth: 0)
        return found
    }

    private func applicationURL(named names: [String], in applications: [URL]) -> URL? {
        for name in names {
            if let url = applications.first(where: {
                $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
            }) { return url }
        }
        return nil
    }

    private func discoverOtherAgents(excluding knownRoots: Set<String>) -> [Agent] {
        let bases: [(URL, Int)] = [
            (home, 2),
            (home.appending(path: ".config"), 3),
            (home.appending(path: ".local/share"), 3),
            (home.appending(path: "Library/Application Support"), 3)
        ]
        var candidates: Set<URL> = []
        func search(_ directory: URL, depth: Int, limit: Int, homeBase: Bool) {
            guard depth <= limit,
                  let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let component = entry.lastPathComponent
                if component.lowercased() == "skills" {
                    if values?.isDirectory == true || (values?.isSymbolicLink == true && isDirectory(entry)) {
                        candidates.insert(entry.standardizedFileURL)
                    }
                    continue
                }
                guard values?.isDirectory == true else { continue }
                guard depth < limit,
                      ![".cache", ".git", "node_modules", ".build", "Caches", "Extensions", "plugins"].contains(component),
                      !component.hasPrefix(".mskill-") else { continue }
                if homeBase && depth == 0 && !component.hasPrefix(".") { continue }
                search(entry, depth: depth + 1, limit: limit, homeBase: false)
            }
        }
        for (base, limit) in bases {
            search(base, depth: 0, limit: limit, homeBase: base == home)
        }
        var seenRoots = knownRoots
        return candidates
            .sorted { $0.path < $1.path }
            .filter { root in
                guard !seenRoots.contains(root.path), !seenRoots.contains(root.realFileURL.path) else { return false }
                seenRoots.insert(root.realFileURL.path)
                return true
            }
            .compactMap { root in
                guard !scanRoot(root, agentID: "probe").skills.isEmpty else { return nil }
                let rawName = root.deletingLastPathComponent().lastPathComponent
                let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    .replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: "_", with: " ")
                    .capitalized
                return Agent(id: "discovered:\(root.path)", name: name.isEmpty ? "其他 Agent" : name,
                             symbol: "square.dashed.inset.filled", roots: [root], installed: true, isCustom: false)
            }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func scanRoot(_ root: URL, agentID: String) -> (skills: [Skill], brokenLinks: [BrokenLink]) {
        guard fileManager.fileExists(atPath: root.path) else { return ([], []) }
        var found: [Skill] = []
        var broken: [BrokenLink] = []
        var visited: Set<String> = []
        func walk(_ directory: URL, depth: Int) {
            guard depth <= 4, !visited.contains(directory.realFileURL.path) else { return }
            visited.insert(directory.realFileURL.path)
            guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { return }
            for entry in entries {
                guard ![".git", "node_modules", "dist", "build", ".mskill-backups"].contains(entry.lastPathComponent),
                      !entry.lastPathComponent.hasPrefix(".mskill-staging-") else { continue }
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                var linkTarget: URL?
                switch LinkStatus(at: entry, fileManager: fileManager) {
                case .dangling:
                    broken.append(.init(agentID: agentID, location: entry,
                                        destination: (try? fileManager.destinationOfSymbolicLink(atPath: entry.path)) ?? ""))
                    continue
                case .resolved(let target):
                    guard isDirectory(target) else { continue }
                    linkTarget = target
                case .none:
                    guard values?.isDirectory == true else { continue }
                }
                let manifest = entry.appending(path: "SKILL.md")
                if fileManager.fileExists(atPath: manifest.path) {
                    let metadata = Self.metadata(at: manifest, fallback: entry.lastPathComponent)
                    found.append(.init(id: "\(agentID):\(entry.standardizedFileURL.path)", agentID: agentID,
                                       folderName: entry.lastPathComponent, name: metadata.name,
                                       summary: metadata.summary, directory: entry,
                                       fingerprint: Self.fingerprint(of: entry, fileManager: fileManager),
                                       linkTarget: linkTarget))
                } else {
                    walk(entry, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        return (found, broken)
    }

    private static func metadata(at url: URL, fallback: String) -> (name: String, summary: String) {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return (fallback, "") }
        let lines = source.components(separatedBy: .newlines)
        var name = fallback
        var summary = ""
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<closing] {
                if line.hasPrefix("name:") { name = cleanYAMLValue(String(line.dropFirst(5))) }
                if line.hasPrefix("description:") { summary = cleanYAMLValue(String(line.dropFirst(12))) }
            }
        }
        if summary.isEmpty {
            summary = lines.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? "暂无描述"
        }
        return (name.isEmpty ? fallback : name, summary)
    }

    private static func cleanYAMLValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    static func fingerprint(of directory: URL, fileManager: FileManager = .default) -> String {
        let directory = directory.realFileURL
        var hasher = SHA256()
        let rootPath = directory.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return "" }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if [".git", "node_modules", "dist", "build", ".mskill-backups"].contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if url.lastPathComponent == ".DS_Store" { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(url) }
        }
        for url in files.sorted(by: { $0.path < $1.path }) {
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count))
            hasher.update(data: Data(relative.utf8))
            if let handle = try? FileHandle(forReadingFrom: url) {
                while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
                    hasher.update(data: chunk)
                }
                try? handle.close()
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct SkillSyncer {
    var fileManager: FileManager = .default

    func state(for skill: Skill, target: Agent) -> SyncState {
        guard let root = target.primaryRoot else { return .unavailable }
        let destination = root.appending(path: skill.folderName, directoryHint: .notDirectory)
        if destination.standardizedFileURL.path == skill.directory.standardizedFileURL.path { return .identical }
        switch LinkStatus(at: destination, fileManager: fileManager) {
        case .dangling: return .brokenLink
        case .resolved(let url) where url.path == skill.directory.realFileURL.path: return .linked
        case .resolved, .none: break
        }
        guard fileManager.fileExists(atPath: destination.path) else { return .missing }
        return SkillScanner.fingerprint(of: destination, fileManager: fileManager) == skill.fingerprint ? .identical : .conflict
    }

    /// 复制模式写入独立副本；链接模式在目标目录创建指向源真实路径的软链接。
    /// 目标中的实体文件夹被替换前总会移入 .mskill-backups；软链接本身不含数据，直接替换。
    func sync(_ skill: Skill, to target: Agent, replace: Bool = false, mode: SyncMode = .copy) throws -> SyncResult {
        let source = skill.directory.realFileURL
        guard fileManager.fileExists(atPath: source.appending(path: "SKILL.md").path) else { throw SkillError.invalidSource }
        guard let root = target.primaryRoot else { throw SkillError.unavailableTarget }
        // 不带结尾斜杠：对软链接做 remove/move 时，带斜杠的路径会被解析成链接指向的目录。
        let destination = root.appending(path: skill.folderName, directoryHint: .notDirectory)
        let link = LinkStatus(at: destination, fileManager: fileManager)
        if link == .resolved(source) { return SyncResult(destination: destination, backup: nil) }
        let destinationPath = root.realFileURL.appending(path: skill.folderName).path
        guard destinationPath != source.path, !destinationPath.hasPrefix(source.path + "/") else { throw SkillError.sameLocation }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let existing = fileManager.fileExists(atPath: destination.path)
        let identical = existing && SkillScanner.fingerprint(of: destination, fileManager: fileManager)
            == SkillScanner.fingerprint(of: source, fileManager: fileManager)
        if identical && mode == .copy { return SyncResult(destination: destination, backup: nil) }
        if existing && !identical && !replace { throw SkillError.conflict }

        let staging = root.appending(path: ".mskill-staging-\(UUID().uuidString)", directoryHint: .notDirectory)
        switch mode {
        case .copy: try fileManager.copyItem(at: source, to: staging)
        case .link: try fileManager.createSymbolicLink(at: staging, withDestinationURL: source)
        }
        var backup: URL?
        var removedLink: String?
        do {
            if link != .none {
                removedLink = try fileManager.destinationOfSymbolicLink(atPath: destination.path)
                try fileManager.removeItem(atPath: destination.path)
            } else if existing {
                let backupRoot = root.appending(path: ".mskill-backups", directoryHint: .isDirectory)
                try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
                let backupURL = backupRoot.appending(path: "\(skill.folderName)-\(ISO8601DateFormatter().string(from: Date()))-\(UUID().uuidString.prefix(6))")
                try fileManager.moveItem(at: destination, to: backupURL)
                backup = backupURL
            }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            if !fileManager.fileExists(atPath: destination.path) {
                if let backup { try? fileManager.moveItem(at: backup, to: destination) }
                if let removedLink { try? fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: removedLink) }
            }
            try? fileManager.removeItem(atPath: staging.path)
            throw error
        }
        return SyncResult(destination: destination, backup: backup)
    }

    /// 只删除失效的软链接本身；路径若是实体文件或仍然有效的链接则拒绝操作。
    func removeBrokenLink(_ link: BrokenLink) throws {
        guard LinkStatus(at: link.location, fileManager: fileManager) == .dangling else { throw SkillError.notBrokenLink }
        try fileManager.removeItem(atPath: link.location.path)
    }
}
