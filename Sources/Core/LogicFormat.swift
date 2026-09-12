//  LogicFormat.swift
//
//  The `ProjectData` stream inside a Logic Pro `.logicx` bundle: read, mutate,
//  write back. The framing is documented in ~/Scripts/logic-discovery/FORMAT.md
//  and was proven against a 32-stream corpus — a 24-byte file header followed by
//  a flat run of records, each a 36-byte header plus a length-prefixed payload.
//
//  Nothing here is nested, which is the whole reason this app can exist: a
//  record can be moved, copied between projects, or dropped, and the stream is
//  still a stream. Whether *Logic* agrees is a different question, and the point
//  of the Fidelity setting.

import Foundation

enum LogicFormatError: LocalizedError {
    case badMagic(String)
    case sizeMismatch(declared: Int, actual: Int)
    case truncated(at: Int)
    case nonAsciiTag(at: Int, bytes: String)
    case unexpectedConstants(at: Int)
    case noRecords

    var errorDescription: String? {
        switch self {
        case .badMagic(let hex): return "Not a Logic ProjectData stream (magic \(hex))."
        case .sizeMismatch(let d, let a): return "Header says \(d) bytes, file holds \(a)."
        case .truncated(let off): return "Record at \(off) runs past the end of the file."
        case .nonAsciiTag(let off, let b): return "Unreadable record tag at \(off): \(b)."
        case .unexpectedConstants(let off): return "Record at \(off) has an unfamiliar header."
        case .noRecords: return "The stream holds no records."
        }
    }
}

// MARK: - Record

/// One record in the flat stream. `tag` is the logical FourCC — on disk the four
/// bytes are stored reversed, so `Song` is written `gnoS`.
struct LogicRecord: Equatable {
    var tag: String
    var version: UInt16      // +4  class version, stable per tag
    var subtype: UInt16      // +6  role discriminator within the tag
    var indexRaw: UInt32     // +8  index << 18
    var unk12: UInt16        // +12
    var id1: UInt32          // +14 object id, 0xFFFFFFFF = nil
    var id2: UInt32          // +18 object id
    var const22: UInt32      // +22 always 2 in the corpus
    var const26: UInt16      // +26 always 1 in the corpus
    var payload: Data

    static let headerSize = 36

    var index: Int { Int(indexRaw >> 18) }
    var byteCount: Int { Self.headerSize + payload.count }

    /// Rewrites only the group index, leaving the low bits of the field alone.
    mutating func setIndex(_ i: Int) {
        indexRaw = (indexRaw & 0x3FFFF) | (UInt32(truncatingIfNeeded: i) << 18)
    }
}

// MARK: - Project

struct LogicProject {
    static let magic: [UInt8] = [0x23, 0x47, 0xC0, 0xAB]
    static let fileHeaderSize = 24

    var appVersion: UInt16   // +4  2507 = Logic 10.8.1, 1710 = the 2014 vintage
    var dataVersion: UInt16  // +6  3 modern, 2 old
    var reserved8: UInt32    // +8  always 4
    var reserved12: UInt16   // +12 always 1
    var sizeWidth: UInt16    // +14 always 8 — the width of the size field
    var records: [LogicRecord]

    // MARK: Parse

    init(data: Data) throws {
        guard data.count >= Self.fileHeaderSize,
              Array(data.prefix(4)) == Self.magic else {
            throw LogicFormatError.badMagic(data.prefix(4).map { String(format: "%02x", $0) }.joined())
        }
        appVersion = data.u16(4)
        dataVersion = data.u16(6)
        reserved8 = data.u32(8)
        reserved12 = data.u16(12)
        sizeWidth = data.u16(14)

        let declared = Int(data.u64(16))
        guard declared == data.count - Self.fileHeaderSize else {
            throw LogicFormatError.sizeMismatch(declared: declared, actual: data.count - Self.fileHeaderSize)
        }

        var out: [LogicRecord] = []
        var off = Self.fileHeaderSize
        while off + LogicRecord.headerSize <= data.count {
            let tagBytes = [UInt8](data[data.startIndex + off ..< data.startIndex + off + 4]).reversed()
            guard tagBytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else {
                throw LogicFormatError.nonAsciiTag(at: off, bytes: tagBytes.map { String(format: "%02x", $0) }.joined())
            }
            let const22 = data.u32(off + 22), const26 = data.u16(off + 26)
            guard const22 == 2, const26 == 1 else { throw LogicFormatError.unexpectedConstants(at: off) }
            let plen = Int(data.u64(off + 28))
            let end = off + LogicRecord.headerSize + plen
            guard end <= data.count else { throw LogicFormatError.truncated(at: off) }
            out.append(LogicRecord(
                tag: String(decoding: Array(tagBytes), as: UTF8.self),
                version: data.u16(off + 4), subtype: data.u16(off + 6),
                indexRaw: data.u32(off + 8), unk12: data.u16(off + 12),
                id1: data.u32(off + 14), id2: data.u32(off + 18),
                const22: const22, const26: const26,
                payload: data.subdata(in: data.startIndex + off + LogicRecord.headerSize ..< data.startIndex + end)))
            off = end
        }
        guard !out.isEmpty else { throw LogicFormatError.noRecords }
        records = out
    }

