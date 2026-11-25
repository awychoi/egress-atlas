import SwiftUI

struct AtlasTopBar: View {
    @ObservedObject var runtime: AtlasRuntime
    let metrics: Metrics
    @State private var livePulse = false
    @State private var topRightWidth: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            HStack(alignment: .top, spacing: 12) {
                brand
                    .padding(.top, metrics.brandTopInset)
                panelNav
                    .padding(.top, metrics.brandTopInset + 4)
                Spacer(minLength: 12)
                topRight
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: TopRightWidthKey.self, value: proxy.size.width)
                        }
                    )
            }
            if metrics.showTopCenter && hasRoomForTopCenter && !centersSwitcher {
                topCenter
                    .padding(.top, 6)
            }
            if centersSwitcher {
                HostGlobeSwitcher(runtime: runtime, metrics: metrics)
                    .padding(.top, metrics.topPadding)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.top, metrics.topPadding)
        .padding(.leading, metrics.topSidePadding)
        .padding(.trailing, metrics.topSidePadding)
        .onPreferenceChange(TopRightWidthKey.self) { topRightWidth = $0 }
    }

    private var centersSwitcher: Bool { metrics.width >= 1180 }

    private var brand: some View {
        Group {
            if metrics.tiny {
                BrandMark(side: metrics.brandLockupHeight)
            } else {
                BrandLockup(height: metrics.brandLockupHeight)
            }
        }
    }

    private var panelNav: some View {
        let host = runtime.displayedGlobe == .host
        return HStack(spacing: 2) {
            panelButton(
                title: host ? "Apps" : "Network",
                symbol: host ? "square.grid.2x2" : "list.bullet",
                count: host ? runtime.hostSnapshot.apps.count : runtime.network.devices.count,
                active: runtime.leftRailOpen,
                accent: host ? Palette.host : Palette.gold,
                hint: host ? "Toggle the host apps panel ([)" : "Toggle the network panel ([)",
                action: toggleNetwork
            )
            panelButton(
                title: host ? "Domains" : "Queries",
                symbol: host ? "globe" : "waveform.path.ecg",
                count: host ? runtime.hostSnapshot.domains.count
                    : (runtime.isReplay ? runtime.feed.count : runtime.feedCount),
                active: runtime.rightRailOpen,
                accent: host ? Palette.host : Palette.gold,
                hint: host ? "Toggle the host domains panel (])" : "Toggle the live queries panel (])",
                action: toggleQueries
            )
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.rgba("0f0805", 0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Palette.text.opacity(0.11), lineWidth: 1)
        )
    }

    private func panelButton(
        title: String,
        symbol: String,
        count: Int,
        active: Bool,
        accent: SRGB = Palette.gold,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .opacity(active ? 1 : 0.76)
                if !metrics.compact {
                    Text(title.uppercased())
                        .font(.atlasMono(10, .regular))
                        .tracking(0.7)
                }
                if !metrics.tiny {
                    Text(Format.compact(count))
                        .font(.atlasMono(9, .regular))
                        .foregroundColor(active ? accent.opacity(0.72) : Palette.dim.color)
                        .padding(.leading, showsPanelLabel ? 5 : 0)
                        .overlay(alignment: .leading) {
                            if showsPanelLabel {
                                Rectangle().fill(Palette.text.opacity(0.062)).frame(width: 1)
                            }
                        }
                }
            }
            .foregroundColor(active ? accent.color : Palette.muted.color)
            .padding(.horizontal, 7)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? accent.opacity(0.09) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(active ? accent.opacity(0.16) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(AtlasPlainButtonStyle())
        .help(hint)
        .accessibilityLabel("\(title) panel, \(count) \(title == "Network" ? "devices" : "recent queries")")
        .accessibilityValue(active ? "Open" : "Closed")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var showsPanelLabel: Bool { !metrics.compact }

    private func toggleNetwork() {
        runtime.filterOpen = false
        let opening = !runtime.leftRailOpen
        if opening && metrics.width <= 1280 { runtime.rightRailOpen = false }
        runtime.leftRailOpen = opening
    }

    private func toggleQueries() {
        runtime.filterOpen = false
        let opening = !runtime.rightRailOpen
        if opening && metrics.width <= 1280 { runtime.leftRailOpen = false }
        runtime.rightRailOpen = opening
    }

    private var topCenter: some View {
        HStack(spacing: 15) {
            if runtime.displayedGlobe == .host {
                hostPill
            } else {
                livePill
            }
            if hasRoomForTopMeta {
                HStack(spacing: 9) {
                    Text(runtime.displayedGlobe == .host
                         ? "\(Format.compact(runtime.hostSnapshot.apps.count)) apps"
                         : runtime.devicePresenceText)
                    Circle().fill(Palette.faint.color).frame(width: 2, height: 2)
                    Text(runtime.displayedGlobe == .host
                         ? "\(Format.compact(runtime.hostSnapshot.domains.count)) domains"
                         : "\(Format.compact(runtime.windowStats.destinations)) destinations")
                }
                .font(.atlasMono(7, .regular))
                .tracking(7 * 0.09)
                .foregroundColor(Palette.faint.color)
            }
        }
    }

    /// The centred live readout and the right-hand toolbar share one row. Use
    /// the measured toolbar width to keep the live pill clear of its leading
    /// edge, then only add the secondary devices/destinations readout when that
    /// still fits.
    private var hasRoomForTopCenter: Bool {
        guard topRightWidth > 0 else { return false }
        let center = metrics.width / 2
        let rightStart = metrics.width - metrics.topSidePadding - topRightWidth
        return rightStart - center >= 90
    }

    private var hasRoomForTopMeta: Bool {
        guard topRightWidth > 0 else { return false }
        let center = metrics.width / 2
        let rightStart = metrics.width - metrics.topSidePadding - topRightWidth
        return 2 * max(0, rightStart - center - 14) >= 350
    }

    private var livePill: some View {
        let replay = runtime.isReplay
        let tone: Color = runtime.paused ? Palette.coral.color
            : (replay ? Palette.gold.color : Palette.sage.color)
        return HStack(spacing: 8) {
            Circle()
                .fill(tone)
                .frame(width: 4, height: 4)
                .shadow(color: tone.opacity(0.8), radius: 3.5)
                .opacity(runtime.paused ? 1 : (livePulse ? 1 : 0.32))
            Text(runtime.paused ? "PAUSED" : (replay ? "REPLAY" : "LIVE"))
                .font(.atlasMono(7.5, .regular))
                .tracking(7.5 * 0.13)
                .foregroundColor(tone)
            Text(runtime.clock)
                .font(.atlasMono(7.5, .regular))
                .tracking(7.5 * 0.06)
                .foregroundColor(Palette.text2.color)
                .monospacedDigit()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(runtime.paused ? Color.rgba("25100c", 0.3)
                           : (replay ? Color.rgba("1c1408", 0.35) : Color.rgba("0e1913", 0.24)))
        )
        .overlay(
            Capsule().strokeBorder(tone.opacity(0.24), lineWidth: 1)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { livePulse = true }
        }
    }

    private var hostPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Palette.host.color)
                .frame(width: 4, height: 4)
                .shadow(color: Palette.host.opacity(0.8), radius: 3.5)
                .opacity(runtime.hostPaused ? 1 : (livePulse ? 1 : 0.32))
            Text("HOST")
                .font(.atlasMono(7.5, .regular))
                .tracking(7.5 * 0.13)
                .foregroundColor(Palette.host.color)
            Text(runtime.clock)
                .font(.atlasMono(7.5, .regular))
                .tracking(7.5 * 0.06)
                .foregroundColor(Palette.text2.color)
                .monospacedDigit()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.rgba("081416", 0.35)))
        .overlay(Capsule().strokeBorder(Palette.host.opacity(0.24), lineWidth: 1))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { livePulse = true }
        }
    }

    private var topRight: some View {
        HStack(spacing: metrics.topRightGap) {
            if !centersSwitcher {
                HostGlobeSwitcher(runtime: runtime, metrics: metrics)
                topDivider
            }
            sourceChip
            filterMenu
            topDivider
            searchButton
            helpButton
            settingsButton
        }
        .padding(.top, 2)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var topDivider: some View {
        Rectangle()
            .fill(Palette.text.opacity(0.08))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 1)
    }

    private var sourceChip: some View {
        let host = runtime.displayedGlobe == .host
        let tone = host ? Palette.host : (runtime.isLiveSource ? Palette.signal : Palette.gold)
        return Button {
            runtime.helpOpen = false
            runtime.filterOpen = false
            if host {
                runtime.settingsTab = .host
            } else {
                runtime.settingsTab = .source
            }
            runtime.settingsOpen = true
        } label: {
            HStack(spacing: 6) {
                Circle().fill(tone.color).frame(width: 5, height: 5)
                    .shadow(color: tone.opacity(0.6), radius: 4)
                if metrics.showSourceLabel {
                    Text(host ? "THIS MAC" : (runtime.isLiveSource ? "PI-HOLE" : "DEMO"))
                        .font(.atlasMono(7, .regular))
                        .tracking(7 * 0.12)
                        .foregroundColor(host ? Palette.host.color : Palette.muted.color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(height: 32)
            .padding(.horizontal, metrics.showSourceLabel ? 10 : 8)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.rgba("110906", 0.68))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Palette.text.opacity(0.11), lineWidth: 1)
            )
        }
        .buttonStyle(AtlasPlainButtonStyle())
        .accessibilityLabel(host ? "Data source: this Mac" : (runtime.isLiveSource ? "Data source: Pi-hole live" : "Data source: demo"))
    }

    @ViewBuilder
    private var filterMenu: some View {
        if runtime.displayedGlobe == .host {
            if !metrics.tiny {
                HostScopeCountChip(runtime: runtime, compact: false)
            }
        } else {
            dnsFilterMenu
        }
    }

    private var dnsFilterMenu: some View {
        let activeColor: Color = runtime.filter == .blocked ? Palette.coralHot.color : Palette.gold.color
        return Button {
            runtime.helpOpen = false
            runtime.settingsOpen = false
            runtime.filterOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(filterTitle(runtime.filter).uppercased())
                    .font(.atlasMono(8, .regular))
                    .tracking(8 * 0.12)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if metrics.showFilterCounts {
                    Text(Format.compact(filterCount(runtime.filter)))
                        .font(.atlasMono(7, .regular))
                        .tracking(7 * 0.02)
                        .foregroundColor(activeColor.opacity(0.6))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundColor(Palette.faint.color)
                    .padding(.leading, 1)
            }
            .foregroundColor(activeColor)
            .frame(height: 32)
            .padding(.horizontal, metrics.narrowest ? 8 : 10)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.rgba("0f0805", 0.62))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(runtime.filterOpen ? activeColor.opacity(0.26) : Palette.text.opacity(0.11),
                                  lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(AtlasPlainButtonStyle())
        .popover(isPresented: Binding(get: { runtime.filterOpen },
                                      set: { runtime.filterOpen = $0 }),
                 arrowEdge: .top) {
            FilterMenuCard(runtime: runtime)
        }
        .fixedSize(horizontal: true, vertical: false)
        .help("Filter outcomes (F)")
        .accessibilityLabel("Outcome filter")
        .accessibilityValue("\(filterTitle(runtime.filter)), \(filterCount(runtime.filter)) destinations")
    }

    private func filterTitle(_ filter: OutcomeFilter) -> String {
        filter.rawValue.capitalized
    }

    private func filterCount(_ filter: OutcomeFilter) -> Int {
        switch filter {
        case .all: return runtime.windowStats.destinations
        case .allowed: return runtime.windowStats.allowed
        case .blocked: return runtime.windowStats.blockedDestinations
        }
    }

    private var searchButton: some View {
        Button {
            runtime.filterOpen = false
            runtime.helpOpen = false
            runtime.settingsOpen = false
            runtime.commandOpen = true
        } label: {
            HStack(spacing: 7) {
                SearchGlyph(size: 12, color: Palette.dim.color)
                if metrics.showSearchLabel {
                    Text("SEARCH")
                        .font(.atlasMono(7.5, .regular))
                        .tracking(7.5 * 0.08)
                        .foregroundColor(Palette.dim.color)
                    Text("⌘K")
                        .font(.atlasMono(6.5, .regular))
                        .foregroundColor(Palette.faint.color)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Palette.text.opacity(0.062), lineWidth: 1)
                        )
                }
            }
            .frame(height: 34)
            .padding(.horizontal, 11)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.rgba("0f0805", 0.62))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Palette.text.opacity(0.11), lineWidth: 1)
            )
        }
        .buttonStyle(AtlasPlainButtonStyle())
        .accessibilityLabel("Search devices, destinations and actions")
    }

    private var helpButton: some View {
        Button {
            let opening = !runtime.helpOpen
            runtime.filterOpen = false
            runtime.settingsOpen = false
            runtime.helpOpen = opening
        } label: {
            Text("?")
                .font(.atlasMono(9.5, .medium))
                .foregroundColor(runtime.helpOpen ? Palette.gold.color : Palette.muted.color)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.rgba("0f0805", 0.62))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(runtime.helpOpen ? Palette.gold.opacity(0.26) : Palette.text.opacity(0.11),
                                      lineWidth: 1)
                )
        }
        .buttonStyle(AtlasPlainButtonStyle())
        .help("How to read this field")
        .accessibilityLabel("How to read this field")
        .accessibilityValue(runtime.helpOpen ? "Open" : "Closed")
    }

    private var settingsButton: some View {
        Button {
            runtime.helpOpen = false
            runtime.filterOpen = false
            runtime.settingsOpen.toggle()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13.5, weight: .regular))
                .foregroundColor(Palette.muted.color)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.rgba("0f0805", 0.62))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Palette.text.opacity(0.11), lineWidth: 1)
                )
        }
        .buttonStyle(AtlasPlainButtonStyle())
        .accessibilityLabel("Settings")
    }
}

