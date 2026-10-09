import Testing
import Foundation
@testable import MSkill

struct SkillCoreTests {
    private let fm = FileManager.default

    private func workspace() throws -> URL {
        let url = fm.temporaryDirectory.appending(path: "mskill-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSkill(at root: URL, folder: String, body: String) throws -> URL {
        let directory = root.appending(path: folder, directoryHint: .isDirectory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try body.write(to: directory.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        return directory
    }

    @Test func scanReadsManifestAndCustomAgent() throws {
        let temp = try workspace()
        defer { try? fm.removeItem(at: temp) }
        let root = temp.appending(path: "custom-skills")
        _ = try makeSkill(at: root, folder: "writer", body: "---\nname: Writing Helper\ndescription: Draft clear text\n---\n# Content")
        let custom = CustomAgent(name: "My Agent", path: root.path)
        let result = SkillScanner(home: temp, applications: temp, definitions: [], customAgents: [custom]).scan()

        #expect(result.agents.count == 1)
        #expect(result.agents[0].installed)
        #expect(result.skills.count == 1)
        #expect(result.skills[0].name == "Writing Helper")
        #expect(result.skills[0].summary == "Draft clear text")
    }

    @Test func syncDetectsConflictAndKeepsBackup() throws {
        let temp = try workspace()
        defer { try? fm.removeItem(at: temp) }
        let sourceRoot = temp.appending(path: "source")
        let targetRoot = temp.appending(path: "target")
        let source = try makeSkill(at: sourceRoot, folder: "writer", body: "# New")
        let targetDirectory = try makeSkill(at: targetRoot, folder: "writer", body: "# Old")
        let skill = Skill(id: "writer", agentID: "source", folderName: "writer", name: "Writer", summary: "",
                          directory: source, fingerprint: SkillScanner.fingerprint(of: source))
        let agent = Agent(id: "target", name: "Target", symbol: "folder", roots: [targetRoot], installed: true, isCustom: true)
        let syncer = SkillSyncer()

        #expect(syncer.state(for: skill, target: agent) == .conflict)
        #expect(throws: SkillError.self) { try syncer.sync(skill, to: agent) }
        let result = try syncer.sync(skill, to: agent, replace: true)
        #expect(try String(contentsOf: targetDirectory.appending(path: "SKILL.md"), encoding: .utf8) == "# New")
        #expect(result.backup != nil)
        #expect(try String(contentsOf: result.backup!.appending(path: "SKILL.md"), encoding: .utf8) == "# Old")
        #expect(syncer.state(for: skill, target: agent) == .identical)
    }

    @Test func syncCreatesMissingTarget() throws {
        let temp = try workspace()
        defer { try? fm.removeItem(at: temp) }
        let source = try makeSkill(at: temp.appending(path: "source"), folder: "helper", body: "# Help")
        let targetRoot = temp.appending(path: "missing/skills")
        let skill = Skill(id: "helper", agentID: "source", folderName: "helper", name: "Helper", summary: "",
                          directory: source, fingerprint: SkillScanner.fingerprint(of: source))
        let target = Agent(id: "target", name: "Target", symbol: "folder", roots: [targetRoot], installed: true, isCustom: true)
        #expect(SkillSyncer().state(for: skill, target: target) == .missing)
        let result = try SkillSyncer().sync(skill, to: target)
        #expect(fm.fileExists(atPath: result.destination.appending(path: "SKILL.md").path))
        try "# Updated".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        #expect(throws: SkillError.self) { try SkillSyncer().sync(skill, to: target) }
    }

    @Test func discoversUnknownAgentAndIgnoresBackup() throws {
        let temp = try workspace()
        defer { try? fm.removeItem(at: temp) }
        let root = temp.appending(path: ".new-agent/skills")
        _ = try makeSkill(at: root, folder: "helper", body: "# Helper")
        _ = try makeSkill(at: root.appending(path: ".mskill-backups"), folder: "old-helper", body: "# Old")

        let result = SkillScanner(home: temp, applications: temp, definitions: []).scan()
        #expect(result.agents.count == 1)
        #expect(result.agents[0].name == "New Agent")
        #expect(result.skills.map(\.folderName) == ["helper"])
    }

    @Test func prefersAgentApplicationOverCompanionApplication() throws {
        let temp = try workspace()
        defer { try? fm.removeItem(at: temp) }
        let applications = temp.appending(path: "SystemApplications")
        let chatGPT = applications.appending(path: "ChatGPT.app")
        let codex = temp.appending(path: "Applications/Developer/Codex.app")
        try fm.createDirectory(at: chatGPT, withIntermediateDirectories: true)
        try fm.createDirectory(at: codex, withIntermediateDirectories: true)
        let definitions = AgentDefinition.known.filter { $0.id == "codex" }
        let scanner = SkillScanner(home: temp, applications: applications, definitions: definitions)

        let agent = try #require(scanner.scan().agents.first)
        #expect(agent.installed)
        #expect(agent.applicationURL?.resolvingSymlinksInPath().path == codex.resolvingSymlinksInPath().path)

        try fm.removeItem(at: codex)
        #expect(scanner.scan().agents.first?.applicationURL?.resolvingSymlinksInPath().path == chatGPT.resolvingSymlinksInPath().path)
    }

    @Test func findsLocalIconsForKnownAndCustomAgents() throws {
        let temp = try workspace()
        defer { try? fm.removeItem(at: temp) }
        let applications = temp.appending(path: "SystemApplications")
        let claude = applications.appending(path: "claude.app")
        let customApp = temp.appending(path: "Applications/My Agent.app")
        let root = temp.appending(path: "custom-skills")
        try fm.createDirectory(at: claude, withIntermediateDirectories: true)
        try fm.createDirectory(at: customApp, withIntermediateDirectories: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let custom = CustomAgent(name: "My Agent", path: root.path)
        let definitions = AgentDefinition.known.filter { $0.id == "claude" }
        let agents = SkillScanner(home: temp, applications: applications,
                                  definitions: definitions, customAgents: [custom]).scan().agents

        #expect(agents.first { $0.id == "claude" }?.applicationURL?.resolvingSymlinksInPath().path == claude.resolvingSymlinksInPath().path)
        #expect(agents.first { $0.id == "claude" }?.installed == true)
        #expect(agents.first { $0.id == custom.id.uuidString }?.applicationURL?.resolvingSymlinksInPath().path == customApp.resolvingSymlinksInPath().path)
    }

    @Test func skillDirectoryWithoutApplicationKeepsSymbolFallback() throws {
        let temp = try workspace()
        defer { try? fm.removeItem(at: temp) }
        try fm.createDirectory(at: temp.appending(path: ".cursor/skills"), withIntermediateDirectories: true)
        let definitions = AgentDefinition.known.filter { $0.id == "cursor" }
        let agent = try #require(SkillScanner(home: temp, applications: temp,
                                            definitions: definitions).scan().agents.first)

        #expect(agent.installed)
        #expect(agent.applicationURL == nil)
        #expect(agent.symbol == "cursorarrow.rays")
    }

    @Test func scanFollowsSymlinkedSkillsAndReportsBrokenLinks() throws {
        let temp = try workspace()
        defer { try? fm.removeItem(at: temp) }
        let library = temp.appending(path: "library")
        let source = try makeSkill(at: library, folder: "writer", body: "---\nname: Writer\n---")
        let root = temp.appending(path: ".cursor/skills")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appending(path: "writer"), withDestinationURL: source)
        try fm.createSymbolicLink(atPath: root.appending(path: "gone").path, withDestinationPath: library.appending(path: "gone").path)
        let definitions = AgentDefinition.known.filter { $0.id == "cursor" }

        let result = SkillScanner(home: temp, applications: temp, definitions: definitions).scan()
        let skill = try #require(result.skills.first)
        #expect(result.skills.count == 1)
        #expect(skill.name == "Writer")
        #expect(skill.linkTarget?.path == source.realFileURL.path)
        #expect(skill.fingerprint == SkillScanner.fingerprint(of: source))
        #expect(result.brokenLinks.map(\.location.lastPathComponent) == ["gone"])
    }

    @Test func linkModeCreatesSymlinkThatTracksSource() throws {
        let temp = try workspace()
        defer { try? fm.removeItem(at: temp) }
        let source = try makeSkill(at: temp.appending(path: "source"), folder: "helper", body: "# Help")
        let targetRoot = temp.appending(path: "target")
        let skill = Skill(id: "helper", agentID: "source", folderName: "helper", name: "Helper", summary: "",
                          directory: source, fingerprint: SkillScanner.fingerprint(of: source))
        let target = Agent(id: "target", name: "Target", symbol: "folder", roots: [targetRoot], installed: true, isCustom: true)
        let syncer = SkillSyncer()

        let result = try syncer.sync(skill, to: target, mode: .link)
        #expect(try fm.destinationOfSymbolicLink(atPath: result.destination.path) == source.realFileURL.path)
        #expect(syncer.state(for: skill, target: target) == .linked)
        try "# Updated".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        #expect(try String(contentsOf: result.destination.appending(path: "SKILL.md"), encoding: .utf8) == "# Updated")
        #expect(try syncer.sync(skill, to: target, mode: .link).backup == nil)
        #expect(try syncer.sync(skill, to: target, mode: .copy).backup == nil)
        #expect(syncer.state(for: skill, target: target) == .linked)
    }

    @Test func linkModeBacksUpRealFolderAndCopyModeCopiesThroughLink() throws {
        let temp = try workspace()
        defer { try? fm.removeItem(at: temp) }
        let source = try makeSkill(at: temp.appending(path: "source"), folder: "writer", body: "# Same")
        let targetRoot = temp.appending(path: "target")
        _ = try makeSkill(at: targetRoot, folder: "writer", body: "# Same")
        let skill = Skill(id: "writer", agentID: "source", folderName: "writer", name: "Writer", summary: "",
                          directory: source, fingerprint: SkillScanner.fingerprint(of: source))
        let target = Agent(id: "target", name: "Target", symbol: "folder", roots: [targetRoot], installed: true, isCustom: true)
        let syncer = SkillSyncer()

        #expect(syncer.state(for: skill, target: target) == .identical)
        let linked = try syncer.sync(skill, to: target, mode: .link)
        #expect(linked.backup != nil)
        #expect(syncer.state(for: skill, target: target) == .linked)

        let linkedSkill = Skill(id: "linked", agentID: "target", folderName: "writer", name: "Writer", summary: "",
                                directory: linked.destination, fingerprint: skill.fingerprint)
        let other = Agent(id: "other", name: "Other", symbol: "folder", roots: [temp.appending(path: "other")], installed: true, isCustom: true)
        let copied = try syncer.sync(linkedSkill, to: other, mode: .copy)
        #expect((try? fm.destinationOfSymbolicLink(atPath: copied.destination.path)) == nil)
        #expect(fm.fileExists(atPath: copied.destination.appending(path: "SKILL.md").path))
    }

    @Test func brokenLinkIsRepairedAndRemovedSafely() throws {
        let temp = try workspace()
        defer { try? fm.removeItem(at: temp) }
        let source = try makeSkill(at: temp.appending(path: "source"), folder: "helper", body: "# Help")
        let targetRoot = temp.appending(path: "target")
        try fm.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        let dangling = targetRoot.appending(path: "helper")
        try fm.createSymbolicLink(atPath: dangling.path, withDestinationPath: temp.appending(path: "missing").path)
        let skill = Skill(id: "helper", agentID: "source", folderName: "helper", name: "Helper", summary: "",
                          directory: source, fingerprint: SkillScanner.fingerprint(of: source))
        let target = Agent(id: "target", name: "Target", symbol: "folder", roots: [targetRoot], installed: true, isCustom: true)
        let syncer = SkillSyncer()

        #expect(syncer.state(for: skill, target: target) == .brokenLink)
        _ = try syncer.sync(skill, to: target, mode: .copy)
        #expect(syncer.state(for: skill, target: target) == .identical)
        #expect((try? fm.destinationOfSymbolicLink(atPath: dangling.path)) == nil)

        let realFolder = BrokenLink(agentID: "target", location: dangling, destination: "")
        #expect(throws: SkillError.self) { try syncer.removeBrokenLink(realFolder) }
        #expect(fm.fileExists(atPath: dangling.appending(path: "SKILL.md").path))

        let orphan = targetRoot.appending(path: "orphan")
        try fm.createSymbolicLink(atPath: orphan.path, withDestinationPath: temp.appending(path: "nowhere").path)
        try syncer.removeBrokenLink(BrokenLink(agentID: "target", location: orphan, destination: ""))
        #expect((try? fm.destinationOfSymbolicLink(atPath: orphan.path)) == nil)
    }
}
