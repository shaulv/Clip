import Foundation
import AppKit

/// Persists heavy clipboard payloads (images) to disk and loads them back.
/// Text is stored inline in history.json; images/files go here.
final class MediaStore {
    static let shared = MediaStore()

    private let fileManager = FileManager.default

    let mediaDir: URL
    private lazy var imageCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        return c
    }()

    private init() {
        mediaDir = AppPaths.media
    }

    // MARK: - Save

    /// The first save failure this launch has already been reported. A disk
    /// that stays full does not need a second identical notice for every
    /// clipboard image copied afterwards - it needs the one that told the
    /// person what happened, and `NoticeCenter.report(key:)` keeps that
    /// notice current rather than piling up duplicates anyway, but the
    /// underlying condition is worth naming once per episode, not per byte.
    private var reportedSaveFailure = false

    /// Persists raw data and returns the filename it was stored under, or
    /// `nil` when the write failed. This used to swallow the error outright:
    /// a full disk or an unwritable Media folder stopped every image capture
    /// silently, for ever, while ordinary text kept copying fine right next
    /// to it - nothing distinguished "no image was copied" from "an image
    /// was copied and lost".
    @discardableResult
    func save(_ data: Data, ext: String) -> String? {
        let name = "\(UUID().uuidString).\(ext)"
        let url = mediaDir.appendingPathComponent(name)
        do {
            try data.write(to: url)
            return name
        } catch {
            if !reportedSaveFailure {
                reportedSaveFailure = true
                _ = MainActor.assumeIsolated {
                    NoticeCenter.shared.report(.mediaSaveFailed(detail: "\(mediaDir.path): \(error.localizedDescription)"))
                }
            }
            return nil
        }
    }

    #if CLIP_TESTING
    func resetSaveFailureReportForTesting() { reportedSaveFailure = false }
    #endif

    // MARK: - Load

    func url(for name: String) -> URL? {
        let u = mediaDir.appendingPathComponent(name)
        return fileManager.fileExists(atPath: u.path) ? u : nil
    }

    func data(for name: String) -> Data? {
        guard let url = url(for: name) else { return nil }
        return try? Data(contentsOf: url)
    }

    func image(for name: String) -> NSImage? {
        let key = name as NSString
        if let hit = imageCache.object(forKey: key) { return hit }
        guard let data = data(for: name), let img = NSImage(data: data) else { return nil }
        imageCache.setObject(img, forKey: key)
        return img
    }

    func cgImage(for name: String, maxDimension: CGFloat = 900) -> CGImage? {
        guard let data = data(for: name) else { return nil }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    // MARK: - Delete

    /// How many files this launch have been asked to go and would not. Kept
    /// running across separate `delete` calls (a "Clear unpinned" or "Clear
    /// everything" is many single deletes, not one bulk one) so the notice
    /// reads as the true total left behind rather than restarting at one
    /// each time and looking like the same single file failing repeatedly.
    private var residueThisLaunch = 0

    /// Removes one media file. Returns `true` when the file is gone
    /// afterwards - including when it was already gone, which is not a
    /// failure - and `false` when it is still there. This used to report
    /// nothing either way, so "Clear everything" could say the library was
    /// empty while the Media folder still held every file.
    @discardableResult
    func delete(_ name: String?) -> Bool {
        guard let name else { return true }
        imageCache.removeObject(forKey: name as NSString)
        guard let url = url(for: name) else { return true }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            residueThisLaunch += 1
            _ = MainActor.assumeIsolated {
                NoticeCenter.shared.report(.mediaRemoveFailed(count: residueThisLaunch))
            }
            return false
        }
    }

    /// Empties the Media folder. Returns how many files could not be removed.
    @discardableResult
    func purgeAll() -> Int {
        var failedHere = 0
        if let files = try? fileManager.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil) {
            for f in files {
                do { try fileManager.removeItem(at: f) } catch { failedHere += 1 }
            }
        }
        imageCache.removeAllObjects()
        if failedHere > 0 {
            residueThisLaunch += failedHere
            _ = MainActor.assumeIsolated {
                NoticeCenter.shared.report(.mediaRemoveFailed(count: residueThisLaunch))
            }
        }
        return failedHere
    }

    #if CLIP_TESTING
    func resetResidueForTesting() { residueThisLaunch = 0 }
    #endif
}
