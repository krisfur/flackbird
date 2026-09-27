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
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue
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
                }

                // Apps can't read or flip the Siri switch; this opens the Shortcuts page that has it.
                Section {
                    #if os(iOS)
                        ShortcutsLink()
                    #else
                        // ShortcutsLink is iOS-only; this opens the Shortcuts app instead of SwiftFlac's page.
                        Link(destination: URL(string: "shortcuts://")!) {
                            Label("Open Shortcuts", systemImage: "square.2.layers.3d")
                        }
                    #endif
                } header: {
                    Text("Siri & Shortcuts")
                } footer: {
                    Text("Turn on Siri for SwiftFlac there to use voice commands like \"Shuffle my library in SwiftFlac\".")
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