    init(contentsOf url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    // MARK: Serialize

    /// Rebuilds the stream, recomputing the one size field the format keeps.
    func serialized() -> Data {
        let body = records.reduce(into: Data()) { acc, r in
            acc.append(contentsOf: Array(r.tag.utf8).reversed())
            acc.appendLE(r.version); acc.appendLE(r.subtype)
            acc.appendLE(r.indexRaw); acc.appendLE(r.unk12)
            acc.appendLE(r.id1); acc.appendLE(r.id2)
            acc.appendLE(r.const22); acc.appendLE(r.const26)
            acc.appendLE(UInt64(r.payload.count))
            acc.append(r.payload)
        }
        var out = Data(Self.magic)
        out.appendLE(appVersion); out.appendLE(dataVersion)
        out.appendLE(reserved8); out.appendLE(reserved12); out.appendLE(sizeWidth)
        out.appendLE(UInt64(body.count))
        out.append(body)
        return out
    }

    /// Re-parses what we just wrote. Every mutation run ends with this, so a
    /// strategy can never hand back a stream this app itself cannot read.
    func roundTrips() -> Bool { (try? LogicProject(data: serialized())) != nil }

    // MARK: Access

    func indices(ofTag tag: String) -> [Int] {
        records.indices.filter { records[$0].tag == tag }
    }

    var songIndex: Int? { records.firstIndex { $0.tag == "Song" } }

    /// Renumbers each tag group so the index field stays consecutive after
    /// records have been added, dropped or reordered.
    mutating func renumber() {
        var counts: [String: Int] = [:]
        for i in records.indices where records[i].tag != "Song" {
            let n = counts[records[i].tag, default: 0]
            records[i].setIndex(n)
            counts[records[i].tag] = n + 1
        }
    }
}

// MARK: - Song globals

extension LogicProject {
    // Offsets inside the Song payload. Stable across data version 2 and 3.
    enum SongField {
        static let tempo = 198            // u32, BPM * 10000
        static let tempoCopy = 898
        static let tempoLastUsed = [110, 114]   // present only sometimes
        static let sigNumerator = 190     // u8
        static let sigDenomLog2 = 191     // u8
        static let sigNumeratorCopy = 890
        static let sigDenomLog2Copy = 891
    }
    static let tempoScale: Double = 10_000
    /// The tempo track's own copy: the EvSq whose MSeq is subtype 3.
    static let tempoEventOffset = 16

    var tempo: Double {
        get {
            guard let s = songIndex, records[s].payload.count > SongField.tempo + 4 else { return 0 }
            return Double(records[s].payload.u32(SongField.tempo)) / Self.tempoScale
        }
        set { setTempo(newValue) }
    }

    /// Writes every copy of the tempo the corpus showed: two in `Song`, the
    /// tempo track's first event, and the two "last used" fields when they
    /// currently agree with the old value (they trail the real tempo, so
    /// leaving a stale one behind is what makes Logic show the wrong number).
    mutating func setTempo(_ bpm: Double) {
        let clamped = min(max(bpm, 5), 990)
        let raw = UInt32((clamped * Self.tempoScale).rounded())
        guard let s = songIndex else { return }
        let old = records[s].payload.u32(SongField.tempo)
        records[s].payload.writeLE(raw, at: SongField.tempo)
        records[s].payload.writeLE(raw, at: SongField.tempoCopy)
        for off in SongField.tempoLastUsed where records[s].payload.count > off + 4 {
            if records[s].payload.u32(off) == old { records[s].payload.writeLE(raw, at: off) }
        }
        for i in records.indices where records[i].tag == "EvSq" && records[i].subtype == 3 {
            if records[i].payload.count > Self.tempoEventOffset + 4,
               records[i].payload.u32(Self.tempoEventOffset) == old {
                records[i].payload.writeLE(raw, at: Self.tempoEventOffset)
            }
        }
    }