/// The collapsed outcome filter. A popover keeps the one-line control in the
/// top bar while preserving the three outcomes and their counts.
private struct FilterMenuCard: View {
    @ObservedObject var runtime: AtlasRuntime

    var body: some View {
        VStack(spacing: 0) {
            ForEach(OutcomeFilter.allCases, id: \.self) { option in
                FilterMenuRow(runtime: runtime, option: option)
            }
            HStack(spacing: 0) {
                Text("F CYCLES · ESC CLOSES")
                    .font(.atlasMono(6.2, .regular))
                    .tracking(6.2 * 0.07)
                    .foregroundColor(Palette.faint.color)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .overlay(alignment: .top) { Hairline().padding(.top, 2) }
        }
        .padding(4)
        .frame(width: 200)
        .background(WarmGlass(radius: 8, strong: true))
        .shadow(color: .black.opacity(0.42), radius: 20, x: 0, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Outcome filter")
    }
}

private struct FilterMenuRow: View {
    @ObservedObject var runtime: AtlasRuntime
    let option: OutcomeFilter
    @State private var hover = false

    private var active: Bool { runtime.filter == option }
    private var accent: Color { option == .blocked ? Palette.coralHot.color : Palette.gold.color }

    private var count: Int {
        switch option {
        case .all: return runtime.windowStats.destinations
        case .allowed: return runtime.windowStats.allowed
        case .blocked: return runtime.windowStats.blockedDestinations
        }
    }

    var body: some View {
        Button {
            runtime.setFilter(option)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(accent)
                    .frame(width: 4, height: 4)
                    .shadow(color: accent.opacity(0.7), radius: 3)
                Text(option.rawValue.uppercased())
                    .font(.atlasMono(7.4, .regular))
                    .tracking(7.4 * 0.09)
                Spacer(minLength: 6)
                Text(Format.compact(count))
                    .font(.atlasMono(6.8, .regular))
                    .foregroundColor(active ? accent.opacity(0.7) : Palette.faint.color)
                Image(systemName: "checkmark")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundColor(accent)
                    .opacity(active ? 1 : 0)
                    .frame(width: 9)
            }
            .foregroundColor(active ? accent : (hover ? Palette.text2.color : Palette.muted.color))
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(active ? accent.opacity(0.075)
                          : (hover ? Palette.text.opacity(0.035) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(AtlasPlainButtonStyle())
        .onHover { hover = $0 }
        .accessibilityLabel("Show \(option.rawValue) outcomes")
        .accessibilityValue(active ? "Selected" : "Not selected")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct TopRightWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
