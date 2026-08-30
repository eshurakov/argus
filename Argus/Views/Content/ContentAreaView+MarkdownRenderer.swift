// ContentAreaView+MarkdownRenderer.swift
// Argus

import SwiftUI

enum MarkdownRenderedBlock: Sendable {
    case heading(level: Int, content: AttributedString)
    case paragraph(AttributedString)
    case listItem(marker: String, depth: Int, content: AttributedString)
    case quote(AttributedString)
    case code(language: String?, content: AttributedString)
    case thematicBreak
    case table([MarkdownRenderedTableRow])
}

struct MarkdownRenderedTableRow: Sendable {
    let isHeader: Bool
    var cells: [AttributedString]
}

private struct MarkdownRunGroup {
    let identity: Int
    let components: [PresentationIntent.IntentType]
    var content: AttributedString
}

enum MarkdownRenderer {
    static func blocks(source: String, baseURL: URL?) -> [MarkdownRenderedBlock] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard
            let markdown = try? AttributedString(
                markdown: source,
                options: options,
                baseURL: baseURL
            )
        else {
            return [.paragraph(AttributedString(source))]
        }

        var groups: [MarkdownRunGroup] = []
        for run in markdown.runs {
            guard let components = run.presentationIntent?.components,
                let leaf = components.first
            else { continue }

            let content = AttributedString(markdown[run.range])
            if groups.last?.identity == leaf.identity {
                groups[groups.count - 1].content.append(content)
            } else {
                groups.append(
                    MarkdownRunGroup(
                        identity: leaf.identity,
                        components: components,
                        content: content
                    ))
            }
        }

        var result: [MarkdownRenderedBlock] = []
        var index = 0
        while index < groups.count {
            let group = groups[index]
            if let currentTableIdentity = tableIdentity(in: group.components) {
                var tableGroups: [MarkdownRunGroup] = []
                while index < groups.count,
                    tableIdentity(in: groups[index].components) == currentTableIdentity
                {
                    tableGroups.append(groups[index])
                    index += 1
                }
                result.append(.table(tableRows(from: tableGroups)))
                continue
            }

            result.append(block(from: group))
            index += 1
        }

        return result
    }

    private static func block(from group: MarkdownRunGroup) -> MarkdownRenderedBlock {
        guard let leafKind = group.components.first?.kind else {
            return .paragraph(group.content)
        }
        if let directBlock = directBlock(kind: leafKind, content: group.content) {
            return directBlock
        }
        if let listBlock = listBlock(from: group) {
            return listBlock
        }
        if group.components.contains(where: isBlockQuote) {
            return .quote(group.content)
        }
        return .paragraph(group.content)
    }

    private static func directBlock(
        kind: PresentationIntent.Kind,
        content: AttributedString
    ) -> MarkdownRenderedBlock? {
        switch kind {
        case .header(let level):
            return .heading(level: level, content: content)
        case .codeBlock(let language):
            return .code(language: language, content: content)
        case .thematicBreak:
            return .thematicBreak
        default:
            return nil
        }
    }

    private static func listBlock(from group: MarkdownRunGroup) -> MarkdownRenderedBlock? {
        guard
            let listItem = group.components.first(where: {
                if case .listItem = $0.kind { return true }
                return false
            })
        else { return nil }

        let ordinal: Int
        if case .listItem(let value) = listItem.kind {
            ordinal = value
        } else {
            ordinal = 1
        }
        let listKinds = group.components.compactMap { component -> Bool? in
            switch component.kind {
            case .unorderedList:
                return false
            case .orderedList:
                return true
            default:
                return nil
            }
        }
        let marker = listKinds.first == true ? "\(ordinal)." : "•"
        return .listItem(
            marker: marker,
            depth: max(0, listKinds.count - 1),
            content: group.content
        )
    }

    private static func isBlockQuote(_ component: PresentationIntent.IntentType) -> Bool {
        if case .blockQuote = component.kind { return true }
        return false
    }

    private static func tableIdentity(
        in components: [PresentationIntent.IntentType]
    ) -> Int? {
        components.first(where: {
            if case .table = $0.kind { return true }
            return false
        })?.identity
    }

    private static func tableRows(
        from groups: [MarkdownRunGroup]
    ) -> [MarkdownRenderedTableRow] {
        let columnCount =
            groups.first?.components.compactMap { component -> Int? in
                if case .table(let columns) = component.kind { return columns.count }
                return nil
            }.first ?? 0

        var rows: [(identity: Int, row: MarkdownRenderedTableRow)] = []
        for group in groups {
            guard
                let rowComponent = group.components.first(where: { component in
                    switch component.kind {
                    case .tableHeaderRow, .tableRow:
                        return true
                    default:
                        return false
                    }
                }),
                let column = group.components.compactMap({ component -> Int? in
                    if case .tableCell(let value) = component.kind { return value }
                    return nil
                }).first
            else { continue }

            let isHeader: Bool
            if case .tableHeaderRow = rowComponent.kind {
                isHeader = true
            } else {
                isHeader = false
            }

            if rows.last?.identity != rowComponent.identity {
                rows.append(
                    (
                        rowComponent.identity,
                        MarkdownRenderedTableRow(
                            isHeader: isHeader,
                            cells: Array(
                                repeating: AttributedString(""),
                                count: max(columnCount, column + 1)
                            )
                        )
                    ))
            }

            if column >= rows[rows.count - 1].row.cells.count {
                rows[rows.count - 1].row.cells.append(
                    contentsOf: Array(
                        repeating: AttributedString(""),
                        count: column - rows[rows.count - 1].row.cells.count + 1
                    ))
            }
            rows[rows.count - 1].row.cells[column] = group.content
        }

        return rows.map(\.row)
    }
}
