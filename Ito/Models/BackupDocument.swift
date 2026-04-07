import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Custom UTType for Ito Backup Files natively configured.
    nonisolated static let itoBackup = UTType(exportedAs: "moe.itoapp.backup", conformingTo: .data)
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.itoBackup] }

    var fileURL: URL?

    init(url: URL) {
        self.fileURL = url
    }

    init(configuration: ReadConfiguration) throws {
        // When reading from the file importer, the system temporarily provides access to this URL
        // We will just store it so the BackupManager can process it. 
        // FileDocument expects data extraction here, but because we are dealing with SQLite databases,
        // it's much safer to pass the URL to GRDB directly instead of loading an entire database into RAM as Data.
        // SwiftUI's fileImporter can just provide the URL directly, so we might not even strictly *need* FileDocument for reading,
        // but it is useful for standardizing the type.
        self.fileURL = nil
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let url = fileURL else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try FileWrapper(url: url, options: .immediate)
    }
}