    var timeSignature: (numerator: Int, denominator: Int) {
        guard let s = songIndex, records[s].payload.count > SongField.sigDenomLog2 else { return (4, 4) }
        return (Int(records[s].payload[byte: SongField.sigNumerator]),
                1 << Int(records[s].payload[byte: SongField.sigDenomLog2]))
    }

    mutating func setTimeSignature(numerator: Int, denominator: Int) {
        guard let s = songIndex else { return }
        let num = UInt8(min(max(numerator, 1), 99))
        // Only powers of two are representable: the field stores the exponent.
        let log2den = UInt8(min(max(Int(log2(Double(max(denominator, 1)))), 1), 6))
        for (n, d) in [(SongField.sigNumerator, SongField.sigDenomLog2),
                       (SongField.sigNumeratorCopy, SongField.sigDenomLog2Copy)]
        where records[s].payload.count > d {
            records[s].payload[byte: n] = num
            records[s].payload[byte: d] = log2den
        }
    }
}

// MARK: - Payload field helpers
//
// Two string encodings coexist, both length-prefixed: single-byte for sequence
// and region names, UTF-16LE for audio filenames. Rewriting a name changes the
// payload length, which is fine — the length lives in the record header and is
// recomputed on serialize.

enum PayloadString {
    /// `u16 byteCount` + that many UTF-8 bytes. The count is bytes and not
    /// characters: a region named after a macOS timestamp carries a narrow
    /// no-break space, which is three bytes and one character, and treating it
    /// as one byte shortens the field and moves everything after it.
    static func readUTF8(_ p: Data, at off: Int, limit: Int = 512) -> String? {
        guard p.count >= off + 2 else { return nil }
        let n = Int(p.u16(off))
        guard n > 0, n <= limit, p.count >= off + 2 + n else { return nil }
        return String(decoding: p.subdata(in: p.startIndex + off + 2 ..< p.startIndex + off + 2 + n), as: UTF8.self)
    }

    /// The field is `u16 byteCount`, the bytes, then a pad byte when the count
    /// is odd — the whole field is an even number of bytes wide. Getting that
    /// pad wrong is not a cosmetic error: Logic reads the record sequentially
    /// and every field after the name lands one byte off, which it reports as a
    /// corrupted song rather than a bad name.
    static func fieldWidthUTF8(_ p: Data, at off: Int) -> Int {
        let n = Int(p.u16(off))
        return 2 + n + (n & 1)
    }

    static func writeUTF8(_ p: inout Data, at off: Int, _ s: String, limit: Int = 512) {
        guard p.count >= off + 2 else { return }
        let oldWidth = fieldWidthUTF8(p, at: off)
        guard p.count >= off + oldWidth else { return }
        // Truncated on a character boundary, so a clipped name is never left as
        // half a multi-byte sequence.
        var bytes = Array(s.utf8)
        if bytes.count > limit {
            var clipped = String(s.prefix(limit))
            while clipped.utf8.count > limit { clipped = String(clipped.dropLast()) }
            bytes = Array(clipped.utf8)
        }
        var next = p.subdata(in: p.startIndex ..< p.startIndex + off)
        next.appendLE(UInt16(bytes.count))
        next.append(contentsOf: bytes)
        if bytes.count & 1 == 1 { next.append(0) }
        next.append(p.subdata(in: p.startIndex + off + oldWidth ..< p.endIndex))
        p = next
    }

    static func readUTF16(_ p: Data, at off: Int, limit: Int = 512) -> String? {
        guard p.count >= off + 2 else { return nil }
        let n = Int(p.u16(off))
        guard n > 0, n <= limit, p.count >= off + 2 + n * 2 else { return nil }
        let units = (0..<n).map { p.u16(off + 2 + $0 * 2) }
        return String(decoding: units, as: UTF16.self)
    }

