import Foundation

enum ReleaseNotesContent {
    case markdown(source: String, baseURL: URL?)
    case failed(String)
}

enum ReleaseNotesService {
    static func load(bundle: Bundle = .main) -> ReleaseNotesContent {
        load(resourceURL: bundle.url(forResource: "CHANGELOG", withExtension: "md"))
    }

    static func load(resourceURL: URL?) -> ReleaseNotesContent {
        guard let resourceURL else {
            return .failed("The bundled changelog could not be found.")
        }

        do {
            return .markdown(
                source: try String(contentsOf: resourceURL, encoding: .utf8),
                baseURL: resourceURL.deletingLastPathComponent()
            )
        } catch {
            return .failed("The bundled changelog could not be read: \(error.localizedDescription)")
        }
    }
}
