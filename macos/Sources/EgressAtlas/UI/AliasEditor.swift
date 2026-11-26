import SwiftUI

/// Small inline editor used by the inspector cards. Aliases are local display
/// names only: they never travel to Pi-hole. A device alias replaces the name
/// while the IP stays visible; a destination alias can optionally keep the
/// original domain beside it.
struct AliasEditor: View {
    enum Target {
        case device
        case destination
        case hostApp
        case hostDestination
    }

    @ObservedObject var runtime: AtlasRuntime
    /// The IP or domain this alias stands in for.
    let original: String
    /// The currently stored alias, if any.
    let alias: String?
    /// Devices always keep their address; destinations follow the display
    /// preference for showing the original domain beside the alias.
    let target: Target
    /// Accent for the editor chrome; host cards use their own cool tones.
    var accent: SRGB = Palette.gold
    /// Persists an empty string as "remove the alias".
    let commit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    private var trimmedDraft: String {
        draft.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        trimmedDraft != (alias ?? "")
    }

    private var hasAlias: Bool {
        !(alias ?? "").isEmpty
    }

    private var usesHostChrome: Bool {
        target == .hostApp || target == .hostDestination
    }

    private var fieldFill: Color {
        usesHostChrome ? Color.rgba("040d13", 0.7) : Color.rgba("080503", 0.55)
    }

    private var panelFill: Color {
        usesHostChrome ? Color.rgba("06141a", 0.58) : Color.rgba("0b0604", 0.44)
    }

    private var disabledFill: Color {
        usesHostChrome ? Color.rgba("07141b", 0.6) : Color.rgba("120a06", 0.55)
    }

    private var helperText: String {
        guard hasAlias else { return "cards show \(original)" }
        switch target {
        case .device:
            return "alias replaces the title · IP stays visible"
        case .destination:
            return runtime.showAliasWithAddress
                ? "alias + \(original)"
                : "alias replaces \(original)"
        case .hostApp:
            return "alias replaces the app title · detail stays visible"
        case .hostDestination:
            return runtime.showAliasWithAddress
                ? "alias + \(original)"
                : "alias replaces \(original)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "Alias", size: 7.5, color: accent.color, trackingEm: 0.13)
                Spacer(minLength: 6)
                Text(hasAlias ? "LOCAL ONLY" : "NOT SET")
                    .font(.atlasMono(5.8, .regular))
                    .tracking(5.8 * 0.08)
                    .foregroundColor(hasAlias ? Palette.sage.opacity(0.9) : Palette.faint.color)
            }

            HStack(spacing: 5) {
                TextField("Add a display name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.atlasSans(10, .regular))
                    .foregroundColor(Palette.text.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(fieldFill))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(focused ? accent.opacity(0.42) : Palette.text.opacity(0.1),
                                      lineWidth: 1))
                    .focused($focused)
                    .onSubmit { commitDraft() }
                    .accessibilityLabel("Alias for \(original)")

                Button(action: { commitDraft() }) {
                    Text("SAVE")
                        .font(.atlasMono(6.6, .regular))
                        .tracking(6.6 * 0.08)
                        .foregroundColor(canSave ? Palette.deep.color : Palette.faint.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(canSave ? accent.opacity(0.92) : disabledFill))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(canSave ? accent.opacity(0.65) : Palette.text.opacity(0.08),
                                          lineWidth: 1))
                }
                .buttonStyle(AtlasPlainButtonStyle())
                .disabled(!canSave)
                .accessibilityLabel("Save alias for \(original)")

                if hasAlias {
                    Button {
                        draft = ""
                        commit("")
                        focused = false
                    } label: {
                        Text("CLEAR")
                            .font(.atlasMono(6.2, .regular))
                            .tracking(6.2 * 0.06)
                            .foregroundColor(Palette.coral.opacity(0.9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 5).fill(disabledFill))
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Palette.coral.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(AtlasPlainButtonStyle())
                    .accessibilityLabel("Clear alias for \(original)")
                }
            }

            HStack(spacing: 6) {
                Text(helperText)
                    .font(.atlasMono(6, .regular))
                    .tracking(6 * 0.02)
                    .foregroundColor(Palette.faint.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if target == .destination || target == .hostDestination {
                    Text("SHOW BOTH")
                        .font(.atlasMono(5.9, .regular))
                        .tracking(5.9 * 0.06)
                        .foregroundColor(runtime.showAliasWithAddress ? accent.color : Palette.dim.color)
                    TinyToggle(isOn: Binding(get: { runtime.showAliasWithAddress },
                                             set: { runtime.setShowAliasWithAddress($0) }),
                               label: "Show original with alias", tone: accent)
                        .help("Show the original domain or IP beside destination aliases")
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(panelFill))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(usesHostChrome ? accent.opacity(0.13) : Palette.text.opacity(0.07), lineWidth: 1))
        .padding(.top, 12)
        .onAppear { draft = alias ?? "" }
        .onChange(of: alias) { _, value in
            if !focused { draft = value ?? "" }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commitDraft() }
        }
    }

    private func commitDraft() {
        let normalized = String(trimmedDraft.prefix(64))
        guard normalized != (alias ?? "") else {
            draft = alias ?? ""
            return
        }
        commit(normalized)
        draft = normalized
    }
}
