// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Fork: Settings › App Icons. Every app in a grid. Drop a picture (or an
/// .icns, or another app) on one to make it its icon; click one to compare
/// its own icon with the dark version and choose.
struct AppIconSettings: View {
    @ObservedObject private var service = AppIconService.shared
    @AppStorage(DefaultsKey.appIconsEnabled) private var keepAfterUpdates = true
    @State private var search = ""
    @State private var onlyCustomized = false
    @State private var confirmAllDark = false
    @State private var confirmRestoreAll = false

    private var shown: [AppIconService.App] {
        service.apps.filter { app in
            (search.isEmpty || app.name.localizedCaseInsensitiveContains(search))
                && (!onlyCustomized || service.record(for: app) != nil)
        }
    }

    private var changeable: [AppIconService.App] { service.apps.filter { !$0.isProtected } }

    var body: some View {
        Form {
            Section {
                Toggle("Keep custom icons after updates", isOn: $keepAfterUpdates)
                    .onChange(of: keepAfterUpdates) { _, _ in service.syncWithPreferences() }
                Text("An update replaces an app, and its custom icon with it. With this on, Vorssaint notices and puts the icon back.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline) {
                    Label("Changing an app you installed yourself needs App Management for Vorssaint. Apps from the App Store or an installer ask for your password instead.",
                          systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open…") { Permissions.shared.openAppManagementSettings() }
                        .controlSize(.small)
                }
                if !service.pendingRestore.isEmpty {
                    HStack {
                        Label("\(service.pendingRestore.map(\.name).joined(separator: ", ")) updated and lost \(service.pendingRestore.count == 1 ? "its" : "their") icon.",
                              systemImage: "arrow.uturn.backward.circle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Put Back") { service.restorePending() }
                    }
                }
                if let message = service.message {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if service.needsAppManagement {
                            Button("Open App Management Settings") { Permissions.shared.openAppManagementSettings() }
                                .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text(AppIconSupport.title)
            }

            Section {
                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search apps", text: $search, prompt: Text("Search apps"))
                            .textFieldStyle(.plain)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
                    .frame(maxWidth: 240)
                    Picker("", selection: $onlyCustomized) {
                        Text("All").tag(false)
                        Text("Customized").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Menu {
                        Button("Make All Dark…") { confirmAllDark = true }
                            .disabled(changeable.isEmpty)
                        Button("Restore All Originals…") { confirmRestoreAll = true }
                            .disabled(service.records.isEmpty)
                        Divider()
                        Button("Refresh the Dock") { service.refreshDock() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                if service.apps.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding()
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 6)], spacing: 6) {
                        ForEach(shown) { app in
                            AppIconTile(app: app)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Apps")
            } footer: {
                Text("Drop a picture, an .icns file or another app on an app to use it as its icon. Click an app for its dark version.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { service.scan() }
        .confirmationDialog("Make \(changeable.filter { service.record(for: $0) == nil }.count) apps dark?",
                            isPresented: $confirmAllDark) {
            Button("Make Dark") { service.makeDark(changeable.filter { service.record(for: $0) == nil }) }
        } message: {
            Text("Apps you already customized keep their icon. Apps installed by the App Store or an installer ask for your password once.")
        }
        .confirmationDialog("Restore every original icon?", isPresented: $confirmRestoreAll) {
            Button("Restore All", role: .destructive) {
                service.restore(service.apps.filter { service.record(for: $0) != nil })
            }
        }
    }
}

// MARK: - A tile

private struct AppIconTile: View {
    let app: AppIconService.App
    @ObservedObject private var service = AppIconService.shared
    @State private var targeted = false
    @State private var hovering = false
    @State private var showsDetail = false

    var body: some View {
        let record = service.record(for: app)
        let busy = service.busy.contains(app.path)
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: service.currentIcon(for: app))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .opacity(busy ? 0.4 : 1)
                    .overlay { if busy { ProgressView().controlSize(.small) } }
                if let record {
                    Image(systemName: record.style == .dark ? "moon.fill" : "paintbrush.pointed.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.accentColor))
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                } else if app.isProtected {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .offset(x: 2, y: 2)
                }
            }
            Text(app.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 30, alignment: .top)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(targeted ? Color.accentColor.opacity(0.18) : hovering ? Color.primary.opacity(0.06) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(targeted ? Color.accentColor : .clear, lineWidth: 2))
        .opacity(app.isProtected ? 0.45 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(app.isProtected ? "Apple's own apps live on the sealed system volume and can't be changed." : app.name)
        .onTapGesture { if !app.isProtected { showsDetail = true } }
        .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
            guard !app.isProtected else { return false }
            AppIconImageLoader.load(from: providers) { image in
                if let image { service.setIcon(image, style: .custom, for: [app]) }
            }
            return true
        }
        .contextMenu {
            if !app.isProtected {
                Button("Choose Image…") { AppIconImageLoader.choose { service.setIcon($0, style: .custom, for: [app]) } }
                Button("Make Dark") { service.makeDark([app]) }
                if record != nil || AppIconService.hasCustomIcon(app.path) {
                    Button("Restore Original") { service.restore([app]) }
                }
                Divider()
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
        }
        .popover(isPresented: $showsDetail, arrowEdge: .bottom) {
            AppIconDetail(app: app) { showsDetail = false }
        }
    }
}

// MARK: - Detail

/// The app's icon now, its own icon, and the dark version, side by side.
private struct AppIconDetail: View {
    let app: AppIconService.App
    let close: () -> Void
    @ObservedObject private var service = AppIconService.shared
    @State private var natural: NSImage?
    @State private var dark: NSImage?
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 16) {
            Text(app.name).font(.headline)
            HStack(alignment: .top, spacing: 18) {
                choice("Now", image: service.currentIcon(for: app), action: nil)
                choice("Original", image: natural,
                       action: service.record(for: app) == nil && !AppIconService.hasCustomIcon(app.path) ? nil : {
                    service.restore([app]); close()
                })
                choice("Dark", image: dark, action: {
                    service.makeDark([app]); close()
                })
            }
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5))
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(targeted ? Color.accentColor.opacity(0.12) : .clear))
                .frame(height: 64)
                .overlay {
                    VStack(spacing: 4) {
                        Text("Drop an image here").font(.callout)
                        Button("Choose Image…") {
                            AppIconImageLoader.choose { service.setIcon($0, style: .custom, for: [app]); close() }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
                    AppIconImageLoader.load(from: providers) { image in
                        if let image { service.setIcon(image, style: .custom, for: [app]); close() }
                    }
                    return true
                }
        }
        .padding(18)
        .frame(width: 400)
        .task {
            let app = self.app
            let (natural, dark) = await Task.detached(priority: .userInitiated) {
                let natural = AppIconService.shared.naturalIcon(for: app)
                return (natural, AppIconRenderer.darkIcon(from: natural))
            }.value
            self.natural = natural
            self.dark = dark
        }
    }

    private func choice(_ title: String, image: NSImage?, action: (() -> Void)?) -> some View {
        VStack(spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 96, height: 96)
            Text(title).font(.caption).foregroundStyle(.secondary)
            if let action {
                Button(title == "Dark" ? "Use Dark" : "Use Original", action: action)
                    .controlSize(.small)
                    .disabled(image == nil)
            } else {
                // Keeps the three columns level.
                Button(" ") {}.controlSize(.small).hidden()
            }
        }
    }
}

// MARK: - Loading pictures

enum AppIconImageLoader {
    /// A picture from a drop: an image file, an .icns, an app (its icon), or
    /// image data dragged out of a browser.
    static func load(from providers: [NSItemProvider], completion: @escaping (NSImage?) -> Void) {
        let deliver = { (image: NSImage?) in DispatchQueue.main.async { completion(image) } }
        guard let provider = providers.first else { return deliver(nil) }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                deliver(url.flatMap(image(at:)))
            }
        } else if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { image, _ in deliver(image as? NSImage) }
        } else {
            deliver(nil)
        }
    }

    static func image(at url: URL) -> NSImage? {
        if url.pathExtension.lowercased() == "app" { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(contentsOf: url)
    }

    static func choose(_ completion: @escaping (NSImage) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .icns, .application]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture, an .icns file or an app whose icon to use."
        guard panel.runModal() == .OK, let url = panel.url, let image = image(at: url) else { return }
        completion(image)
    }
}
