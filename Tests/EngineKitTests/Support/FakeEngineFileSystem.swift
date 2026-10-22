import Foundation
import Synchronization
import WarzagCore
import WarzagTestSupport
@testable import EngineKit

/// `InMemoryFileSystem` plus what the engine needs on top: symbolic links (followed for reads, like the real file
/// system, never for removal), tree copies and executable bits.
final class FakeEngineFileSystem: EngineFileSystem {
    let base = InMemoryFileSystem()

    private struct State {
        var links: [String: String] = [:]
        var executables: Set<String> = []
    }

    private let state = Mutex(State())

    // MARK: Test helpers

    func addFile(_ path: String, _ contents: String) { base.addFile(resolveParent(path), contents) }
    func addFile(_ path: String, _ data: Data) { base.addFile(resolveParent(path), data) }
    func addDirectory(_ path: String) { base.addDirectory(resolve(path)) }

    func addExecutable(_ path: String, _ contents: String = "#!/bin/sh\n") {
        let resolved = resolveParent(path)
        base.addFile(resolved, contents)
        state.withLock { _ = $0.executables.insert(resolved) }
    }

    func addLink(_ path: String, to destination: String) {
        let resolved = resolveParent(path)
        base.addDirectory((resolved as NSString).deletingLastPathComponent)
        state.withLock { $0.links[resolved] = destination }
    }

    func text(at path: String) -> String? { base.text(at: resolve(path)) }
    func data(at path: String) -> Data? { base.data(at: resolve(path)) }
    var links: [String: String] { state.withLock { $0.links } }

    // MARK: Paths

    static func normalize(_ path: String) -> String { URL(filePath: path).standardized.plainPath }

    /// The path with every symbolic link on the way followed.
    func resolve(_ path: String) -> String { resolve(path, followLast: true) }

    /// Links followed in the parent only: the item itself, link or not.
    func resolveParent(_ path: String) -> String { resolve(path, followLast: false) }

    private func resolve(_ path: String, followLast: Bool) -> String {
        let links = state.withLock { $0.links }
        var components = Self.normalize(path).split(separator: "/").map(String.init)
        var resolved = ""
        var index = 0
        var hops = 0
        while index < components.count {
            let candidate = resolved + "/" + components[index]
            let isLast = index == components.count - 1
            if !isLast || followLast, let destination = links[candidate], hops < 40 {
                hops += 1
                let target = destination.hasPrefix("/") ? destination : resolved + "/" + destination
                components = Self.normalize(target).split(separator: "/").map(String.init)
                    + components[(index + 1)...]
                resolved = ""
                index = 0
                continue
            }
            resolved = candidate
            index += 1
        }
        return resolved.isEmpty ? "/" : resolved
    }

    private func url(_ path: String) -> URL { URL(filePath: path) }
    private func resolved(_ url: URL) -> URL { URL(filePath: resolve(url.plainPath)) }

    // MARK: EngineFileSystem

    func isSymbolicLink(at url: URL) -> Bool {
        let path = resolveParent(url.plainPath)
        return state.withLock { $0.links[path] != nil }
    }

    func destinationOfSymbolicLink(at url: URL) throws -> String {
        let path = resolveParent(url.plainPath)
        guard let destination = state.withLock({ $0.links[path] }) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        return destination
    }

    func createSymbolicLink(at url: URL, destination: String) throws {
        let path = resolveParent(url.plainPath)
        guard !isSymbolicLink(at: url), !base.fileExists(at: self.url(path)) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try base.createDirectory(at: self.url((path as NSString).deletingLastPathComponent))
        state.withLock { $0.links[path] = destination }
    }

    func copyItem(at source: URL, to destination: URL) throws {
        let from = resolve(source.plainPath)
        let to = resolveParent(destination.plainPath)
        guard !base.fileExists(at: url(to)), !isSymbolicLink(at: url(to)) else { throw CocoaError(.fileWriteFileExists) }
        guard base.fileExists(at: url(from)) else { throw CocoaError(.fileReadNoSuchFile) }
        let executables = state.withLock { $0.executables }
        if let data = base.data(at: from) {
            base.addFile(to, data)
            if executables.contains(from) { state.withLock { _ = $0.executables.insert(to) } }
            return
        }
        let prefix = from + "/"
        base.addDirectory(to)
        for directory in base.allDirectories where directory.hasPrefix(prefix) {
            base.addDirectory(to + directory.dropFirst(from.count))
        }
        for file in base.allFiles where file.hasPrefix(prefix) {
            let copy = to + file.dropFirst(from.count)
            base.addFile(copy, base.data(at: file) ?? Data())
            if executables.contains(file) { state.withLock { _ = $0.executables.insert(copy) } }
        }
        state.withLock { state in
            for (link, target) in state.links where link.hasPrefix(prefix) {
                state.links[to + link.dropFirst(from.count)] = target
            }
        }
    }

