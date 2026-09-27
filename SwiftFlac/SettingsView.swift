import AppIntents
import SwiftUI

struct SettingsButton: View {
    @State private var showingSettings = false

    var body: some View {
        Button("Settings", systemImage: "gearshape") {
            showingSettings = true
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue
    @AppStorage("showAudioQuality") private var showAudioQuality = true
    @State private var showingFolderPicker = false

    private static let repositoryURL = URL(string: "https://github.com/krisfur/swiftflac")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Library") {
                    if let root = library.rootURL {
                        LabeledContent("Folder", value: root.lastPathComponent)
                    }
                    Button("Choose Folder…", systemImage: "folder.badge.plus") {
                        showingFolderPicker = true
                    }
                    Button("Rescan Library", systemImage: "arrow.clockwise") {
                        library.rescan()
                    }
                }

                Section {
                    Picker("Appearance", selection: $appearanceRaw) {
                        ForEach(Appearance.allCases, id: \.rawValue) { appearance in
                            Text(appearance.label).tag(appearance.rawValue)
                        }
                    }
                    Toggle("Show Audio Quality", isOn: $showAudioQuality)
                } footer: {
                    Text("Shows the file's format, resolution, and bitrate under the scrubber. AirPlay and Bluetooth may play it at a different quality.")
                }

                // Apps can't read or flip the Siri switch; this opens the Shortcuts page that has it.
                Section {
                    #if os(iOS)
                        // .automatic contrasts with the background; match it, outlined to stay visible.
                        ShortcutsLink()
                            .shortcutsLinkStyle(colorScheme == .dark ? .darkOutline : .lightOutline)
                            .frame(maxWidth: .infinity)
                    #else
                        // ShortcutsLink is iOS-only; this opens the Shortcuts app instead of SwiftFlac's page.
                        Link(destination: URL(string: "shortcuts://")!) {
                            Label("Open Shortcuts", systemImage: "square.2.layers.3d")
                        }
                        .frame(maxWidth: .infinity)
                    #endif
                } header: {
                    Text("Siri & Shortcuts")
                } footer: {
                    #if os(iOS)
                        Text("In Shortcuts, tap \(Image(systemName: "info.circle")) at the top right and turn on Siri to use voice commands like \"Shuffle my library in SwiftFlac\".")
                    #else
                        Text("Turn on Siri for SwiftFlac in Shortcuts to use voice commands like \"Shuffle my library in SwiftFlac\".")
                    #endif
                }

                Section("About") {
                    HStack(spacing: 12) {
                        Image("AboutIcon")
                            .resizable()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SwiftFlac")
                                .font(.headline)
                            Text("Version \(version) · MIT License")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Made by", value: "Krzysztof Furman")
                    Link(destination: Self.repositoryURL) {
                        Label("View on GitHub", systemImage: "link")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                library.setRootFolder(url)
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }
}
