import Foundation

/// Where a song that did not come from NetEase lives: the LX platform it
/// belongs to, the script that found it, and that script's own description
/// of it (LX's `musicInfo`), handed back verbatim when the song needs a URL
/// or lyrics.
struct ExternalTrackRef: Codable, Hashable, Sendable {
    /// LX platform id: `kw`, `mg`, `tx`, … or a script's own, e.g. `qsvip`.
    let platform: String
    let platformName: String
    let scriptID: UUID?
    /// The `musicInfo` JSON object as the script returned it.
    let musicInfo: Data

    var musicInfoObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: musicInfo)) as? [String: Any] ?? [:]
    }
}

/// Translation between LX Music's song objects and `Track`.
enum LXMusicInfo {
    /// Normalises one search result. Scripts return LX's legacy shape
    /// (`songmid`, `singer`, `albumName`, `interval`, `img`) or something
    /// close to it, so every field has a few spellings to try.
    static func track(from object: [String: Any], platform: String, platformName: String, scriptID: UUID?) -> Track? {
        let meta = object["meta"] as? [String: Any] ?? [:]
        guard let name = firstString(object, ["name", "songname", "title"]), !name.isEmpty else { return nil }
        let singer = firstString(object, ["singer", "artist", "artists", "singerName"]) ?? ""
        let album = firstString(object, ["albumName", "album"]) ?? firstString(meta, ["albumName"]) ?? ""
        let picture = firstString(object, ["img", "pic", "picUrl", "cover", "albumPic"])
            ?? firstString(meta, ["picture", "picUrl", "img"])
        let durationMS = durationMilliseconds(object)
        let songID = songID(in: object)
        let key = songID ?? "\(name)|\(singer)|\(album)"

        var musicInfo = object
        // Scripts look for the song id under different names; make sure the
        // usual ones are present when the script gave only one.
        if let songID {
            for field in ["songmid", "id"] where musicInfo[field] == nil {
                musicInfo[field] = songID
            }
        }
        if musicInfo["source"] == nil { musicInfo["source"] = platform }
        if musicInfo["albumName"] == nil, !album.isEmpty { musicInfo["albumName"] = album }
        if musicInfo["singer"] == nil, !singer.isEmpty { musicInfo["singer"] = singer }
        guard let data = try? JSONSerialization.data(withJSONObject: musicInfo) else { return nil }

        return Track(
            external: ExternalTrackRef(platform: platform, platformName: platformName, scriptID: scriptID, musicInfo: data),
            id: syntheticID(platform: platform, key: key),
            name: name,
            artists: splitArtists(singer),
            albumName: album,
            picUrl: picture.map { $0.hasPrefix("//") ? "https:\($0)" : $0 },
            durationMS: durationMS
        )
    }

    /// The `musicInfo` a script receives for `track`: the stored original for
    /// an external song, LX's legacy `wy` shape for a NetEase one.
    static func musicInfo(for track: Track) -> [String: Any] {
        if let external = track.external { return external.musicInfoObject }
        let id = String(track.id)
        var info: [String: Any] = [
            "id": id,
            "songmid": id,
            "hash": id,
            "name": track.name,
            "singer": track.artists.map(\.name).joined(separator: "、"),
            "albumName": track.album.name,
            "albumId": String(track.album.id),
            "source": "wy",
            "interval": interval(seconds: Int(track.duration)),
            "meta": [
                "songId": id,
                "albumName": track.album.name,
                "picUrl": track.album.picUrl ?? "",
            ] as [String: Any],
        ]
        if let picUrl = track.album.picUrl { info["img"] = picUrl }
        return info
    }

    /// A stable, negative id for a song from an LX source. FNV-1a, not
    /// `Hasher`, whose seed changes every launch: the id is persisted with
    /// the play queue and keys the audio cache.
    static func syntheticID(platform: String, key: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "lx:\(platform):\(key)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return -Int(hash & 0x3fff_ffff_ffff_ffff) - 1
    }

    /// The best LX quality name a source offers for the app's quality setting,
    /// stepping down when the source does not list the requested one.
    static func quality(for quality: AudioQuality, supported: [String]) -> String {
        let ladder = ["flac24bit", "hires", "24bit", "flac", "320k", "192k", "128k"]
        let requested: String
        switch quality {
        case .standard: requested = "128k"
        case .higher: requested = "192k"
        case .exhigh: requested = "320k"
        case .lossless: requested = "flac"
        case .hires: requested = "flac24bit"
        }
        guard !supported.isEmpty else { return requested }
        if supported.contains(requested) { return requested }
        let start = ladder.firstIndex(of: requested) ?? ladder.count - 1
        for name in ladder[start...] where supported.contains(name) { return name }
        return supported.first(where: { ladder.contains($0) }) ?? supported[0]
    }

    // MARK: - Field helpers

    static func songID(in object: [String: Any]) -> String? {
        let meta = object["meta"] as? [String: Any] ?? [:]
        return firstString(object, ["songmid", "hash", "id", "rid", "copyrightId", "strMediaMid", "mid", "songId"])
            ?? firstString(meta, ["songId", "hash", "mid"])
    }

    static func durationMilliseconds(_ object: [String: Any]) -> Int {
        if let interval = object["interval"] as? String, let seconds = seconds(fromInterval: interval), seconds > 0 {
            return seconds * 1000
        }
        for key in ["duration", "interval", "dt", "time"] {
            if let number = (object[key] as? NSNumber)?.doubleValue ?? (object[key] as? String).flatMap(Double.init), number > 0 {
                // Seconds unless it is clearly milliseconds.
                return number > 36_000 ? Int(number) : Int(number * 1000)
            }
        }
        return 0
    }

    /// "04:29" or "1:02:03" → seconds.
    static func seconds(fromInterval interval: String) -> Int? {
        let parts = interval.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    static func interval(seconds: Int) -> String {
        String(format: "%02ld:%02ld", max(0, seconds) / 60, max(0, seconds) % 60)
    }

    static func splitArtists(_ singer: String) -> [String] {
        let names = singer
            .components(separatedBy: CharacterSet(charactersIn: "、/&,，;；"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return names.isEmpty ? [] : names
    }

    private static func firstString(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            } else if let value = object[key] as? NSNumber {
                return value.stringValue
            }
        }
        return nil
    }
}
