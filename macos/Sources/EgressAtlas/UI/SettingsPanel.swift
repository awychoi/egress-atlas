import SwiftUI

struct SettingsPanel: View {
    @ObservedObject var runtime: AtlasRuntime
    let metrics: Metrics
    @State private var sourceURL = ""
    @State private var sourcePassword = ""
    @State private var sourceInsecure = false
    @State private var sourceFieldsLoaded = false

    private var hostMode: Bool { runtime.displayedGlobe == .host }
    private var accent: SRGB { hostMode ? Palette.host : Palette.gold }
    private var ink: Color { hostMode ? Palette.hostText.color : Palette.text.color }
    private var ink2: Color { hostMode ? Palette.hostText2.color : Palette.text2.color }
    private var muted: Color { hostMode ? Palette.hostMuted.color : Palette.muted.color }
    private var dim: Color { hostMode ? Palette.hostMeta.color : Palette.dim.color }
    private var faint: Color { hostMode ? Palette.hostFaint.color : Palette.faint.color }
    private var inactiveTone: SRGB { hostMode ? Palette.hostMeta : Palette.dim }
    private var warn: SRGB { hostMode ? Palette.hostFault : Palette.coral }
    private var okay: SRGB { hostMode ? Palette.hostMint : Palette.sage }
    private var divider: Color { hostMode ? Palette.hostText.opacity(0.09) : Palette.text.opacity(0.062) }
    private var dividerLine: some View { Hairline(color: divider) }
    private var visibleTabs: [SettingsTab] {
        hostMode ? [.host, .display, .about] : SettingsTab.allCases
    }
    private var activeTab: SettingsTab {
        if visibleTabs.contains(runtime.settingsTab) { return runtime.settingsTab }
        return hostMode ? .host : .source
    }