    /// UTF-16 fields need no pad — two bytes per character is already even.
    static func writeUTF16(_ p: inout Data, at off: Int, _ s: String, limit: Int = 512) {
        guard p.count >= off + 2 else { return }
        let old = Int(p.u16(off))
        guard p.count >= off + 2 + old * 2 else { return }
        let units = Array(Array(s.utf16).prefix(limit))
        var next = p.subdata(in: p.startIndex ..< p.startIndex + off)
        next.appendLE(UInt16(units.count))
        for u in units { next.appendLE(u) }
        next.append(p.subdata(in: p.startIndex + off + 2 + old * 2 ..< p.endIndex))
        p = next
    }
}

// MARK: - Known payload layouts

enum Layout {
    static let mseqName = 16          // u16 count + single-byte name
    static let aurgName = 74          // u16 count + single-byte name
    static let auflName = 8           // u16 count + UTF-16LE filename
    static let aurgFileStart = 4      // u64, 16.16 fixed-point source samples
    static let aurgLength = 20        // u64, 16.16 fixed-point source samples
    static let fixedOne: Double = 65536
}

extension LogicRecord {
    var sequenceName: String? {
        tag == "MSeq" ? PayloadString.readUTF8(payload, at: Layout.mseqName, limit: 256) : nil
    }
    var regionName: String? {
        tag == "AuRg" ? PayloadString.readUTF8(payload, at: Layout.aurgName, limit: 256) : nil
    }
    var audioFileName: String? {
        tag == "AuFl" ? PayloadString.readUTF16(payload, at: Layout.auflName, limit: 512) : nil
    }

    mutating func setSequenceName(_ s: String) {
        guard tag == "MSeq" else { return }
        PayloadString.writeUTF8(&payload, at: Layout.mseqName, s, limit: 200)
    }
    mutating func setRegionName(_ s: String) {
        guard tag == "AuRg" else { return }
        PayloadString.writeUTF8(&payload, at: Layout.aurgName, s, limit: 200)
    }
    mutating func setAudioFileName(_ s: String) {
        guard tag == "AuFl" else { return }
        PayloadString.writeUTF16(&payload, at: Layout.auflName, s, limit: 400)
    }

    /// Region extent in the *source file's* frames — not bars, and not the
    /// project's sample rate: an Apple Loop stays 44.1 kHz inside a 48 kHz song.
    var regionExtent: (start: Double, length: Double)? {
        guard tag == "AuRg", payload.count >= Layout.aurgLength + 8 else { return nil }
        return (Double(payload.u64(Layout.aurgFileStart)) / Layout.fixedOne,
                Double(payload.u64(Layout.aurgLength)) / Layout.fixedOne)
    }

    mutating func setRegionExtent(start: Double, length: Double) {
        guard tag == "AuRg", payload.count >= Layout.aurgLength + 8 else { return }
        let s = UInt64(max(0, min(start, 1e12)) * Layout.fixedOne)
        let l = UInt64(max(1, min(length, 1e12)) * Layout.fixedOne)
        payload.writeLE(s, at: Layout.aurgFileStart)
        payload.writeLE(l, at: Layout.aurgLength)
    }
}

// MARK: - Little-endian Data access

extension Data {
    func u16(_ off: Int) -> UInt16 {
        guard count >= off + 2 else { return 0 }
        return UInt16(self[startIndex + off]) | UInt16(self[startIndex + off + 1]) << 8
    }
    func u32(_ off: Int) -> UInt32 {
        guard count >= off + 4 else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + off + $1]) << (8 * UInt32($1)) }
    }
    func u64(_ off: Int) -> UInt64 {
        guard count >= off + 8 else { return 0 }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[startIndex + off + $1]) << (8 * UInt64($1)) }
    }
    subscript(byte off: Int) -> UInt8 {
        get { count > off ? self[startIndex + off] : 0 }
        set { if count > off { self[startIndex + off] = newValue } }
    }

    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
    mutating func writeLE<T: FixedWidthInteger>(_ v: T, at off: Int) {
        let width = MemoryLayout<T>.size
        guard count >= off + width else { return }
        Swift.withUnsafeBytes(of: v.littleEndian) { raw in
            for i in 0..<width { self[startIndex + off + i] = raw[i] }
        }
    }
}