    func replaceFile(at destination: URL, withCopyOf source: URL) throws {
        let data = try contents(of: source)
        let to = resolveParent(destination.plainPath)
        state.withLock { _ = $0.links.removeValue(forKey: to) }
        try base.writeAtomically(data, to: url(to))
        let from = resolve(source.plainPath)
        // Mutex is not re-entrant: resolve() takes the lock, so it runs outside withLock.
        state.withLock { state in
            if state.executables.contains(from) { state.executables.insert(to) } else { state.executables.remove(to) }
        }
    }

    func isExecutableFile(at url: URL) -> Bool {
        let path = resolve(url.plainPath)
        return base.fileExists(at: self.url(path)) && state.withLock { $0.executables.contains(path) }
    }

    // MARK: FileSystem

    func fileExists(at url: URL) -> Bool { base.fileExists(at: resolved(url)) }
    func directoryExists(at url: URL) -> Bool { base.directoryExists(at: resolved(url)) }
    func contents(of url: URL) throws -> Data { try base.contents(of: resolved(url)) }
    func read(_ url: URL, offset: UInt64, maxLength: Int) throws -> Data {
        try base.read(resolved(url), offset: offset, maxLength: maxLength)
    }
    func forEachChunk(of url: URL, chunkSize: Int, _ body: (Data) throws -> Void) throws {
        try base.forEachChunk(of: resolved(url), chunkSize: chunkSize, body)
    }
    func attributes(of url: URL) throws -> FileAttributes { try base.attributes(of: resolved(url)) }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        let directory = resolve(url.plainPath)
        var entries = try base.contentsOfDirectory(at: self.url(directory))
        let prefix = directory == "/" ? "/" : directory + "/"
        let links = state.withLock { $0.links.keys.filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") } }
        entries += links.map { URL(filePath: $0) }
        return entries.sorted { $0.plainPath < $1.plainPath }
    }

    func createDirectory(at url: URL) throws { try base.createDirectory(at: resolved(url)) }

    func writeAtomically(_ data: Data, to url: URL) throws {
        let path = resolveParent(url.plainPath)
        state.withLock { _ = $0.links.removeValue(forKey: path) }
        try base.writeAtomically(data, to: self.url(path))
    }

    func createExclusively(_ data: Data, at url: URL) throws -> Bool {
        if isSymbolicLink(at: url) { return false }
        return try base.createExclusively(data, at: URL(filePath: resolveParent(url.plainPath)))
    }

    func append(_ data: Data, to url: URL) throws { try base.append(data, to: resolved(url)) }

    func moveItem(at source: URL, to destination: URL) throws {
        let from = resolveParent(source.plainPath)
        let to = resolveParent(destination.plainPath)
        if let link = state.withLock({ $0.links.removeValue(forKey: from) }) {
            state.withLock { $0.links[to] = link }
            return
        }
        try base.moveItem(at: url(from), to: url(to))
        state.withLock { state in
            for (link, target) in state.links where link.hasPrefix(from + "/") {
                state.links.removeValue(forKey: link)
                state.links[to + link.dropFirst(from.count)] = target
            }
            for executable in state.executables where executable.hasPrefix(from + "/") || executable == from {
                state.executables.remove(executable)
                state.executables.insert(to + executable.dropFirst(from.count))
            }
        }
    }

    /// Removes a file, a tree, or a link itself (never what it points at).
    func removeItem(at url: URL) throws {
        let path = resolveParent(url.plainPath)
        if state.withLock({ $0.links.removeValue(forKey: path) }) != nil { return }
        try base.removeItem(at: self.url(path))
        state.withLock { state in
            state.links = state.links.filter { !$0.key.hasPrefix(path + "/") }
            state.executables = state.executables.filter { !$0.hasPrefix(path + "/") && $0 != path }
        }
    }

    func isWritableDirectory(at url: URL) -> Bool { base.isWritableDirectory(at: resolved(url)) }
    func volumeInfo(for url: URL) throws -> VolumeInfo { try base.volumeInfo(for: url) }
}
