import SwiftUI

/// Small inline editor used by the inspector cards. Aliases are local display
/// names only: they never travel to Pi-hole and the original address stays one
/// keystroke away.
struct AliasEditor: View {
    @ObservedObject var runtime: AtlasRuntime
    /// The IP or domain this alias stands in for.
    let original: String
    /// The currently stored alias, if any.
    let alias: String?
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

    private var helperText: String {
        guard hasAlias else { return "cards show \(original)" }
        return runtime.showAliasWithAddress
            ? "alias + \(original)"
            : "alias replaces \(original)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "Alias", size: 7.5, color: Palette.gold.color, trackingEm: 0.13)
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
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.rgba("080503", 0.55)))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(focused ? Palette.gold.opacity(0.42) : Palette.text.opacity(0.1),
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
                            .fill(canSave ? Palette.gold.opacity(0.92) : Color.rgba("120a06", 0.55)))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(canSave ? Palette.gold.opacity(0.65) : Palette.text.opacity(0.08),
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
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.rgba("120a06", 0.55)))
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
                Text("SHOW BOTH")
                    .font(.atlasMono(5.9, .regular))
                    .tracking(5.9 * 0.06)
                    .foregroundColor(runtime.showAliasWithAddress ? Palette.gold.color : Palette.dim.color)
                TinyToggle(isOn: Binding(get: { runtime.showAliasWithAddress },
                                         set: { runtime.setShowAliasWithAddress($0) }),
                           label: "Show alias and address")
                    .help("Show aliases and original addresses on every card")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.rgba("0b0604", 0.44)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Palette.text.opacity(0.07), lineWidth: 1))
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
