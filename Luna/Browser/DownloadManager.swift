// Luma MVP - Download manager and hub
import Foundation
import SwiftUI
import AppKit
import Combine

/// A single recent download for the hub.
struct DownloadItem: Identifiable {
    let id: UUID
    let url: URL
    let fileURL: URL
    let suggestedFilename: String
    let date: Date

    init(id: UUID = UUID(), url: URL, fileURL: URL, suggestedFilename: String, date: Date = Date()) {
        self.id = id
        self.url = url
        self.fileURL = fileURL
        self.suggestedFilename = suggestedFilename
        self.date = date
    }
}

/// Manages recent downloads; files are saved to ~/Downloads.
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var recentDownloads: [DownloadItem] = []
    private let maxRecent = 50
    private let fileManager = FileManager.default

    var downloadsDirectory: URL {
        fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }

    private init() {}

    /// Call when a file was saved to path (from WKDownload or URLSession).
    func addDownload(url: URL, fileURL: URL, suggestedFilename: String) {
        let item = DownloadItem(url: url, fileURL: fileURL, suggestedFilename: suggestedFilename)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.recentDownloads.insert(item, at: 0)
            if self.recentDownloads.count > self.maxRecent {
                self.recentDownloads.removeLast()
            }
        }
    }

    /// Open the file in its default application.
    func open(_ item: DownloadItem) {
        NSWorkspace.shared.open(item.fileURL)
    }

    /// Reveal the file in Finder.
    func revealInFinder(_ item: DownloadItem) {
        NSWorkspace.shared.selectFile(item.fileURL.path, inFileViewerRootedAtPath: item.fileURL.deletingLastPathComponent().path)
    }

    /// Remove an item from the recent downloads list (does not delete the file on disk).
    func removeItem(_ item: DownloadItem) {
        DispatchQueue.main.async { [weak self] in
            self?.recentDownloads.removeAll { $0.id == item.id }
        }
    }

    /// Remove an item by id.
    func removeItem(id: UUID) {
        DispatchQueue.main.async { [weak self] in
            self?.recentDownloads.removeAll { $0.id == id }
        }
    }
}
