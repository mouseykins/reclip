import Foundation

enum DownloadFormat: String, CaseIterable, Identifiable {
    case mp4 = "MP4"
    case mp3 = "MP3"

    var id: String { rawValue }
}
