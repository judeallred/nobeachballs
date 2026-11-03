import NoBeachballsCore
import SwiftUI

enum ListMode: String, CaseIterable {
    case grouped = "Grouped"
    case all = "All processes"
}

enum SortKey: String, CaseIterable {
    case cpu = "CPU"
    case memory = "Memory"
    case disk = "Disk"
}

struct ProcessListView: View {
    @ObservedObject var monitor: Monitor
    @State private var mode = ListMode.grouped
    @State private var sort = SortKey.cpu
    @State private var query = ""
    @State private var showSystem = false
    @State private var expanded = Set<String>()

    var body: some View {
        Panel(title: "proc", trailing: "\(monitor.groups.reduce(0) { $0 + $1.members.count }) processes") {
            HStack(spacing: 8) {
                TextField("filter (name, command, pid)", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(11))
                    .frame(width: 260)
                Picker("", selection: $mode) {
                    ForEach(ListMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                Picker("", selection: $sort) {
                    ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                Toggle("system", isOn: $showSystem).toggleStyle(.checkbox).font(Theme.mono(10))
                    .help("Show system and other users' processes. Their CPU/memory can't be read without root.")
                Spacer()
            }

            header
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { group in
                        VStack(spacing: 0) {
                            ProcessRow(monitor: monitor, system: monitor.system, deprioritized: monitor.deprioritized, group: group, depth: 0,
                                       expandable: mode == .grouped && group.members.count > 1,
                                       isExpanded: expanded.contains(group.id)) {
                                if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
                            }
                            if mode == .grouped, group.members.count > 1, expanded.contains(group.id) {
                                ForEach(group.members) { member in
                                    ProcessRow(monitor: monitor, system: monitor.system, deprioritized: monitor.deprioritized, group: single(member, in: group), depth: 1,
                                               expandable: false, isExpanded: false) {}
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("").frame(width: 14)
            Text("pid").frame(width: 52, alignment: .trailing)
            Text("name").frame(maxWidth: .infinity, alignment: .leading)
            Text("cpu").frame(width: 120, alignment: .leading)
            Text("mem").frame(width: 62, alignment: .trailing)
            Text("disk/s").frame(width: 62, alignment: .trailing)
            Text("").frame(width: 76)
        }
        .font(Theme.mono(10, .bold))
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 4)
    }

    private var rows: [ProcessGroup] {
        let source: [ProcessGroup]
        switch mode {
        case .grouped: source = monitor.groups
        case .all: source = monitor.groups.flatMap { g in g.members.map { single($0, in: g) } }
        }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = source.filter { g in
            guard showSystem || g.kind != .system else { return false }
            guard !needle.isEmpty else { return true }
            return g.name.lowercased().contains(needle) || g.members.contains { p in
                p.name.lowercased().contains(needle) || p.command.lowercased().contains(needle) || "\(p.pid)" == needle
            }
        }
        let sorted: [ProcessGroup]
        switch sort {
        case .cpu: sorted = filtered.sorted { ($0.cpu, $0.memory) > ($1.cpu, $1.memory) }
        case .memory: sorted = filtered.sorted { $0.memory > $1.memory }
        case .disk: sorted = filtered.sorted { ($0.diskRate, $0.cpu) > ($1.diskRate, $1.cpu) }
        }
        return Array(sorted.prefix(300))
    }

    /// A single process presented as a group so it gets the same row and actions.
    private func single(_ p: ProcessSample, in group: ProcessGroup) -> ProcessGroup {
        let kind: ProcessGroup.Kind = group.kind == .system ? .system : .job
        return ProcessGroup(id: "pid:\(p.key.startTime):\(p.pid)", kind: kind, root: p, members: [p],
                            isProtected: group.isProtected)
    }
}

struct ProcessRow: View {
    let monitor: Monitor
    let system: SystemSample?
    let deprioritized: Set<ProcessKey>
    let group: ProcessGroup
    let depth: Int
    let expandable: Bool
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        let cores = Double(system?.coreCount ?? 1)
        HStack(spacing: 6) {
            Group {
                if expandable {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.dim)
                } else {
                    Text("")
                }
            }
            .frame(width: 14)

            Text(group.kind == .system && !group.root.isAccessible && depth == 0 ? "\(group.root.pid)" : "\(group.root.pid)")
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(Theme.dim)

            HStack(spacing: 5) {
                badge
                Text(group.name).font(Theme.mono(11, depth == 0 ? .semibold : .regular)).lineLimit(1)
                if depth == 0, group.members.count > 1 {
                    Text("×\(group.members.count)").font(Theme.mono(10)).foregroundStyle(Theme.dim)
                }
                Text(group.root.command).font(Theme.mono(10)).foregroundStyle(Theme.dim.opacity(0.8))
                    .lineLimit(1).truncationMode(.tail)
            }
            .padding(.leading, CGFloat(depth) * 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(group.root.command)

            HStack(spacing: 4) {
                MeterBar(fraction: group.cpu / (100 * cores), height: 5).frame(width: 56)
                Text(group.root.isAccessible ? percent(group.cpu) : "—").frame(width: 58, alignment: .trailing)
            }
            .frame(width: 120, alignment: .leading)

            Text(group.root.isAccessible ? ByteFormat.short(group.memory) : "—")
                .frame(width: 62, alignment: .trailing)
                .foregroundStyle(Theme.meter(Double(group.memory) / Double(max(system?.memTotal ?? 1, 1)) * 4))
            Text(group.root.isAccessible && group.diskRate > 1024 ? ByteFormat.short(group.diskRate) : "")
                .frame(width: 62, alignment: .trailing)
                .foregroundStyle(Theme.dim)

            ZStack(alignment: .trailing) {
                if hovering {
                    GroupActions(monitor: monitor, group: group)
                }
            }
            .frame(width: 76, alignment: .trailing)
        }
        .font(Theme.mono(11))
        .padding(.horizontal, 4)
        .frame(height: 21)
        .background(hovering ? Color.white.opacity(0.06) : group.anyStopped ? Theme.yellow.opacity(0.07) : .clear)
        .opacity(group.kind == .system ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if expandable { toggle() } }
    }

    @ViewBuilder
    private var badge: some View {
        if group.isStopped {
            Image(systemName: "pause.circle.fill").foregroundStyle(Theme.yellow).help("Paused")
        } else if group.anyStopped {
            Image(systemName: "pause.circle").foregroundStyle(Theme.yellow).help("Partly paused")
        } else if group.members.contains(where: { deprioritized.contains($0.key) }) {
            Image(systemName: "tortoise.fill").foregroundStyle(Theme.accent).help("Deprioritized by auto-throttle")
        } else if group.isProtected, group.kind != .system {
            Image(systemName: "shield.fill").foregroundStyle(Theme.dim.opacity(0.6))
                .help("Never auto-throttled (app, system, or on your list). You can still pause or kill it manually.")
        }
    }
}
