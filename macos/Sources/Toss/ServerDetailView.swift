import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DetailTab: Hashable {
    case throwFlow
    case send
    case pull
    case list
}

struct ServerDetailView: View {
    @ObservedObject var state: AppState
    let server: ServerConfig
    let onEdit: () -> Void

    @State private var tab: DetailTab = .throwFlow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Picker("", selection: $tab) {
                Text(t("Throw")).tag(DetailTab.throwFlow)
                Text(t("Send")).tag(DetailTab.send)
                Text(t("Pull")).tag(DetailTab.pull)
                Text(t("Files")).tag(DetailTab.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            Group {
                switch tab {
                case .throwFlow:
                    ThrowSourcePanel(state: state, source: .server(server))
                case .send:
                    ScrollView {
                        SendPanel(state: state, server: server)
                    }
                case .pull:
                    PullPanel(state: state, server: server)
                case .list:
                    ListPanel(state: state, server: server)
                }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if tab != .throwFlow {
                Divider()
                    .padding(.top, 12)

                OutputView(state: state)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(server.name)
                        .font(.title2.weight(.semibold))
                    if server.hasCustomTargetDir {
                        Text(t("Custom folder"))
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }

                Text(server.address)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text(state.targetDirectories(for: server).first ?? state.effectiveTargetDir(for: server))
                        .textSelection(.enabled)
                    if state.targetDirectories(for: server).count > 1 {
                        Text("+\(state.targetDirectories(for: server).count - 1)")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(t("Edit"), action: onEdit)
        }
        .padding(20)
    }
}

private enum PathMessage {
    case error(String)
    case notice(String)
    case success(String)

    var text: String {
        switch self {
        case .error(let text), .notice(let text), .success(let text):
            return text
        }
    }

    var icon: String {
        switch self {
        case .error:
            return "exclamationmark.triangle.fill"
        case .notice:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .error:
            return .red
        case .notice:
            return .orange
        case .success:
            return .green
        }
    }
}

struct SendPanel: View {
    @ObservedObject var state: AppState
    let server: ServerConfig

    @State private var files: [URL] = []
    @State private var targetOverride = ""
    @State private var pathInput = ""
    @State private var pathMessage: PathMessage?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            dropZone

            HStack(spacing: 10) {
                Button {
                    addPaths(FileChooser.chooseFiles().map(\.path))
                } label: {
                    Label(t("Choose Files or Folders…"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(state.busy)

                Spacer()

                Text(files.isEmpty ? t("No files selected") : t("{} selected", files.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                TextField(t("Or paste a file or folder path (supports ~)"), text: $pathInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        addTypedPath()
                    }
                Button(t("Add")) {
                    addTypedPath()
                }
                .disabled(pathInput.trimmed.isEmpty)
            }

            if let pathMessage {
                Label(pathMessage.text, systemImage: pathMessage.icon)
                    .font(.caption)
                    .foregroundStyle(pathMessage.color)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            if !files.isEmpty {
                fileList
            }

            TextField(
                t("Remote folder (empty uses {})", state.effectiveTargetDir(for: server)),
                text: $targetOverride
            )
            .textFieldStyle(.roundedBorder)

            HStack(alignment: .firstTextBaseline) {
                Label(t("Folders are packed as tar.gz when sent"), systemImage: "archivebox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    send()
                } label: {
                    Label(t("Send"), systemImage: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.green)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(files.isEmpty || state.busy)
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 5) {
            Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "tray.and.arrow.down")
                .font(.system(size: 22, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isDropTargeted ? Brand.green : Color.secondary)
            Text(isDropTargeted ? t("Drop to add") : t("Drag files or folders here"))
                .font(.callout.weight(.medium))
                .foregroundStyle(isDropTargeted ? Brand.green : Color.primary)
            Text(t("Or use the button below, or paste a path"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(
            RoundedRectangle(cornerRadius: Brand.radius)
                .fill(isDropTargeted ? Brand.green.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Brand.radius)
                .strokeBorder(isDropTargeted ? Brand.green.opacity(0.65) : Brand.hairline, lineWidth: 1)
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isDropTargeted)
        .onDrop(
            of: [UTType.fileURL, UTType.url, UTType.plainText, UTType.item],
            isTargeted: $isDropTargeted,
            perform: handleDrop
        )
    }

    private var fileList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(Array(files.enumerated()), id: \.offset) { index, url in
                    HStack(spacing: 9) {
                        Image(systemName: isDirectory(url) ? "folder" : "doc")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(url.deletingLastPathComponent().path)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Button {
                            files.remove(at: index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
            .padding(4)
        }
        .frame(maxHeight: 132)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func send() {
        let value = targetOverride.trimmed
        let destination = value.isEmpty ? state.effectiveTargetDir(for: server) : value
        let selected = files
        let currentServer = server
        state.run {
            try await state.transfer.send(server: currentServer, files: selected, targetDir: destination)
        }
    }

    private func addTypedPath() {
        let raw = pathInput.trimmed
        guard !raw.isEmpty else {
            pathMessage = .error(t("Enter a file or folder path"))
            return
        }

        switch validate(raw) {
        case .invalid(let reason):
            pathMessage = .error(reason)
        case .valid(let url, let duplicate):
            if duplicate {
                pathMessage = .notice(t("Already in the list: {}", url.path))
                return
            }
            files.append(url)
            pathInput = ""
            if isDirectory(url) {
                pathMessage = .success(t("Added folder \"{}\"; it will be packed when sent", url.lastPathComponent))
            } else {
                pathMessage = .success(t("Added file \"{}\"", url.lastPathComponent))
            }
        }
    }

    private func addPaths(_ rawPaths: [String], initialProblems: [String] = []) {
        var added = 0
        var problems = initialProblems

        for raw in rawPaths {
            switch validate(raw) {
            case .invalid(let reason):
                problems.append(reason)
            case .valid(let url, let duplicate):
                if duplicate {
                    problems.append(t("Already in the list: {}", url.path))
                } else {
                    files.append(url)
                    added += 1
                }
            }
        }

        guard !problems.isEmpty || added > 0 else { return }

        if let first = problems.first {
            let extra = problems.count > 1 ? t(" ({} more were not added)", problems.count - 1) : ""
            if added > 0 {
                pathMessage = .notice(t("Added {} items; {}{}", added, first, extra))
            } else {
                pathMessage = .error("\(first)\(extra)")
            }
        } else {
            pathMessage = .success(t("Added {} items", added))
        }
    }

    private enum PathCheck {
        case valid(URL, duplicate: Bool)
        case invalid(String)
    }

    private enum DropLoadResult {
        case success(String)
        case failure(String)
    }

    private func validate(_ raw: String) -> PathCheck {
        let value = raw.trimmed
        guard !value.isEmpty else {
            return .invalid(t("The path is empty"))
        }

        let url: URL
        if value.lowercased().hasPrefix("file://") {
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? value
            guard let parsed = URL(string: encoded), parsed.isFileURL else {
                return .invalid(t("Could not parse the file path: {}", value))
            }
            url = parsed.standardizedFileURL
        } else if let parsed = URL(string: value), let scheme = parsed.scheme, !scheme.isEmpty {
            guard parsed.isFileURL else {
                return .invalid(t("Only local files or folders are supported, not links: {}", value))
            }
            url = parsed.standardizedFileURL
        } else {
            let expanded = (value as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                return .invalid(t("Enter an absolute path, or one starting with ~"))
            }
            url = URL(fileURLWithPath: expanded).standardizedFileURL
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return .invalid(t("Path does not exist: {}", url.path))
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return .invalid(t("No permission to read: {}", url.path))
        }

        let duplicate = files.contains { $0.standardizedFileURL.path == url.path }
        return .valid(url, duplicate: duplicate)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }

        let lock = NSLock()
        let group = DispatchGroup()
        var candidates: [String] = []
        var failures: [String] = []

        for provider in providers {
            group.enter()
            loadDropCandidate(from: provider) { result in
                defer { group.leave() }
                lock.lock()
                switch result {
                case .success(let raw):
                    candidates.append(raw)
                case .failure(let reason):
                    failures.append(reason)
                }
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            if candidates.isEmpty && failures.isEmpty {
                pathMessage = .error(t("No files or folders could be added"))
                return
            }
            addPaths(candidates, initialProblems: failures)
        }
        return true
    }

    private func loadDropCandidate(
        from provider: NSItemProvider,
        completion: @escaping (DropLoadResult) -> Void
    ) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = Self.droppedURL(from: item) else {
                    completion(.failure(t("Could not read the dropped file path")))
                    return
                }
                completion(.success(url.isFileURL ? url.path : url.absoluteString))
            }
            return
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                guard let url = Self.droppedURL(from: item) else {
                    completion(.failure(t("Could not read the dropped link")))
                    return
                }
                completion(.success(url.isFileURL ? url.path : url.absoluteString))
            }
            return
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let text = item as? String {
                    completion(.success(text))
                } else if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                    completion(.success(text))
                } else {
                    completion(.failure(t("Could not read the dropped text")))
                }
            }
            return
        }

        completion(.failure(t("Unsupported content type; only local files or folders")))
    }

    private static func droppedURL(from item: NSSecureCoding?) -> URL? {
        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
            return url
        }
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        return nil
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }
}

struct PullPanel: View {
    @ObservedObject var state: AppState
    let server: ServerConfig

    @State private var remoteFile = ""
    @State private var outputDirText = PullPanel.defaultOutputDir.path
    @State private var pathMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(t("Remote file"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(t("e.g. report.pdf or /var/tmp/backup.tar.gz"), text: $remoteFile)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(t("Save to"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField("", text: $outputDirText, prompt: Text(PullPanel.defaultOutputDir.path))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityLabel(t("Save to"))

                    Button {
                        chooseOutputDir()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .help(t("Choose a folder to save into"))
                    .disabled(state.busy)
                }
            }

            if let pathMessage {
                Label(pathMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(t("Relative paths are joined to the server's transfer folder"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    pull()
                } label: {
                    Label(t("Pull"), systemImage: "arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.green)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(remoteFile.trimmed.isEmpty || state.busy)
            }
        }
    }

    private static var defaultOutputDir: URL {
        FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private func chooseOutputDir() {
        if let url = FileChooser.chooseDirectory(
            title: t("Choose a folder to save into"),
            prompt: t("Choose")
        ) {
            outputDirText = url.path
            pathMessage = nil
        }
    }

    private func resolvedOutputDir() -> URL? {
        let trimmed = outputDirText.trimmed
        if trimmed.isEmpty {
            outputDirText = Self.defaultOutputDir.path
            pathMessage = nil
            return Self.defaultOutputDir
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            pathMessage = t("Enter an absolute path, or one starting with ~")
            return nil
        }

        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                pathMessage = t("The save location is not a folder: {}", url.path)
                return nil
            }
        } else {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                pathMessage = t("Could not create the save location: {}", error.localizedDescription)
                return nil
            }
        }

        pathMessage = nil
        return url
    }

    private func pull() {
        guard let directory = resolvedOutputDir() else { return }
        let file = remoteFile.trimmed
        let targetDir = state.effectiveTargetDir(for: server)
        let currentServer = server
        state.run {
            try await state.transfer.pull(
                server: currentServer,
                remoteFile: file,
                outputDir: directory,
                targetDir: targetDir
            )
        }
    }
}

struct ListPanel: View {
    @ObservedObject var state: AppState
    let server: ServerConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Brand.green.opacity(0.10))
                    Image(systemName: "folder")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Brand.green)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(server.address)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(state.effectiveTargetDir(for: server))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button {
                    refresh()
                } label: {
                    Label(t("Refresh List"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(state.busy)
            }

            Text(t("Results appear in the output area below."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Brand.radius)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Brand.radius)
                .strokeBorder(Brand.hairline, lineWidth: 1)
        )
    }

    private func refresh() {
        let targetDir = state.effectiveTargetDir(for: server)
        let currentServer = server
        state.run {
            try await state.transfer.list(server: currentServer, targetDir: targetDir)
        }
    }
}

struct OutputView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(t("Output"), systemImage: "terminal")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                if state.busy {
                    ProgressView()
                        .controlSize(.small)
                    Text(t("Running…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(t("Clear")) {
                    state.clearOutput()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(state.output.isEmpty ? t("No activity yet") : state.output)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(state.output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Brand.hairline, lineWidth: 1)
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(minHeight: 150, maxHeight: 220)
    }
}
