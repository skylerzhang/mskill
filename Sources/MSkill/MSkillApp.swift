import SwiftUI
import AppKit

@main
struct MSkillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = SkillStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Skill") {
                Button("重新扫描") { store.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

@MainActor
private enum AppIcon {
    static let image: NSImage = {
        let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png")
            ?? Bundle.module.url(forResource: "AppIcon", withExtension: "png")
        if let url, let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "MSkill")
            ?? NSImage()
    }()
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = AppIcon.image
    }
}

@MainActor
final class SkillStore: ObservableObject {
    @Published private(set) var result = ScanResult(agents: [], skills: [])
    @Published var selectedAgentID: String? = nil
    @Published var selectedSkillID: String? = nil
    @Published var search = ""
    @Published var notice: String? = nil

    private let customKey = "MSkill.customAgents.v1"
    private(set) var customAgents: [CustomAgent] = []
    private var agentIcons: [String: NSImage] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: customKey),
           let saved = try? JSONDecoder().decode([CustomAgent].self, from: data) {
            customAgents = saved
        }
        refresh()
    }

    var filteredSkills: [Skill] {
        result.skills.filter { skill in
            let matchesAgent = selectedAgentID == nil || skill.agentID == selectedAgentID
            let matchesSearch = search.isEmpty || skill.name.localizedCaseInsensitiveContains(search)
                || skill.folderName.localizedCaseInsensitiveContains(search)
                || skill.summary.localizedCaseInsensitiveContains(search)
            return matchesAgent && matchesSearch
        }
    }

    var filteredBrokenLinks: [BrokenLink] {
        result.brokenLinks.filter { link in
            (selectedAgentID == nil || link.agentID == selectedAgentID)
                && (search.isEmpty || link.location.lastPathComponent.localizedCaseInsensitiveContains(search))
        }
    }

    var selectedSkill: Skill? { result.skills.first { $0.id == selectedSkillID } }

    func agent(for id: String) -> Agent? { result.agents.first { $0.id == id } }
    func skillCount(for id: String) -> Int { result.skills.filter { $0.agentID == id }.count }
    func icon(for agent: Agent) -> NSImage? { agentIcons[agent.id] }

    func refresh() {
        let scan = SkillScanner(customAgents: customAgents).scan()
        agentIcons = Dictionary(uniqueKeysWithValues: scan.agents.compactMap { agent in
            guard agent.installed, let applicationURL = agent.applicationURL else { return nil }
            return (agent.id, NSWorkspace.shared.icon(forFile: applicationURL.path))
        })
        result = scan
        if let selectedSkillID, !result.skills.contains(where: { $0.id == selectedSkillID }) {
            self.selectedSkillID = nil
        }
    }

    func addCustom(name: String, path: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !path.isEmpty else { return }
        customAgents.append(.init(name: cleanName, path: path))
        saveCustom()
        refresh()
        selectedAgentID = customAgents.last?.id.uuidString
    }

    func removeCustom(id: String) {
        customAgents.removeAll { $0.id.uuidString == id }
        saveCustom()
        if selectedAgentID == id { selectedAgentID = nil }
        refresh()
    }

    func sync(_ skill: Skill, to agent: Agent, replace: Bool = false, mode: SyncMode = .copy) {
        do {
            let result = try SkillSyncer().sync(skill, to: agent, replace: replace, mode: mode)
            refresh()
            notice = switch (mode, result.backup == nil) {
            case (.copy, true): "已同步到 \(agent.name)"
            case (.copy, false): "已替换 \(agent.name) 中的 Skill，原版本已备份"
            case (.link, true): "已在 \(agent.name) 中创建链接"
            case (.link, false): "已将 \(agent.name) 中的 Skill 改为链接，原文件夹已备份"
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func removeBrokenLink(_ link: BrokenLink) {
        do {
            try SkillSyncer().removeBrokenLink(link)
            refresh()
        } catch {
            notice = error.localizedDescription
        }
    }

    private func saveCustom() {
        if let data = try? JSONEncoder().encode(customAgents) {
            UserDefaults.standard.set(data, forKey: customKey)
        }
    }
}

private enum Palette {
    static let background = Color(red: 0.965, green: 0.966, blue: 0.957)
    static let sidebar = Color(red: 0.938, green: 0.944, blue: 0.936)
    static let ink = Color(red: 0.16, green: 0.19, blue: 0.18)
    static let muted = Color(red: 0.47, green: 0.51, blue: 0.49)
    static let accent = Color(red: 0.17, green: 0.43, blue: 0.34)
    static let pale = Color(red: 0.86, green: 0.92, blue: 0.86)
}

struct ContentView: View {
    @EnvironmentObject private var store: SkillStore
    @State private var showAddSheet = false
    @State private var pendingConflict: Agent?
    @AppStorage("MSkill.syncMode") private var syncMode: SyncMode = .copy

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.black.opacity(0.07)).frame(width: 1)
            main
        }
        .background(Palette.background)
        .sheet(isPresented: $showAddSheet) { AddAgentSheet() }
        .confirmationDialog("发现同名 Skill", isPresented: Binding(get: { pendingConflict != nil }, set: { if !$0 { pendingConflict = nil } })) {
            Button("取消", role: .cancel) { pendingConflict = nil }
            Button("备份并替换", role: .destructive) {
                if let skill = store.selectedSkill, let agent = pendingConflict { store.sync(skill, to: agent, replace: true, mode: syncMode) }
                pendingConflict = nil
            }
        } message: {
            Text("目标目录中的内容不同。替换前会把原文件夹保存到目标目录的 .mskill-backups；若原来是软链接，只替换链接本身。")
        }
        .alert("操作结果", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("好的") { store.notice = nil }
        } message: { Text(store.notice ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: AppIcon.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    Text("MSkill").font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("本地 Skill 工作台").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 28)
            .padding(.bottom, 28)

            Text("资料库")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 22)
                .padding(.bottom, 9)
            sidebarRow(title: "所有 Skills", symbol: "square.grid.2x2", count: store.result.skills.count,
                       selected: store.selectedAgentID == nil) { store.selectedAgentID = nil; store.selectedSkillID = nil }

            HStack {
                Text("AGENT 客户端")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Text("\(store.result.agents.filter(\.installed).count) 已发现")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 22)
            .padding(.top, 30)
            .padding(.bottom, 9)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.result.agents) { agent in
                        sidebarRow(title: agent.name, symbol: agent.symbol, icon: store.icon(for: agent), count: store.skillCount(for: agent.id),
                                   selected: store.selectedAgentID == agent.id, dimmed: !agent.installed) {
                            store.selectedAgentID = agent.id
                            store.selectedSkillID = nil
                        }
                        .contextMenu {
                            if agent.isCustom {
                                Button("移除自定义客户端", role: .destructive) { store.removeCustom(id: agent.id) }
                            }
                            if let root = agent.primaryRoot {
                                Button("在 Finder 中显示目录") { NSWorkspace.shared.open(root.deletingLastPathComponent()) }
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 10)
            Button { showAddSheet = true } label: {
                Label("添加自定义路径", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(14)
        }
        .frame(width: 242)
        .background(Palette.sidebar)
        .foregroundStyle(Palette.ink)
    }

    private func sidebarRow(title: String, symbol: String, icon: NSImage? = nil, count: Int, selected: Bool, dimmed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                AgentIcon(symbol: symbol, image: icon, size: 18)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(selected ? Palette.accent : Palette.muted)
            }
            .foregroundStyle(dimmed ? Palette.muted.opacity(0.65) : Palette.ink)
            .padding(.horizontal, 12).frame(height: 36)
            .background(selected ? Palette.pale : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }

    private var main: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.black.opacity(0.07)).frame(height: 1)
            HStack(spacing: 0) {
                skillList
                    .frame(minWidth: 340, maxWidth: .infinity)
                Rectangle().fill(Color.black.opacity(0.07)).frame(width: 1)
                detail
                    .frame(width: 355)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(store.selectedAgentID.flatMap { store.agent(for: $0)?.name } ?? "所有 Skills")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                Text("集中查看、比较并同步本机 Agent 的 Skill")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer()
            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 30, height: 30) }
                .help("重新扫描 · ⌘R")
                .buttonStyle(.bordered)
            Text("\(store.filteredSkills.count) 个 Skill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(Palette.pale, in: Capsule())
        }
        .padding(.horizontal, 27).padding(.top, 31).padding(.bottom, 24)
    }

    private var skillList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("搜索名称或描述", text: $store.search).textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !store.search.isEmpty {
                    Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 13).frame(height: 36)
            .background(.white, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.black.opacity(0.07)))
            .padding(.horizontal, 25).padding(.top, 20).padding(.bottom, 13)

            if store.filteredSkills.isEmpty && store.filteredBrokenLinks.isEmpty {
                ContentUnavailableView(store.search.isEmpty ? "还没有发现 Skill" : "没有匹配的 Skill",
                                       systemImage: "square.stack.3d.up.slash",
                                       description: Text(store.search.isEmpty ? "检查 Agent 的 Skill 目录，或添加自定义路径。" : "试试其他搜索词。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(store.filteredBrokenLinks) { link in
                            brokenLinkRow(link)
                        }
                        ForEach(store.filteredSkills) { skill in
                            skillRow(skill)
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 22)
                }
            }
        }
    }

    private func skillRow(_ skill: Skill) -> some View {
        let selected = store.selectedSkillID == skill.id
        let agent = store.agent(for: skill.agentID)
        return Button { store.selectedSkillID = skill.id } label: {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 35, height: 35)
                    .background(Palette.pale.opacity(0.75), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 6) {
                    Text(skill.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(skill.summary).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(agent?.name ?? skill.agentID)
                        if skill.linkTarget != nil {
                            Label("链接", systemImage: "link").labelStyle(.titleAndIcon)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Palette.pale, in: Capsule())
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.accent)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted.opacity(0.7))
                    .padding(.top, 11)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(selected ? Palette.pale.opacity(0.75) : .white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Palette.accent.opacity(0.3) : Color.black.opacity(0.055)))
        }
        .buttonStyle(.plain)
    }

    private func brokenLinkRow(_ link: BrokenLink) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "link.badge.plus")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 35, height: 35)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 6) {
                Text(link.location.lastPathComponent).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                Text("链接已失效 → \(link.destination)").font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
                Text(store.agent(for: link.agentID)?.name ?? link.agentID)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            Button("移除链接") { store.removeBrokenLink(link) }
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.bordered)
                .help("只删除这个软链接，不会删除任何文件夹")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.3)))
    }

    @ViewBuilder
    private var detail: some View {
        if let skill = store.selectedSkill {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 54, height: 54)
                        .background(Palette.pale, in: RoundedRectangle(cornerRadius: 15))
                        .padding(.bottom, 17)
                    Text(skill.name)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                    Text(skill.summary).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        .lineSpacing(3).padding(.top, 8)
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text(skill.directory.path).lineLimit(2).textSelection(.enabled)
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .padding(.top, 20)
                    if let linkTarget = skill.linkTarget {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                            Text(linkTarget.path).lineLimit(2).textSelection(.enabled)
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.accent)
                        .padding(.top, 6)
                    }
                    Button("在 Finder 中显示", systemImage: "arrow.up.forward.app") {
                        NSWorkspace.shared.activateFileViewerSelecting([skill.linkTarget ?? skill.directory])
                    }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.link)
                    .padding(.top, 8)

                    Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1).padding(.vertical, 25)
                    Text("同步到其他 Agent")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Palette.ink)
                    Picker("同步方式", selection: $syncMode) {
                        Text("复制").tag(SyncMode.copy)
                        Text("链接").tag(SyncMode.link)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.top, 10)
                    Text(syncMode == .copy
                         ? "复制整个文件夹。之后修改源 Skill，需要再次同步。"
                         : "创建指向源文件夹的软链接，修改即时生效。源文件夹被删除或移动后，链接会失效。")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 7).padding(.bottom, 16)
                    ForEach(store.result.agents.filter { $0.id != skill.agentID }) { agent in
                        targetRow(skill: skill, agent: agent)
                    }
                }
                .padding(26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 34, weight: .ultraLight)).foregroundStyle(Palette.muted)
                Text("选择一个 Skill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("查看详情并同步到其他 Agent")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func targetRow(skill: Skill, agent: Agent) -> some View {
        let state = SkillSyncer().state(for: skill, target: agent)
        return HStack(spacing: 10) {
            AgentIcon(symbol: agent.symbol, image: store.icon(for: agent), size: 20)
                .foregroundStyle(Palette.accent)
                .frame(width: 28, height: 28)
                .background(Palette.pale.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(statusText(state, installed: agent.installed))
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            if let title = actionTitle(state, installed: agent.installed) {
                Button(title) {
                    if state == .conflict { pendingConflict = agent }
                    else { store.sync(skill, to: agent, mode: syncMode) }
                }
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.bordered)
                .tint(state == .brokenLink ? .orange : Palette.accent)
            } else if state == .identical || state == .linked {
                Image(systemName: state == .linked ? "link.circle.fill" : "checkmark.circle.fill").foregroundStyle(Palette.accent)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.055)).frame(height: 1) }
    }

    private func statusText(_ state: SyncState, installed: Bool) -> String {
        if !installed { return "未检测到客户端" }
        return switch state {
        case .unavailable: "目录不可用"
        case .missing: "尚未安装"
        case .identical: "已同步"
        case .linked: "已链接"
        case .brokenLink: "链接已失效"
        case .conflict: "内容不同"
        }
    }

    /// 返回 nil 表示不显示按钮。复制模式下内容相同即无需操作；链接模式下可把相同的副本改为链接。
    private func actionTitle(_ state: SyncState, installed: Bool) -> String? {
        guard installed else { return nil }
        return switch (state, syncMode) {
        case (.unavailable, _), (.linked, _), (.identical, .copy): nil
        case (.identical, .link): "改为链接"
        case (.brokenLink, _): "修复"
        case (.conflict, _): "替换"
        case (.missing, .copy): "同步"
        case (.missing, .link): "链接"
        }
    }
}

private struct AgentIcon: View {
    let symbol: String
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct AddAgentSheet: View {
    @EnvironmentObject private var store: SkillStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var path = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加自定义 Agent")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("选择该 Agent 存放 Skill 文件夹的目录。MSkill 会扫描其中包含 SKILL.md 的文件夹。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("客户端名称", text: $name)
            HStack {
                TextField("Skill 目录路径", text: $path)
                Button("选择…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加") { store.addCustom(name: name, path: path); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || path.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(26)
        .frame(width: 465)
    }
}
