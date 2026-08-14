import Foundation
import SwiftDiffs

struct ArgusDiffInput: Equatable, Sendable {
    let oldFile: ArgusDiffFile
    let newFile: ArgusDiffFile
    let options: ArgusDiffOptions

    var packageInput: DiffInput {
        .files(old: oldFile.packageFile, new: newFile.packageFile)
    }

    var packageConfiguration: DiffConfiguration {
        DiffConfiguration(
            layout: options.style.packageLayout,
            appearance: options.theme.packageAppearance,
            context: .collapsible()
        )
    }
}

struct ArgusDiffFile: Equatable, Sendable {
    let name: String
    let contents: String
    let language: String?

    init(name: String, contents: String, language: String? = nil) {
        self.name = name
        self.contents = contents
        self.language = language
    }

    var packageFile: DiffFile {
        DiffFile(path: name, contents: contents, language: DiffLanguage(argusIdentifier: language))
    }
}

struct ArgusDiffOptions: Equatable, Sendable {
    let theme: ArgusDiffTheme
    let style: ArgusDiffStyle
}

enum ArgusDiffTheme: String, Sendable {
    case light
    case dark

    var packageAppearance: DiffAppearance {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }
}

enum ArgusDiffStyle: String, Sendable {
    case split
    case unified

    var packageLayout: DiffLayout {
        switch self {
        case .split: .sideBySide
        case .unified: .unified
        }
    }
}

extension DiffLanguage {
    init?(argusIdentifier: String?) {
        guard let argusIdentifier else { return nil }
        self.init(rawValue: argusIdentifier)
    }
}
