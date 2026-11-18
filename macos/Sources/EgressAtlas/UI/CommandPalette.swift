import SwiftUI

struct CommandPalette: View {
    @ObservedObject var runtime: AtlasRuntime
    @State private var query = ""
    @State private var active = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let id: String
        let kind: Int // 0 device, 1 destination
        let title: String
        let detail: String
        let haystack: String
        let blocked: Bool
    }

    private var allItems: [Item] {
        var items: [Item] = []
        for device in runtime.network.devices {
            items.append(Item(
                id: "device:\(device.id)", kind: 0, title: device.name,
                detail: "\(device.kind) · \(device.ip) · \(Format.count(device.liveQueries)) queries",
                haystack: "\(device.name) \(device.kind) \(device.ip) \(device.os)".lowercased(),
                blocked: false
            ))
        }
        for destination in runtime.windowVisibleDestinations() {
            items.append(Item(
                id: "destination:\(destination.id)", kind: 1, title: destination.domain,
                detail: "\(destination.category) · \(destination.status.rawValue) · \(destination.devices.count) device\(destination.devices.count == 1 ? "" : "s")",
                haystack: "\(destination.domain) \(destination.category) \(destination.status.rawValue)".lowercased(),
                blocked: destination.status == .blocked
            ))
        }
        let actions: [(String, String, String)] = [
            ("open-network", "Open network panel", "devices, destinations, clients"),
            ("open-queries", "Open queries panel", "the live query feed"),
            ("filter-all", "Show all outcomes", "remove the outcome filter"),
            ("filter-blocked", "Show blocked only", "blocked destinations and queries"),
            ("pause", runtime.paused ? "Resume live traffic" : "Pause live traffic", "space"),
            ("settings", "Open settings", "source, display, motion, about"),
            ("reset-camera", "Reset camera", "return to the opening view"),
            ("labels-all", "Show all labels", "keep every orb labelled"),
        ]
        for (key, title, detail) in actions {
            items.append(Item(
                id: "action:\(key)", kind: 2, title: title, detail: detail,
                haystack: "\(title) \(detail) action".lowercased(), blocked: false
            ))
        }
        return items
    }

    private var filtered: [Item] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = allItems
        if q.isEmpty {
            let devices = all.filter { $0.kind == 0 }.prefix(4)
            let actions = all.filter { $0.kind == 2 }.prefix(4)
            return Array(actions) + Array(devices)
        }
        return Array(all.filter { $0.haystack.contains(q) }.prefix(14))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.opacity(0.54)
                    .background(VisualEffectView(material: .hudWindow, blending: .withinWindow).opacity(0.18))
                    .ignoresSafeArea()
                    .onTapGesture { runtime.commandOpen = false }

                VStack(spacing: 0) {
                    inputRow
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 0) {
                            if filtered.isEmpty {
                                Text("NO DEVICE OR DESTINATION MATCHES THAT SEARCH.")
                                    .font(.atlasMono(8, .regular))
                                    .tracking(8 * 0.06)
                                    .foregroundColor(Palette.faint.color)
                                    .padding(.vertical, 30)
                            } else {
                                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    group("ACTIONS", items: filtered.filter { $0.kind == 2 })
                                    group("DEVICES", items: filtered.filter { $0.kind == 0 })
                                } else {
                                    group("DEVICES", items: filtered.filter { $0.kind == 0 })
                                    group("DESTINATIONS", items: filtered.filter { $0.kind == 1 })
                                    group("ACTIONS", items: filtered.filter { $0.kind == 2 })
                                }
                            }
                        }
                        .padding(5)
                    }
                    .frame(maxHeight: min(540, geo.size.height * 0.62))
                    footer
                }
                .frame(width: min(540, geo.size.width - 40))
                .background(
                    ZStack {
                        VisualEffectView(material: .hudWindow, blending: .withinWindow).opacity(0.6)
                        LinearGradient(stops: [
                            .init(color: Color.rgba("2a170e", 0.94), location: 0),
                            .init(color: Color.rgba("0c0604", 0.96), location: 1),
                        ], startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Palette.gold.opacity(0.2), lineWidth: 1))
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.rgba("fff1dd", 0.06)).frame(height: 1).padding(.horizontal, 1).padding(.top, 1)
                }
                .shadow(color: .black.opacity(0.58), radius: 45, x: 0, y: 28)
                .padding(.top, geo.size.height * 0.18)
                .onAppear {
                    focused = true
                    active = 0
                }
            }
        }
        .transition(.opacity)
    }

    private var inputRow: some View {
        HStack(spacing: 9) {
            SearchGlyph(size: 15, color: Palette.gold.opacity(0.8))
            TextField("Search devices, domains, categories, or actions…", text: $query)
                .textFieldStyle(.plain)
                .font(.atlasSans(14, .regular))
                .tracking(-0.14)
                .foregroundColor(Palette.text.color)
                .focused($focused)
                .onChange(of: query) { _ in active = 0 }
                .onSubmit { chooseActive() }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.escape) { runtime.commandOpen = false; return .handled }
            Text("ESC")
                .font(.atlasMono(6.5, .regular))
                .foregroundColor(Palette.faint.color)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Palette.text.opacity(0.062), lineWidth: 1))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Hairline(color: Palette.text.opacity(0.11)) }
    }

    private func group(_ title: String, items: [Item]) -> some View {
        Group {
            if !items.isEmpty {
                HStack {
                    Text(title)
                        .font(.atlasMono(6.3, .regular))
                        .tracking(6.3 * 0.14)
                        .foregroundColor(Palette.faint.color)
                    Spacer()
                }
                .padding(.horizontal, 9)
                .padding(.top, 7)
                .padding(.bottom, 3)
                ForEach(items) { item in
                    let index = filtered.firstIndex(where: { $0.id == item.id }) ?? 0
                    Button {
                        choose(item)
                    } label: {
                        HStack(spacing: 8) {
                            if item.kind == 0 {
                                AtlasDeviceMark(color: Palette.signal.color, size: 18)
                            } else if item.kind == 1 {
                                AtlasDestinationMark(color: item.blocked ? Palette.coral.color : Palette.gold.color, size: 18)
                            } else {
                                Image(systemName: "return")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Palette.gold.color)
                                    .frame(width: 18, height: 18)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.atlasSans(11, .medium))
                                    .tracking(-0.1)
                                    .foregroundColor(Palette.text2.color)
                                    .lineLimit(1)
                                Text(item.detail)
                                    .font(.atlasMono(6.8, .regular))
                                    .tracking(6.8 * 0.04)
                                    .foregroundColor(Palette.faint.color)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text(item.kind == 0 ? "DEVICE" : (item.kind == 1 ? "DEST" : "ACTION"))
                                .font(.atlasMono(6.2, .regular))
                                .tracking(6.2 * 0.1)
                                .foregroundColor(Palette.faint.color)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(index == active ? Palette.gold.opacity(0.065) : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(index == active ? Palette.gold.opacity(0.14) : .clear, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(AtlasPlainButtonStyle())
                    .onHover { if $0 { active = index } }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Text("↑ ↓ NAVIGATE")
            dot
            Text("↵ SELECT")
            dot
            Text("ESC CLOSE")
        }
        .font(.atlasMono(6.2, .regular))
        .tracking(6.2 * 0.08)
        .foregroundColor(Palette.faint.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Hairline() }
    }

    private var dot: some View {
        Circle().fill(Palette.faint.color).frame(width: 2, height: 2)
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        active = (active + delta + filtered.count) % filtered.count
    }

    private func chooseActive() {
        guard filtered.indices.contains(active) else { return }
        choose(filtered[active])
    }

    private func choose(_ item: Item) {
        runtime.commandOpen = false
        if item.kind == 2 {
            let action = String(item.id.dropFirst("action:".count))
            switch action {
            case "open-network": runtime.leftRailOpen = true
            case "open-queries": runtime.rightRailOpen = true
            case "filter-all": runtime.setFilter(.all)
            case "filter-blocked": runtime.setFilter(.blocked)
            case "pause": runtime.setPaused(!runtime.paused)
            case "settings": runtime.settingsTab = .source; runtime.settingsOpen = true
            case "reset-camera": runtime.resetCamera()
            case "labels-all": runtime.setLabelMode(.all)
            default: break
            }
            runtime.showToast(item.title, tone: .signal)
            return
        }
        if item.kind == 0 {
            let id = String(item.id.dropFirst("device:".count))
            runtime.select(.device(id), toggle: false)
        } else {
            let id = String(item.id.dropFirst("destination:".count))
            runtime.select(.destination(id), toggle: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            runtime.focusSelection()
        }
        runtime.showToast("Tracing \(item.title)", tone: .signal)
    }
}
