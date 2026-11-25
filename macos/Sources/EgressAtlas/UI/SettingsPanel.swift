import SwiftUI

struct SettingsPanel: View {
    @ObservedObject var runtime: AtlasRuntime
    let metrics: Metrics
    @State private var sourceURL = ""
    @State private var sourcePassword = ""
    @State private var sourceInsecure = false
    @State private var sourceFieldsLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    switch runtime.settingsTab {
                    case .source: sourceSection
                    case .display: fieldSection
                    case .motion: motionSection
                    case .host: hostSection
                    case .about: aboutSection
                    }
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
        .background(Palette.deep.color.opacity(0.985))
        .background(WarmGlass(radius: 12, strong: true))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.text.opacity(0.11), lineWidth: 1))
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

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Eyebrow(text: "Atlas settings", size: 8, color: Palette.muted.color, trackingEm: 0.16)
                Text("Settings")
                    .font(.atlasSans(22, .medium))
                    .tracking(-22 * 0.03)
                    .foregroundColor(Palette.text.color)
            }
            Spacer()
            Button {
                runtime.settingsOpen = false
            } label: {
                CloseGlyph(size: 12, color: Palette.muted.color)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.rgba("090503", 0.28)))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Palette.text.opacity(0.062), lineWidth: 1))
            }
            .buttonStyle(AtlasPlainButtonStyle())
        }
        .padding(.horizontal, 15)
        .padding(.top, 15)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { item in
                let active = runtime.settingsTab == item
                Button {
                    runtime.settingsTab = item
                } label: {
                    Text(item.title.uppercased())
                        .font(.atlasMono(7.5, .regular))
                        .tracking(7.5 * 0.09)
                        .foregroundColor(active ? Palette.gold.color : Palette.dim.color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(active ? Palette.gold.opacity(0.075) : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(active ? Palette.gold.opacity(0.12) : .clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(AtlasPlainButtonStyle())
                .accessibilityLabel("\(item.title) settings")
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.rgba("090503", 0.32)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.text.opacity(0.062), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionKicker(title: "Source", value: runtime.isLiveSource ? "live" : "demo")

            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(runtime.isLiveSource ? Palette.signal.color : Palette.gold.color)
                    .frame(width: 7, height: 7)
                    .shadow(color: (runtime.isLiveSource ? Palette.signal : Palette.gold).opacity(0.55), radius: 5)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(runtime.isLiveSource ? "Pi-hole live" : "Demo source")
                        .font(.atlasSans(10.5, .medium))
                        .foregroundColor(Palette.text2.color)
                    Text(runtime.isLiveSource
                         ? "\(runtime.sourceEndpoint ?? "Pi-hole") · polling every 1.5 s"
                         : "Deterministic local traffic. Connect a Pi-hole to replace it.")
                        .font(.atlasSans(8.5, .regular))
                        .lineSpacing(1.5)
                        .foregroundColor(Palette.dim.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.rgba("080503", 0.32)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.text.opacity(0.062), lineWidth: 1))
            .padding(.top, 10)

            if runtime.sourceConnecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Palette.gold.color)
                    Text("Connecting to Pi-hole…")
                        .font(.atlasSans(10, .regular))
                        .foregroundColor(Palette.muted.color)
                }
                .padding(.top, 12)
            }

            if let error = runtime.sourceError, !error.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Palette.coral.color)
                        .padding(.top, 2)
                    Text(error)
                        .font(.atlasSans(9.5, .regular))
                        .lineSpacing(1.5)
                        .foregroundColor(Palette.coral.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 5).fill(Palette.coral.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.coral.opacity(0.2), lineWidth: 1))
                .padding(.top, 10)
            }

            if let notice = runtime.sourceNotice, !notice.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "key.slash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Palette.gold.color)
                        .padding(.top, 2)
                    Text(notice)
                        .font(.atlasSans(9.2, .regular))
                        .lineSpacing(1.5)
                        .foregroundColor(Palette.muted.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 5).fill(Palette.gold.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.gold.opacity(0.16), lineWidth: 1))
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
                    .foregroundColor(Palette.dim.color)
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
                    .foregroundColor(Palette.dim.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)
            .padding(.bottom, 2)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var demoSourceForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            sourceField("Pi-hole URL", text: $sourceURL, placeholder: "https://pi.hole")
            sourceField("API password", text: $sourcePassword, placeholder: runtime.hasSavedPassword ? "Saved in Keychain — leave blank to keep" : "Pi-hole API password", secure: true)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Self-signed certificate")
                        .font(.atlasSans(10, .medium))
                        .foregroundColor(Palette.text2.color)
                    Text("allow a local HTTPS Pi-hole certificate")
                        .font(.atlasSans(8.4, .regular))
                        .foregroundColor(Palette.dim.color)
                }
                Spacer()
                TinyToggle(isOn: $sourceInsecure, label: "Allow self-signed certificate")
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
                .foregroundColor(sourceURL.trimmingCharacters(in: .whitespaces).isEmpty ? Palette.faint.color : Palette.deep.color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(sourceURL.trimmingCharacters(in: .whitespaces).isEmpty
                          ? Palette.text.opacity(0.04)
                          : Palette.gold.opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Palette.gold.opacity(sourceURL.trimmingCharacters(in: .whitespaces).isEmpty ? 0.08 : 0.5), lineWidth: 1))
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
                    .foregroundColor(Palette.faint.color)
                Spacer()
                Text(runtime.sourceSnapshotWindow ?? "6 hours")
                    .font(.atlasMono(8, .regular))
                    .foregroundColor(Palette.text2.color)
            }
            HStack(spacing: 8) {
                Text("SELECTED")
                    .font(.atlasMono(7, .regular))
                    .tracking(7 * 0.08)
                    .foregroundColor(Palette.faint.color)
                Spacer()
                Text("\(Format.compact(runtime.network.devices.count)) devices · \(Format.compact(runtime.network.destinations.count)) destinations")
                    .font(.atlasMono(8, .regular))
                    .foregroundColor(Palette.text2.color)
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("POPULATION")
                        .font(.atlasMono(7, .regular))
                        .tracking(7 * 0.08)
                        .foregroundColor(Palette.faint.color)
                    Spacer()
                    Text(runtime.livePopulation.title.uppercased())
                        .font(.atlasMono(8, .regular))
                        .foregroundColor(Palette.gold.color)
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
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.rgba("090503", 0.35)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.text.opacity(0.062), lineWidth: 1))
                Text(runtime.livePopulation.detail)
                    .font(.atlasSans(8.2, .regular))
                    .foregroundColor(Palette.dim.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text("History playback reads the selected range from the on-disk query database and keeps the current graph.")
                    .font(.atlasSans(8.2, .regular))
                    .foregroundColor(Palette.dim.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
            HStack(spacing: 5) {
                MiniActionButton(title: "Refresh") { runtime.refreshLiveSource() }
                MiniActionButton(title: "Use demo") { runtime.useDemoSource() }
                MiniActionButton(title: "Disconnect", danger: true) { runtime.disconnectPiHole() }
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
                .foregroundColor(Palette.text2.color)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.atlasSans(10.5, .regular))
            .foregroundColor(Palette.text.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.rgba("080503", 0.5)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.text.opacity(0.1), lineWidth: 1))
            .disableAutocorrection(true)
            .accessibilityLabel(label)
        }
    }

    private var hostSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionKicker(title: "Host traffic", value: runtime.hostAvailable ? "live" : "unavailable")
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(runtime.hostAvailable ? Palette.host.color : Palette.coral.color)
                    .frame(width: 7, height: 7)
                    .shadow(color: (runtime.hostAvailable ? Palette.host : Palette.coral).opacity(0.55), radius: 5)
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
                            .foregroundColor(Palette.coral.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 8)

            Text("Reads this Mac's own socket counters. No packet capture, no payloads, no history. It never contacts this Mac's traffic.")
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
                    Text(runtime.hostPaused ? "paused; existing bodies stay on screen" : "samples netstat once a second")
                        .font(.atlasSans(8.5, .regular))
                        .foregroundColor(Palette.hostMeta.color)
                }
                Spacer()
                TinyToggle(isOn: Binding(get: { !runtime.hostPaused },
                                         set: { runtime.setHostPaused(!$0) }),
                           label: "Host monitoring")
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
                               label: "\(scope.title) traffic")
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

    private var fieldSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionKicker(title: "Display", value: "globe")
            WindowControl(runtime: runtime, metrics: metrics)
                .padding(.vertical, 4)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto orbit")
                        .font(.atlasSans(10.5, .medium))
                        .foregroundColor(Palette.text2.color)
                    Text("coast the camera when idle (O)")
                        .font(.atlasSans(8.5, .regular))
                        .foregroundColor(Palette.dim.color)
                }
                Spacer()
                TinyToggle(isOn: Binding(get: { runtime.spinEnabled }, set: { runtime.setSpin($0) }), label: "Auto-orbit")
            }
            .padding(.vertical, 7)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Window drag spins globe")
                        .font(.atlasSans(10.5, .medium))
                        .foregroundColor(Palette.text2.color)
                    Text(runtime.windowDragSpinsGlobe
                         ? "moving the window orbits the field"
                         : "off: moving the window leaves the field still")
                        .font(.atlasSans(8.5, .regular))
                        .foregroundColor(Palette.dim.color)
                }
                Spacer()
                TinyToggle(isOn: Binding(get: { runtime.windowDragSpinsGlobe },
                                         set: { runtime.setWindowDragSpinsGlobe($0) }),
                           label: "Window drag spins globe")
            }
            .padding(.vertical, 7)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show domain with alias")
                        .font(.atlasSans(10.5, .medium))
                        .foregroundColor(Palette.text2.color)
                    Text(runtime.showAliasWithAddress
                         ? "destination cards show the alias plus the original domain"
                         : "destination cards show only the alias, or the domain when unset")
                        .font(.atlasSans(8.5, .regular))
                        .foregroundColor(Palette.dim.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                TinyToggle(isOn: Binding(get: { runtime.showAliasWithAddress },
                                         set: { runtime.setShowAliasWithAddress($0) }),
                           label: "Show domain with alias")
            }
            .padding(.vertical, 7)

            VStack(alignment: .leading, spacing: 0) {
                Text("Labels")
                    .font(.atlasSans(10.5, .medium))
                    .foregroundColor(Palette.text2.color)
                Text("brief labels on events, selection, or never")
                    .font(.atlasSans(8.5, .regular))
                    .foregroundColor(Palette.dim.color)
                    .padding(.top, 2)
                HStack(spacing: 1) {
                    ForEach(LabelMode.allCases, id: \.self) { mode in
                        SegmentButton(title: mode.rawValue, active: runtime.labelMode == mode) {
                            runtime.setLabelMode(mode)
                        }
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.rgba("090503", 0.35)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.text.opacity(0.062), lineWidth: 1))
                .padding(.top, 7)
            }
            .padding(.vertical, 7)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var motionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionKicker(title: "Motion", value: "lab")
            VStack(alignment: .leading, spacing: 0) {
                Text("Response")
                    .font(.atlasSans(10.5, .medium))
                    .foregroundColor(Palette.text2.color)
                Text("the study played when a query lands")
                    .font(.atlasSans(8.5, .regular))
                    .foregroundColor(Palette.dim.color)
                    .padding(.top, 2)
                HStack(spacing: 1) {
                    ForEach(MotionMode.allCases, id: \.self) { mode in
                        SegmentButton(title: mode.rawValue, active: runtime.motionMode == mode) {
                            runtime.setMotionMode(mode)
                        }
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.rgba("090503", 0.35)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.text.opacity(0.062), lineWidth: 1))
                .padding(.top, 7)
            }
            .padding(.vertical, 7)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Node recoil")
                        .font(.atlasSans(10.5, .medium))
                        .foregroundColor(Palette.text2.color)
                    Text("allowed destinations take the blast as a knockback")
                        .font(.atlasSans(8.5, .regular))
                        .foregroundColor(Palette.dim.color)
                }
                Spacer()
                TinyToggle(isOn: Binding(get: { runtime.recoilEnabled }, set: { runtime.setRecoil($0) }), label: "Node recoil")
            }
            .padding(.vertical, 7)

            VStack(alignment: .leading, spacing: 0) {
                Text("Study speed")
                    .font(.atlasSans(10.5, .medium))
                    .foregroundColor(Palette.text2.color)
                Text("slow the motion studies down without leaving the field")
                    .font(.atlasSans(8.5, .regular))
                    .foregroundColor(Palette.dim.color)
                    .padding(.top, 2)
                HStack(spacing: 1) {
                    ForEach([Float(0.25), 0.5, 1, 2, 4], id: \.self) { value in
                        SegmentButton(title: speedLabel(value), active: runtime.speed == value) {
                            runtime.setSpeed(value)
                        }
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.rgba("090503", 0.35)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.text.opacity(0.062), lineWidth: 1))
                .padding(.top, 7)
            }
            .padding(.vertical, 7)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto tour")
                        .font(.atlasSans(10.5, .medium))
                        .foregroundColor(Palette.text2.color)
                    Text("loop emergence → impact on one node (T)")
                        .font(.atlasSans(8.5, .regular))
                        .foregroundColor(Palette.dim.color)
                }
                Spacer()
                TinyToggle(isOn: Binding(get: { runtime.autoTour }, set: { runtime.setAutoTour($0) }), label: "Auto tour")
            }
            .padding(.vertical, 7)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hit plane")
                        .font(.atlasSans(10.5, .medium))
                        .foregroundColor(Palette.text2.color)
                    Text("overlay the perpendicular blast plane")
                        .font(.atlasSans(8.5, .regular))
                        .foregroundColor(Palette.dim.color)
                }
                Spacer()
                TinyToggle(isOn: Binding(get: { runtime.showHitGeometry },
                                         set: { runtime.setShowHitGeometry($0) }), label: "Hit plane")
            }
            .padding(.vertical, 7)

            if let study = runtime.studyTelemetry {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Study plane")
                            .font(.atlasSans(10.5, .medium))
                            .foregroundColor(Palette.text2.color)
                        Spacer()
                        Text(study.impactName.uppercased())
                            .font(.atlasMono(6.8, .regular))
                            .tracking(6.8 * 0.08)
                            .foregroundColor(study.blocked ? Palette.coral.color : Palette.gold.color)
                    }
                    Text("\(study.host) · face-on \(String(format: "%.0f", study.faceAngle))°")
                        .font(.atlasMono(7, .regular))
                        .foregroundColor(Palette.dim.color)
                    telemetryLine("Inbound", study.inboundText)
                    telemetryLine("Axis", study.axisText)
                    telemetryLine("Centre", study.centreText)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.rgba("080503", 0.4)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.text.opacity(0.062), lineWidth: 1))
                .padding(.vertical, 7)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("Preview a study")
                    .font(.atlasSans(10.5, .medium))
                    .foregroundColor(Palette.text2.color)
                Text("the selected destination, or the busiest one")
                    .font(.atlasSans(8.5, .regular))
                    .foregroundColor(Palette.dim.color)
                    .padding(.top, 2)
                HStack(spacing: 5) {
                    MiniActionButton(title: "Impact") { runtime.previewMotion("impact") }
                    MiniActionButton(title: "Emergence") { runtime.previewMotion("birth") }
                    MiniActionButton(title: "Erasure", danger: true) { runtime.previewMotion("death") }
                }
                .padding(.top, 7)
            }
            .padding(.vertical, 7)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Hairline() }
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
                .foregroundColor(Palette.faint.color)
                .frame(width: 42, alignment: .leading)
            Text(value)
                .font(.atlasMono(7.2, .regular))
                .foregroundColor(Palette.muted.color)
                .lineLimit(1)
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionKicker(title: "About", value: "v1.0")
            BrandLockup(height: 52)
                .padding(.top, 9)
            Text("Devices on the shell, destinations inside, relationships in signal blue. All traffic stays on this machine.")
                .font(.atlasSans(9.4, .regular))
                .lineSpacing(1.5)
                .foregroundColor(Palette.dim.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            WychoiCredit()
                .padding(.top, 11)
        }
        .padding(.vertical, 13)
    }

    private var foot: some View {
        HStack(spacing: 7) {
            Circle().fill(Palette.sage.color).frame(width: 4, height: 4)
                .shadow(color: Palette.sage.opacity(0.8), radius: 3)
            Text(runtime.isLiveSource
                 ? (runtime.hasSavedPassword ? "PI-HOLE LIVE · READ-ONLY · KEYCHAIN"
                                            : "PI-HOLE LIVE · READ-ONLY · SESSION")
                 : "DEMO STREAM · NO TELEMETRY · LOCAL ONLY")
                .font(.atlasMono(6.4, .regular))
                .tracking(6.4 * 0.07)
                .foregroundColor(Palette.faint.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Hairline() }
    }
}