    private func insetFill(_ alpha: Double) -> Color {
        hostMode ? Color.rgba("050d11", max(0.24, alpha)) : Color.rgba("090503", alpha)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    activeContent
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
            foot
        }
        .frame(width: metrics.settingsWidth)
        .frame(maxHeight: metrics.mediumHeight
               ? max(280, metrics.height - metrics.railTop - 28)
               : max(280, metrics.height - metrics.railTop - metrics.railBottom + 12))
        .background(hostMode ? Palette.hostBg.color.opacity(0.985) : Palette.deep.color.opacity(0.985))
        .background {
            if hostMode {
                CoolGlass(radius: 12, strong: true)
            } else {
                WarmGlass(radius: 12, strong: true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(hostMode ? Palette.hostText.opacity(0.11) : ink.opacity(0.11), lineWidth: 1))
        .shadow(color: .black.opacity(0.52), radius: 40, x: 0, y: 28)
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .onAppear {
            guard !sourceFieldsLoaded else { return }
            sourceFieldsLoaded = true
            sourceURL = runtime.savedSourceURL
            sourceInsecure = runtime.savedSourceInsecure
        }
        .onChange(of: runtime.savedSourceURL) { value in
            if value.isEmpty {
                sourceURL = ""
                sourcePassword = ""
                sourceInsecure = false
            }
        }
        .onChange(of: runtime.sourceEndpoint) { endpoint in
            if endpoint != nil { sourcePassword = "" }
        }
    }

    @ViewBuilder
    private var activeContent: some View {
        switch activeTab {
        case .source: sourceSection
        case .display:
            if hostMode { hostDisplaySection } else { fieldSection }
        case .motion: motionSection
        case .host: hostSection
        case .about: aboutSection
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Eyebrow(text: hostMode ? "Host instrument" : "Atlas settings",
                        size: 8, color: muted, trackingEm: 0.16)
                Text(hostMode ? "Host settings" : "Settings")
                    .font(.atlasSans(22, .medium))
                    .tracking(-22 * 0.03)
                    .foregroundColor(ink)
            }
            Spacer()
            Button {
                runtime.settingsOpen = false
            } label: {
                CloseGlyph(size: 12, color: muted)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 5).fill(insetFill(0.28)))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(ink.opacity(0.062), lineWidth: 1))
            }
            .buttonStyle(AtlasPlainButtonStyle())
        }
        .padding(.horizontal, 15)
        .padding(.top, 15)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { dividerLine }
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(visibleTabs, id: \.self) { item in
                let active = activeTab == item
                Button {
                    runtime.settingsTab = item
                } label: {
                    Text(item.title.uppercased())
                        .font(.atlasMono(7.5, .regular))
                        .tracking(7.5 * 0.09)
                        .foregroundColor(active ? accent.color : dim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(active ? accent.opacity(0.075) : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(active ? accent.opacity(0.12) : .clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(AtlasPlainButtonStyle())
                .accessibilityLabel("\(item.title) settings")
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(insetFill(0.32)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ink.opacity(0.062), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { dividerLine }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionKicker(title: "Source", value: runtime.isLiveSource ? "live" : "demo")

            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(runtime.isLiveSource ? Palette.signal.color : accent.color)
                    .frame(width: 7, height: 7)
                    .shadow(color: (runtime.isLiveSource ? Palette.signal : accent).opacity(0.55), radius: 5)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(runtime.isLiveSource ? "Pi-hole live" : "Demo source")
                        .font(.atlasSans(10.5, .medium))
                        .foregroundColor(ink2)
                    Text(runtime.isLiveSource
                         ? "\(runtime.sourceEndpoint ?? "Pi-hole") · polling every 1.5 s"
                         : "Deterministic local traffic. Connect a Pi-hole to replace it.")
                        .font(.atlasSans(8.5, .regular))
                        .lineSpacing(1.5)
                        .foregroundColor(dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 6).fill(insetFill(0.32)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ink.opacity(0.062), lineWidth: 1))
            .padding(.top, 10)

            if runtime.sourceConnecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(accent.color)
                    Text("Connecting to Pi-hole…")
                        .font(.atlasSans(10, .regular))
                        .foregroundColor(muted)
                }
                .padding(.top, 12)
            }

            if let error = runtime.sourceError, !error.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(warn.color)
                        .padding(.top, 2)
                    Text(error)
                        .font(.atlasSans(9.5, .regular))
                        .lineSpacing(1.5)
                        .foregroundColor(warn.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 5).fill(warn.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(warn.opacity(0.2), lineWidth: 1))
                .padding(.top, 10)
            }

            if let notice = runtime.sourceNotice, !notice.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "key.slash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(accent.color)
                        .padding(.top, 2)
                    Text(notice)
                        .font(.atlasSans(9.2, .regular))
                        .lineSpacing(1.5)
                        .foregroundColor(muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 5).fill(accent.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(accent.opacity(0.16), lineWidth: 1))
                .padding(.top, 10)
            }

            if runtime.isLiveSource {
                liveSourceDetails
            } else {
                demoSourceForm
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "lock")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(dim)
                    .padding(.top, 1)
                Text(runtime.isLiveSource
                     ? (runtime.hasSavedPassword
                        ? "Read-only: Atlas imports queries and never writes to Pi-hole. The API password stays in the login Keychain."
                        : "Read-only: Atlas imports queries and never writes to Pi-hole. The API password is held only for this session.")
                     : (runtime.hasSavedPassword
                        ? "The demo source is local and deterministic. A Pi-hole password is saved in the login Keychain for the next connection."
                        : "The demo source is local and deterministic. Live credentials are only requested when you connect."))
                    .font(.atlasSans(9.2, .regular))
                    .lineSpacing(1.6)
                    .foregroundColor(dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)
            .padding(.bottom, 2)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { dividerLine }
    }

    private var demoSourceForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            sourceField("Pi-hole URL", text: $sourceURL, placeholder: "https://pi.hole")
            sourceField("API password", text: $sourcePassword, placeholder: runtime.hasSavedPassword ? "Saved in Keychain — leave blank to keep" : "Pi-hole API password", secure: true)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Self-signed certificate")
                        .font(.atlasSans(10, .medium))
                        .foregroundColor(ink2)
                    Text("allow a local HTTPS Pi-hole certificate")
                        .font(.atlasSans(8.4, .regular))
                        .foregroundColor(dim)
                }
                Spacer()
                TinyToggle(isOn: $sourceInsecure, label: "Allow self-signed certificate", tone: accent)
            }
            Button {
                runtime.connectPiHole(url: sourceURL, password: sourcePassword, insecure: sourceInsecure)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 11, weight: .medium))
                    Text("CONNECT LIVE")
                        .font(.atlasMono(9.5, .medium))
                        .tracking(0.7)
                }
                .foregroundColor(sourceURL.trimmingCharacters(in: .whitespaces).isEmpty ? faint : Palette.deep.color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(sourceURL.trimmingCharacters(in: .whitespaces).isEmpty
                          ? ink.opacity(0.04)
                          : accent.opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(accent.opacity(sourceURL.trimmingCharacters(in: .whitespaces).isEmpty ? 0.08 : 0.5), lineWidth: 1))
            }
            .buttonStyle(AtlasPlainButtonStyle())
            .disabled(sourceURL.trimmingCharacters(in: .whitespaces).isEmpty || runtime.sourceConnecting)
            .accessibilityHint("Connects read-only to the Pi-hole v6 API")
        }
        .padding(.top, 12)
    }

    private var liveSourceDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("SNAPSHOT")
                    .font(.atlasMono(7, .regular))
                    .tracking(7 * 0.08)
                    .foregroundColor(faint)
                Spacer()
                Text(runtime.sourceSnapshotWindow ?? "6 hours")
                    .font(.atlasMono(8, .regular))
                    .foregroundColor(ink2)
            }
            HStack(spacing: 8) {
                Text("SELECTED")
                    .font(.atlasMono(7, .regular))
                    .tracking(7 * 0.08)
                    .foregroundColor(faint)
                Spacer()
                Text("\(Format.compact(runtime.network.devices.count)) devices · \(Format.compact(runtime.network.destinations.count)) destinations")
                    .font(.atlasMono(8, .regular))
                    .foregroundColor(ink2)
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("POPULATION")
                        .font(.atlasMono(7, .regular))
                        .tracking(7 * 0.08)
                        .foregroundColor(faint)
                    Spacer()
                    Text(runtime.livePopulation.title.uppercased())
                        .font(.atlasMono(8, .regular))
                        .foregroundColor(accent.color)
                }
                HStack(spacing: 1) {
                    ForEach(LivePopulation.allCases) { population in
                        SegmentButton(title: population.title,
                                      active: runtime.livePopulation == population) {
                            runtime.setLivePopulation(population)
                        }
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 5).fill(insetFill(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ink.opacity(0.062), lineWidth: 1))
                Text(runtime.livePopulation.detail)
                    .font(.atlasSans(8.2, .regular))
                    .foregroundColor(dim)
                    .fixedSize(horizontal: false, vertical: true)
                Text("History playback reads the selected range from the on-disk query database and keeps the current graph.")
                    .font(.atlasSans(8.2, .regular))
                    .foregroundColor(dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
            HStack(spacing: 5) {
                MiniActionButton(title: "Refresh", accent: accent) { runtime.refreshLiveSource() }
                MiniActionButton(title: "Use demo", accent: accent) { runtime.useDemoSource() }
                MiniActionButton(title: "Disconnect", danger: true, accent: accent, dangerTone: warn) { runtime.disconnectPiHole() }
            }
            .padding(.top, 2)
        }
        .padding(.top, 12)
    }

    private func sourceField(_ label: String, text: Binding<String>,
                             placeholder: String, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.atlasSans(9.4, .medium))
                .foregroundColor(ink2)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.atlasSans(10.5, .regular))
            .foregroundColor(ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 5).fill(insetFill(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ink.opacity(0.1), lineWidth: 1))
            .disableAutocorrection(true)
            .accessibilityLabel(label)
        }
    }

    private var hostSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionKicker(title: "Host traffic",
                          value: runtime.hostDemoActive ? "demo" : (runtime.hostAvailable ? "live" : "unavailable"),
                          color: Palette.hostMuted.color, valueColor: Palette.hostFaint.color)
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(runtime.hostAvailable ? Palette.host.color : warn.color)
                    .frame(width: 7, height: 7)
                    .shadow(color: (runtime.hostAvailable ? Palette.host : warn).opacity(0.55), radius: 5)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text("This Mac")
                        .font(.atlasSans(11.5, .medium))
                        .foregroundColor(Palette.hostText.color)
                    Text("\(Format.dataRate(runtime.hostSnapshot.rxPerSecond)) in · \(Format.dataRate(runtime.hostSnapshot.txPerSecond)) out · \(runtime.hostSnapshot.apps.count) apps · \(runtime.hostSnapshot.domains.count) remotes")
                        .font(.atlasMono(6.8, .regular))
                        .foregroundColor(Palette.hostMeta.color)
                        .lineLimit(2)
                    if let note = runtime.hostNote {
                        Text(note)
                            .font(.atlasSans(8.5, .regular))
                            .foregroundColor(warn.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 8)

            Text("Reads this Mac's own socket counters. No packet capture, no payloads, no history. It never reads another device's traffic.")
                .font(.atlasSans(9, .regular))
                .lineSpacing(2)
                .foregroundColor(Palette.hostMuted.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Host monitoring")
                        .font(.atlasSans(10.5, .medium))
                        .foregroundColor(Palette.hostText2.color)
                    Text(runtime.hostPaused ? "paused; existing bodies stay on screen" : "samples nettop once a second")
                        .font(.atlasSans(8.5, .regular))
                        .foregroundColor(Palette.hostMeta.color)
                }
                Spacer()
                TinyToggle(isOn: Binding(get: { !runtime.hostPaused },
                                         set: { runtime.setHostPaused(!$0) }),
                           label: "Host monitoring", tone: accent)
            }
            .padding(.vertical, 8)

            Text("Scope")
                .font(.atlasSans(10.5, .medium))
                .foregroundColor(Palette.hostText2.color)
                .padding(.top, 6)
            ForEach(HostScope.allCases) { scope in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scope.title)
                            .font(.atlasSans(9.5, .regular))
                            .foregroundColor(Palette.hostText2.color)
                        Text(scopeDetail(scope))
                            .font(.atlasSans(8, .regular))
                            .foregroundColor(Palette.hostMeta.color)
                    }
                    Spacer()
                    TinyToggle(isOn: Binding(get: { runtime.hostScopes.contains(scope) },
                                             set: { runtime.setHostScope(scope, enabled: $0) }),
                               label: "\(scope.title) traffic", tone: accent)
                }
                .padding(.vertical, 5)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Domain names")
                    .font(.atlasSans(10.5, .medium))
                    .foregroundColor(Palette.hostText2.color)
                Text(runtime.isLiveSource
                     ? (runtime.hostDomainStatus ?? "Pi-hole dnsmasq log is the source of exact answer IPs. Unmatched endpoints stay IP:port.")
                     : "Connect a live Pi-hole to infer domain names. Host traffic still works without it, by IP:port.")
                    .font(.atlasSans(8.5, .regular))
                    .lineSpacing(2)
                    .foregroundColor(runtime.hostDomainStatus == nil ? Palette.hostMeta.color : Palette.hostFault.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)

        }
        .padding(.top, 12)
    }

    private func scopeDetail(_ scope: HostScope) -> String {
        switch scope {
        case .internet: return "public remote addresses"
        case .lan: return "private and link-local peers"
        case .vpn: return "100.64/10 and tunnel ranges"
        case .loopback: return "local IPC, exposed and counted twice"
        }
    }

    private var hostDisplaySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionKicker(title: "Display", value: "host globe",
                          color: Palette.hostMuted.color, valueColor: Palette.hostFaint.color)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto orbit")
                        .font(.atlasSans(10.5, .medium))
                        .foregroundColor(ink2)
                    Text("coast the camera when idle (O)")
                        .font(.atlasSans(8.5, .regular))
                        .foregroundColor(dim)
                }
                Spacer()
                TinyToggle(isOn: Binding(get: { runtime.spinEnabled },
                                         set: { runtime.setSpin($0) }),
                           label: "Auto-orbit", tone: accent)
            }
            .padding(.vertical, 7)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Window drag spins globe")
                        .font(.atlasSans(10.5, .medium))
                        .foregroundColor(ink2)
                    Text(runtime.windowDragSpinsGlobe
                         ? "moving the window orbits the field"
                         : "off: moving the window leaves the field still")
                        .font(.atlasSans(8.5, .regular))
                        .foregroundColor(dim)
                }
                Spacer()
                TinyToggle(isOn: Binding(get: { runtime.windowDragSpinsGlobe },
                                         set: { runtime.setWindowDragSpinsGlobe($0) }),
                           label: "Window drag spins globe", tone: accent)
            }
            .padding(.vertical, 7)

            VStack(alignment: .leading, spacing: 0) {
                Text("Labels")
                    .font(.atlasSans(10.5, .medium))
                    .foregroundColor(ink2)
                Text("brief labels on selection, all host bodies, or never")
                    .font(.atlasSans(8.5, .regular))
                    .foregroundColor(dim)
                    .padding(.top, 2)
                HStack(spacing: 1) {
                    ForEach(LabelMode.allCases, id: \.self) { mode in
                        SegmentButton(title: mode.rawValue, active: runtime.labelMode == mode,
                                      accent: accent, inactive: inactiveTone, activeText: accent) {
                            runtime.setLabelMode(mode)
                        }
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 5).fill(insetFill(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ink.opacity(0.062), lineWidth: 1))
                .padding(.top, 7)
            }
            .padding(.vertical, 7)

            Text("HOST is live only. There is no history window, replay transport or alias editor in this mode; the field always reflects this Mac's current sockets.")
                .font(.atlasSans(8.5, .regular))
                .lineSpacing(2)
                .foregroundColor(faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .padding(.top, 12)
    }

    private var fieldSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionKicker(title: "Display", value: "globe")
            WindowControl(runtime: runtime, metrics: metrics)
                .padding(.vertical, 4)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto orbit")
                        .font(.atlasSans(10.5, .medium))
                        .foregroundColor(ink2)
                    Text("coast the camera when idle (O)")
                        .font(.atlasSans(8.5, .regular))
                        .foregroundColor(dim)
                }
                Spacer()
                TinyToggle(isOn: Binding(get: { runtime.spinEnabled }, set: { runtime.setSpin($0) }), label: "Auto-orbit", tone: accent)
            }
            .padding(.vertical, 7)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Window drag spins globe")
                        .font(.atlasSans(10.5, .medium))
                        .foregroundColor(ink2)
                    Text(runtime.windowDragSpinsGlobe
                         ? "moving the window orbits the field"
                         : "off: moving the window leaves the field still")
                        .font(.atlasSans(8.5, .regular))
                        .foregroundColor(dim)
                }
                Spacer()
                TinyToggle(isOn: Binding(get: { runtime.windowDragSpinsGlobe },
                                         set: { runtime.setWindowDragSpinsGlobe($0) }),
                           label: "Window drag spins globe", tone: accent)
            }
            .padding(.vertical, 7)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show domain with alias")
                        .font(.atlasSans(10.5, .medium))
                        .foregroundColor(ink2)
                    Text(runtime.showAliasWithAddress
                         ? "destination cards show the alias plus the original domain"
                         : "destination cards show only the alias, or the domain when unset")
                        .font(.atlasSans(8.5, .regular))
                        .foregroundColor(dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                TinyToggle(isOn: Binding(get: { runtime.showAliasWithAddress },
                                         set: { runtime.setShowAliasWithAddress($0) }),
                           label: "Show domain with alias", tone: accent)
            }
            .padding(.vertical, 7)

            VStack(alignment: .leading, spacing: 0) {
                Text("Labels")
                    .font(.atlasSans(10.5, .medium))
                    .foregroundColor(ink2)
                Text("brief labels on events, selection, all, or never")
                    .font(.atlasSans(8.5, .regular))
                    .foregroundColor(dim)
                    .padding(.top, 2)
                HStack(spacing: 1) {
                    ForEach(LabelMode.allCases, id: \.self) { mode in
                        SegmentButton(title: mode.rawValue, active: runtime.labelMode == mode,
                                      accent: accent, inactive: inactiveTone, activeText: accent) {
                            runtime.setLabelMode(mode)
                        }
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 5).fill(insetFill(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ink.opacity(0.062), lineWidth: 1))
                .padding(.top, 7)
            }
            .padding(.vertical, 7)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { dividerLine }
    }

    private var motionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionKicker(title: "Motion", value: "lab")
            VStack(alignment: .leading, spacing: 0) {
                Text("Response")
                    .font(.atlasSans(10.5, .medium))
                    .foregroundColor(ink2)
                Text("the study played when a query lands")
                    .font(.atlasSans(8.5, .regular))
                    .foregroundColor(dim)
                    .padding(.top, 2)
                HStack(spacing: 1) {
                    ForEach(MotionMode.allCases, id: \.self) { mode in
                        SegmentButton(title: mode.rawValue, active: runtime.motionMode == mode,
                                      accent: accent, inactive: inactiveTone, activeText: accent) {
                            runtime.setMotionMode(mode)
                        }
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 5).fill(insetFill(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ink.opacity(0.062), lineWidth: 1))
                .padding(.top, 7)
            }
            .padding(.vertical, 7)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Node recoil")
                        .font(.atlasSans(10.5, .medium))
                        .foregroundColor(ink2)
                    Text("allowed destinations take the blast as a knockback")
                        .font(.atlasSans(8.5, .regular))
                        .foregroundColor(dim)
                }
                Spacer()
                TinyToggle(isOn: Binding(get: { runtime.recoilEnabled }, set: { runtime.setRecoil($0) }), label: "Node recoil", tone: accent)
            }
            .padding(.vertical, 7)

            VStack(alignment: .leading, spacing: 0) {
                Text("Study speed")
                    .font(.atlasSans(10.5, .medium))
                    .foregroundColor(ink2)
                Text("slow the motion studies down without leaving the field")
                    .font(.atlasSans(8.5, .regular))
                    .foregroundColor(dim)
                    .padding(.top, 2)
                HStack(spacing: 1) {
                    ForEach([Float(0.25), 0.5, 1, 2, 4], id: \.self) { value in
                        SegmentButton(title: speedLabel(value), active: runtime.speed == value,
                                      accent: accent, inactive: inactiveTone, activeText: accent) {
                            runtime.setSpeed(value)
                        }
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 5).fill(insetFill(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ink.opacity(0.062), lineWidth: 1))
                .padding(.top, 7)
            }
            .padding(.vertical, 7)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto tour")
                        .font(.atlasSans(10.5, .medium))
                        .foregroundColor(ink2)
                    Text("loop emergence → impact on one node (T)")
                        .font(.atlasSans(8.5, .regular))
                        .foregroundColor(dim)
                }
                Spacer()
                TinyToggle(isOn: Binding(get: { runtime.autoTour }, set: { runtime.setAutoTour($0) }), label: "Auto tour", tone: accent)
            }
            .padding(.vertical, 7)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hit plane")
                        .font(.atlasSans(10.5, .medium))
                        .foregroundColor(ink2)
                    Text("overlay the perpendicular blast plane")
                        .font(.atlasSans(8.5, .regular))
                        .foregroundColor(dim)
                }
                Spacer()
                TinyToggle(isOn: Binding(get: { runtime.showHitGeometry },
                                         set: { runtime.setShowHitGeometry($0) }), label: "Hit plane", tone: accent)
            }
            .padding(.vertical, 7)

            if let study = runtime.studyTelemetry {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Study plane")
                            .font(.atlasSans(10.5, .medium))
                            .foregroundColor(ink2)
                        Spacer()
                        Text(study.impactName.uppercased())
                            .font(.atlasMono(6.8, .regular))
                            .tracking(6.8 * 0.08)
                            .foregroundColor(study.blocked ? warn.color : accent.color)
                    }
                    Text("\(study.host) · face-on \(String(format: "%.0f", study.faceAngle))°")
                        .font(.atlasMono(7, .regular))
                        .foregroundColor(dim)
                    telemetryLine("Inbound", study.inboundText)
                    telemetryLine("Axis", study.axisText)
                    telemetryLine("Centre", study.centreText)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 5).fill(insetFill(0.4)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ink.opacity(0.062), lineWidth: 1))
                .padding(.vertical, 7)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("Preview a study")
                    .font(.atlasSans(10.5, .medium))
                    .foregroundColor(ink2)
                Text("the selected destination, or the busiest one")
                    .font(.atlasSans(8.5, .regular))
                    .foregroundColor(dim)
                    .padding(.top, 2)
                HStack(spacing: 5) {
                    MiniActionButton(title: "Impact", accent: accent) { runtime.previewMotion("impact") }
                    MiniActionButton(title: "Emergence", accent: accent) { runtime.previewMotion("birth") }
                    MiniActionButton(title: "Erasure", danger: true, accent: accent, dangerTone: warn) { runtime.previewMotion("death") }
                }
                .padding(.top, 7)
            }
            .padding(.vertical, 7)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { dividerLine }
    }

    private func speedLabel(_ value: Float) -> String {
        switch value {
        case 0.25: return "¼×"
        case 0.5: return "½×"
        default: return "\(Int(value))×"
        }
    }

    private func telemetryLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.atlasMono(6.4, .regular))
                .tracking(6.4 * 0.08)
                .foregroundColor(faint)
                .frame(width: 42, alignment: .leading)
            Text(value)
                .font(.atlasMono(7.2, .regular))
                .foregroundColor(muted)
                .lineLimit(1)
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionKicker(title: "About", value: "v1.0")
            BrandLockup(height: 52, host: hostMode)
                .padding(.top, 9)
            Text(hostMode
                 ? "Apps on the shell, remotes inside, byte flow both ways. All traffic stays on this machine."
                 : "Devices on the shell, destinations inside, relationships in signal blue. All traffic stays on this machine.")
                .font(.atlasSans(9.4, .regular))
                .lineSpacing(1.5)
                .foregroundColor(dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            WychoiCredit()
                .padding(.top, 11)
        }
        .padding(.vertical, 13)
    }

    private var foot: some View {
        HStack(spacing: 7) {
            Circle().fill(okay.color).frame(width: 4, height: 4)
                .shadow(color: okay.opacity(0.8), radius: 3)
            Text(hostMode
                 ? (runtime.hostDemoActive
                    ? "THIS MAC · DEMO SAMPLE · NO HISTORY"
                    : (runtime.hostPaused ? "THIS MAC · PAUSED · MONITOR RUNNING"
                                          : "THIS MAC · LIVE SOCKETS · NO HISTORY"))
                 : (runtime.isLiveSource
                    ? (runtime.hasSavedPassword ? "PI-HOLE LIVE · READ-ONLY · KEYCHAIN"
                                               : "PI-HOLE LIVE · READ-ONLY · SESSION")
                    : "DEMO STREAM · NO TELEMETRY · LOCAL ONLY"))
                .font(.atlasMono(6.4, .regular))
                .tracking(6.4 * 0.07)
                .foregroundColor(faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { dividerLine }
    }
}
