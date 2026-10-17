import Foundation
import UniformTypeIdentifiers

public enum MIMEType {
    /// Explicit table for web types so behaviour never depends on the system's UTType database.
    private static let table: [String: String] = [
        "html": "text/html", "htm": "text/html", "xhtml": "application/xhtml+xml",
        "js": "text/javascript", "mjs": "text/javascript", "cjs": "text/javascript",
        "css": "text/css",
        "json": "application/json", "map": "application/json", "webmanifest": "application/manifest+json",
        "txt": "text/plain", "md": "text/markdown", "csv": "text/csv", "xml": "application/xml",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "avif": "image/avif", "ico": "image/x-icon",
        "bmp": "image/bmp", "heic": "image/heic", "icns": "image/icns", "tif": "image/tiff", "tiff": "image/tiff",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "wasm": "application/wasm",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "wav": "audio/wav", "ogg": "audio/ogg", "opus": "audio/opus",
        "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "webm": "video/webm",
        "pdf": "application/pdf", "zip": "application/zip",
    ]

    public static func forPath(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        if let known = table[ext] { return known }
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    public static func isText(_ mime: String) -> Bool {
        mime.hasPrefix("text/") || ["application/json", "application/xml", "application/xhtml+xml",
                                    "image/svg+xml", "application/manifest+json"].contains(mime)
    }
}
