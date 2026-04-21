import Foundation

struct VideoQuality: Identifiable, Hashable {
    let id: String // yt-dlp format_id
    let resolution: String // e.g. "1080p", "720p"
    let ext: String
    let filesize: Int?
    let codec: String // full vcodec string from yt-dlp
    let description: String // human-readable label

    var isH264: Bool {
        codec.hasPrefix("avc1") || codec.hasPrefix("h264")
    }

    var displayLabel: String {
        if let filesize, filesize > 0 {
            let mb = Double(filesize) / 1_000_000
            return "\(resolution) (\(String(format: "%.0f", mb)) MB)"
        }
        return resolution
    }
}
