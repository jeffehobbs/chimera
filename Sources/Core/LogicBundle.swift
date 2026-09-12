//  LogicBundle.swift
//
//  A `.logicx` is a directory, not an archive, which makes producing a hybrid
//  mostly a copy plus a rewrite. Every output here starts life as a copy of the
//  *host* bundle so the thousand records of boilerplate Logic expects — 32 score
//  styles, 32 text styles, the environment, the mixer — arrive intact, and only
//  then do the strategies touch anything.

import Foundation

struct LogicBundle {
    let url: URL
    var name: String { url.deletingPathExtension().lastPathComponent }

    init(url: URL) { self.url = url }

    // MARK: Paths

    func altDirectory(_ alt: String = "000") -> URL {
        url.appending(path: "Alternatives").appending(path: alt)
    }
    var projectDataURL: URL { altDirectory().appending(path: "ProjectData") }
    var metaDataURL: URL { altDirectory().appending(path: "MetaData.plist") }
    var projectInfoURL: URL { url.appending(path: "Resources/ProjectInformation.plist") }
    var mediaURL: URL { url.appending(path: "Media") }

    var exists: Bool {
        FileManager.default.fileExists(atPath: projectDataURL.path)
    }

    // MARK: Read

    func project() throws -> LogicProject { try LogicProject(contentsOf: projectDataURL) }

    func metadata() -> [String: Any] {
        guard let d = try? Data(contentsOf: metaDataURL),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any]
        else { return [:] }
        return p
    }

    /// Files under `Media/`, keyed by their path relative to it.
    func mediaFiles() -> [String: URL] {
        var out: [String: URL] = [:]
        guard let e = FileManager.default.enumerator(at: mediaURL, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let f as URL in e {
            guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = f.path.replacingOccurrences(of: mediaURL.path + "/", with: "")
            out[rel] = f
        }
        return out
    }

    // MARK: Write

    /// Copies this bundle to `destination`, dropping Logic's own backups — they
    /// would still hold the unmutated project and are only confusing in a hybrid.
    @discardableResult
    func copy(to destination: URL) throws -> LogicBundle {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: url, to: destination)
        let backups = destination.appending(path: "Alternatives/000/Project File Backups")
        if fm.fileExists(atPath: backups.path) { try? fm.removeItem(at: backups) }
        return LogicBundle(url: destination)
    }

    func write(_ project: LogicProject) throws {
        try project.serialized().write(to: projectDataURL, options: .atomic)
    }

    /// Keeps the plist summary honest about what the stream now says. Finder,
    /// Spotlight and Logic's own browser read this and never touch ProjectData.
    func updateMetadata(from project: LogicProject, trackCount: Int? = nil) {
        var md = metadata()
        guard !md.isEmpty else { return }
        md["BeatsPerMinute"] = project.tempo
        md["SongSignatureNumerator"] = project.timeSignature.numerator
        md["SongSignatureDenominator"] = project.timeSignature.denominator
        if let n = trackCount { md["NumberOfTracks"] = n }
        if let d = try? PropertyListSerialization.data(fromPropertyList: md, format: .binary, options: 0) {
            try? d.write(to: metaDataURL, options: .atomic)
        }
    }

    /// Brings a donor's audio into this bundle, skipping anything already here.
    /// Returns the relative paths actually added.
    @discardableResult
    func absorbMedia(from donor: LogicBundle) -> [String] {
        let fm = FileManager.default
        var added: [String] = []
        for (rel, src) in donor.mediaFiles() {
            let dst = mediaURL.appending(path: rel)
            if fm.fileExists(atPath: dst.path) { continue }
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.copyItem(at: src, to: dst)) != nil { added.append(rel) }
        }
        return added
    }
}
