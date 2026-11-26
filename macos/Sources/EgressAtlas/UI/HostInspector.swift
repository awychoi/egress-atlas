import SwiftUI

// MARK: - Inspector

struct HostInspectorPanel: View {
    @ObservedObject var runtime: AtlasRuntime
    let selection: HostSelection
    let metrics: Metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow(text: "Inspector", size: 7.5, color: Palette.host.color, trackingEm: 0.14)
                Spacer()
                Button { runtime.clearHostSelection() } label: {
                    Text("CLOSE")
                        .font(.atlasMono(6.5, .regular))
                        .tracking(0.4)
                        .foregroundColor(Palette.hostMeta.color)
                }
                .buttonStyle(AtlasPlainButtonStyle())
            }
            .padding(.horizontal, 15)
            .padding(.top, 16)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if let app = appContent {
                        app
                    } else if let domain = domainContent {
                        domain
                    } else {
                        Text("Selection no longer present.")
                            .font(.atlasSans(10, .regular))
                            .foregroundColor(Palette.hostMeta.color)
                            .padding(15)
                    }
                    Spacer(minLength: 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var appContent: AnyView? {
        guard case .app(let id) = selection,
              let app = runtime.hostScene.app(for: id) ?? runtime.hostSnapshot.apps.first(where: { $0.id == id })
        else { return nil }
        let domains = app.endpoints.compactMap { endpoint -> (String, Double)? in
            guard let name = endpoint.domain else { return nil }
            return (name, endpoint.rxPerSecond + endpoint.txPerSecond)
        }
        var grouped: [String: Double] = [:]
        for (name, rate) in domains { grouped[name, default: 0] += rate }
        let top = grouped.sorted { $0.value > $1.value }.prefix(6)
        let displayName = runtime.hostAppDisplayName(app)
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                HostAppGlyph(app: app).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName)
                        .font(.atlasSans(17, .medium))
                        .foregroundColor(Palette.hostText.color)
                        .lineLimit(1)
                    Text(app.detail)
                        .font(.atlasMono(7, .regular))
                        .foregroundColor(Palette.hostMeta.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(app.isSystem ? "SERVICE" : "APP")
                    .font(.atlasMono(6, .regular))
                    .tracking(0.4)
                    .foregroundColor(Palette.hostApp.color)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Palette.hostApp.opacity(0.3), lineWidth: 1))
            }
            .padding(.horizontal, 15)
            .padding(.top, 12)
            AliasEditor(runtime: runtime, original: app.name,
                        alias: runtime.hostAppAlias(app), target: .hostApp,
                        accent: Palette.hostApp) { value in
                runtime.setHostAppAlias(value, for: app)
            }
            .id("alias-host-app-\(app.id)")
            .padding(.horizontal, 15)
            stats([
                ("In now", Format.dataRate(app.rxPerSecond), true),
                ("Out now", Format.dataRate(app.txPerSecond), false),
                ("Session in", Format.bytes(app.rxTotal), true),
                ("Session out", Format.bytes(app.txTotal), false),
            ])
            block("Top domains", value: "\(top.count)") {
                if top.isEmpty {
                    Text("No resolved domains yet.")
                        .font(.atlasSans(9.5, .regular))
                        .foregroundColor(Palette.hostMeta.color)
                } else {
                    ForEach(Array(top.enumerated()), id: \.offset) { pair in
                        HStack(spacing: 7) {
                            Text(runtime.hostDestinationDisplayName(name: pair.element.key))
                                .font(.atlasSans(10, .regular))
                                .foregroundColor(Palette.hostRemote.color)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(Format.dataRate(pair.element.value))
                                .font(.atlasMono(6.8, .regular))
                                .foregroundColor(Palette.hostText2.color)
                                .frame(width: 64, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            block("Endpoints", value: "\(app.endpoints.count)") {
                ForEach(app.endpoints.prefix(8)) { endpoint in
                    HStack(spacing: 7) {
                        Text(runtime.hostEndpointDisplayName(endpoint))
                            .font(.atlasMono(7.2, .regular))
                            .foregroundColor(Palette.hostRemote.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(endpoint.service)
                            .font(.atlasMono(6.2, .regular))
                            .foregroundColor(Palette.hostFaint.color)
                        Text(Format.dataRate(endpoint.rxPerSecond + endpoint.txPerSecond))
                            .font(.atlasMono(6.4, .regular))
                            .foregroundColor(Palette.hostMeta.color)
                    }
                    .padding(.vertical, 2)
                }
            }
            Button { runtime.focusHostSelection() } label: {
                Text("FOCUS")
                    .font(.atlasMono(7, .regular))
                    .tracking(0.6)
                    .foregroundColor(Palette.host.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Palette.host.opacity(0.28), lineWidth: 1))
            }
            .buttonStyle(AtlasPlainButtonStyle())
            .padding(.horizontal, 15)
            .padding(.top, 12)
        })
    }

    private var domainContent: AnyView? {
        guard case .domain(let id) = selection,
              let domain = runtime.hostScene.domain(for: id) ?? runtime.hostSnapshot.domains.first(where: { $0.id == id })
        else { return nil }
        let appNames = domain.appIDs.compactMap { appID in
            runtime.hostSnapshot.apps.first(where: { $0.id == appID })
        }
        let displayName = runtime.hostDestinationDisplayName(domain)
        let original = runtime.hostDestinationOriginalText(domain)
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            Text(displayName)
                .font(.atlasSans(17, .medium))
                .foregroundColor(Palette.hostText.color)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 15)
                .padding(.top, 12)
            HStack(spacing: 5) {
                Text("\(domain.service) · \(domain.scope.title)" + (original.map { " · \($0)" } ?? ""))
                    .font(.atlasMono(7, .regular))
                    .foregroundColor(Palette.hostMeta.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let local = domain.scope == .loopback
                if local || domain.confidence != .none || !domain.isDomain {
                    Text(local ? "LOCAL" : domain.confidence.label.uppercased())
                        .font(.atlasMono(5.8, .regular))
                        .foregroundColor(local ? Palette.hostMint.color : Palette.hostRemote.color)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 2)
                            .strokeBorder((local ? Palette.hostMint : Palette.hostRemote).opacity(0.3), lineWidth: 1))
                }
            }
            .padding(.horizontal, 15)
            .padding(.top, 4)
            AliasEditor(runtime: runtime, original: domain.name,
                        alias: runtime.hostDestinationAlias(domain),
                        target: .hostDestination, accent: Palette.hostRemote) { value in
                runtime.setHostDestinationAlias(value, for: domain)
            }
            .id("alias-host-domain-\(domain.id)")
            .padding(.horizontal, 15)
            stats([
                ("In now", Format.dataRate(domain.rxPerSecond), true),
                ("Out now", Format.dataRate(domain.txPerSecond), false),
                ("Session in", Format.bytes(domain.rxTotal), true),
                ("Session out", Format.bytes(domain.txTotal), false),
            ])
            block("Apps", value: "\(appNames.count)") {
                ForEach(appNames) { app in
                    HStack(spacing: 7) {
                        HostAppGlyph(app: app).frame(width: 16, height: 16)
                        Text(runtime.hostAppDisplayName(app))
                            .font(.atlasSans(10, .regular))
                            .foregroundColor(Palette.hostApp.color)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Format.dataRate(app.rxPerSecond + app.txPerSecond))
                            .font(.atlasMono(6.6, .regular))
                            .foregroundColor(Palette.hostMeta.color)
                    }
                    .padding(.vertical, 3)
                }
            }
            block("Endpoints", value: "\(domain.endpointIDs.count)") {
                let endpoints = runtime.hostSnapshot.endpoints.filter { domain.endpointIDs.contains($0.id) }
                ForEach(endpoints.prefix(8)) { endpoint in
                    HStack(spacing: 7) {
                        Text("\(endpoint.remoteHost):\(endpoint.remotePort)")
                            .font(.atlasMono(7, .regular))
                            .foregroundColor(Palette.hostRemote.opacity(0.82))
                        Spacer(minLength: 4)
                        Text(Format.dataRate(endpoint.rxPerSecond + endpoint.txPerSecond))
                            .font(.atlasMono(6.4, .regular))
                            .foregroundColor(Palette.hostText2.color)
                    }
                    .padding(.vertical, 2)
                }
            }
            Text(domain.isDomain
                 ? "Domain inferred from this Mac's Pi-hole query timing and local resolution. It is not read from the packet."
                 : "No domain was resolved for this endpoint; showing IP:port.")
                .font(.atlasSans(9, .regular))
                .lineSpacing(2)
                .foregroundColor(Palette.hostMeta.color)
                .padding(.horizontal, 15)
                .padding(.top, 12)
            Button { runtime.focusHostSelection() } label: {
                Text("FOCUS")
                    .font(.atlasMono(7, .regular))
                    .tracking(0.6)
                    .foregroundColor(Palette.host.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Palette.host.opacity(0.28), lineWidth: 1))
            }
            .buttonStyle(AtlasPlainButtonStyle())
            .padding(.horizontal, 15)
            .padding(.top, 12)
        })
    }

    private func stats(_ cells: [(String, String, Bool)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 1) {
            ForEach(Array(cells.enumerated()), id: \.offset) { pair in
                let cell = pair.element
                VStack(alignment: .leading, spacing: 3) {
                    Text(cell.0.uppercased())
                        .font(.atlasMono(6.2, .regular))
                        .tracking(0.7)
                        .foregroundColor(Palette.hostFaint.color)
                    Text(cell.1)
                        .font(.atlasMono(11, .regular))
                        .foregroundColor(cell.2 ? Palette.hostGlow.color : Palette.hostOut.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(Color.rgba("06141a", 0.8))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.hostText.opacity(0.07), lineWidth: 1))
        .padding(.horizontal, 15)
        .padding(.top, 13)
    }

    @ViewBuilder
    private func block<Content: View>(_ title: String, value: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow(text: title, size: 6.8, color: Palette.host.color, trackingEm: 0.14)
                Spacer()
                Text(value)
                    .font(.atlasMono(6.4, .regular))
                    .foregroundColor(Palette.hostFaint.color)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.top, 5)
        }
        .padding(.horizontal, 15)
        .padding(.top, 14)
    }
}
