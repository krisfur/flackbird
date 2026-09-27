import Foundation

/// Reads tags and embedded artwork from a FLAC file's metadata blocks.
/// AVFoundation does not surface FLAC VORBIS_COMMENT or PICTURE blocks
/// through common metadata, so this parses the container format directly.
enum FlacMetadata {
    static func read(from url: URL, readArtwork: Bool = true) -> TrackMetadata {
        var metadata = TrackMetadata()
        guard let file = try? FileHandle(forReadingFrom: url) else { return metadata }
        defer { try? file.close() }
        guard let magic = try? file.read(upToCount: 4), magic == Data("fLaC".utf8) else { return metadata }

        var fallbackArtwork: Data?
        loop: while true {
            guard let header = try? file.read(upToCount: 4), header.count == 4 else { break }
            let isLast = header[0] & 0x80 != 0
            let blockType = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            switch blockType {
            case 4: // VORBIS_COMMENT
                guard let block = try? file.read(upToCount: length), block.count == length else { break loop }
                parseVorbisComments(block, into: &metadata)
            case 6 where readArtwork: // PICTURE
                guard let block = try? file.read(upToCount: length), block.count == length else { break loop }
                if let picture = parsePicture(block) {
                    if picture.type == 3 {
                        metadata.artworkData = picture.data
                    } // front cover wins
                    else if fallbackArtwork == nil {
                        fallbackArtwork = picture.data
                    }
                }
            default:
                guard let offset = try? file.offset(),
                      (try? file.seek(toOffset: offset + UInt64(length))) != nil else { break loop }
            }
            if isLast {
                break
            }
        }
        if metadata.artworkData == nil {
            metadata.artworkData = fallbackArtwork
        }
        return metadata
    }

    /// Reads STREAMINFO, which the format requires as the first block. The bitrate
    /// counts only the audio frames, so tags and cover art don't inflate it.
    static func quality(from url: URL) -> AudioQuality? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let magic = try? file.read(upToCount: 4), magic == Data("fLaC".utf8),
              let header = try? file.read(upToCount: 4), header.count == 4, header[0] & 0x7F == 0,
              let info = try? file.read(upToCount: 34), info.count == 34 else { return nil }
        // Bytes 10-17: sample rate (20 bits), channels - 1 (3), bits per sample - 1 (5), total samples (36).
        let packed = info[10 ..< 18].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let sampleRate = Double(packed >> 44)
        let bitDepth = Int((packed >> 36) & 0x1F) + 1
        let totalSamples = Double(packed & 0xF_FFFF_FFFF)
        guard sampleRate > 0 else { return nil }

        var isLast = header[0] & 0x80 != 0
        while !isLast {
            guard let next = try? file.read(upToCount: 4), next.count == 4, let offset = try? file.offset() else { return nil }
            isLast = next[0] & 0x80 != 0
            let length = UInt64(next[1]) << 16 | UInt64(next[2]) << 8 | UInt64(next[3])
            guard (try? file.seek(toOffset: offset + length)) != nil else { return nil }
        }
        var kilobits: Int?
        if totalSamples > 0, let audioStart = try? file.offset(), let end = try? file.seekToEnd(), end > audioStart {
            let seconds = totalSamples / sampleRate
            kilobits = Int((Double(end - audioStart) * 8 / seconds / 1000).rounded())
        }
        return AudioQuality(format: "FLAC", bitDepth: bitDepth, sampleRate: sampleRate, kilobitsPerSecond: kilobits)
    }

    private static func parseVorbisComments(_ block: Data, into metadata: inout TrackMetadata) {
        var cursor = 0
        func readLE32() -> Int? {
            guard cursor + 4 <= block.count else { return nil }
            let value = Int(block[cursor]) | Int(block[cursor + 1]) << 8
                | Int(block[cursor + 2]) << 16 | Int(block[cursor + 3]) << 24
            cursor += 4
            return value
        }
        guard let vendorLength = readLE32(), cursor + vendorLength <= block.count else { return }
        cursor += vendorLength
        guard let commentCount = readLE32() else { return }
        for _ in 0 ..< commentCount {
            guard let length = readLE32(), cursor + length <= block.count else { return }
            defer { cursor += length }
            guard let comment = String(data: block[cursor ..< (cursor + length)], encoding: .utf8),
                  let separator = comment.firstIndex(of: "=") else { continue }
            let value = String(comment[comment.index(after: separator)...])
            guard !value.isEmpty else { continue }
            switch comment[..<separator].uppercased() {
            case "TITLE": metadata.title = metadata.title ?? value
            case "ARTIST": metadata.artist = metadata.artist ?? value
            case "ALBUM": metadata.album = metadata.album ?? value
            case "ALBUMARTIST": metadata.albumArtist = metadata.albumArtist ?? value
            case "TRACKNUMBER": metadata.trackNumber = metadata.trackNumber ?? leadingNumber(value)
            case "DISCNUMBER": metadata.discNumber = metadata.discNumber ?? leadingNumber(value)
            default: break
            }
        }
    }

    /// Parses the leading integer of values like "3" or "3/12".
    private static func leadingNumber(_ value: String) -> Int? {
        value.split(separator: "/").first.flatMap { Int($0) }
    }

    private static func parsePicture(_ block: Data) -> (type: UInt32, data: Data)? {
        var cursor = 0
        func readUInt32() -> UInt32? {
            guard cursor + 4 <= block.count else { return nil }
            let value = block[cursor ..< (cursor + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            cursor += 4
            return value
        }
        func skip(_ count: Int) -> Bool {
            guard cursor + count <= block.count else { return false }
            cursor += count
            return true
        }
        guard let pictureType = readUInt32(),
              let mimeLength = readUInt32(), skip(Int(mimeLength)),
              let descriptionLength = readUInt32(), skip(Int(descriptionLength)),
              skip(16), // width, height, colour depth, palette size
              let dataLength = readUInt32(),
              cursor + Int(dataLength) <= block.count
        else { return nil }
        return (pictureType, block.subdata(in: cursor ..< (cursor + Int(dataLength))))
    }
}
