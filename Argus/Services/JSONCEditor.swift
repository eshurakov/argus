// swiftlint:disable file_length

import Foundation

enum JSONCEditor {
    enum Error: LocalizedError, Equatable {
        case malformed(String)
        case pluginIsNotAnArray
        var errorDescription: String? {
            switch self {
            case .malformed(let detail): "Invalid JSONC: \(detail)"
            case .pluginIsNotAnArray: "Kilo's plugin setting must be an array"
            }
        }
    }
    enum Operation { case enable, disable }
    static func edit(_ text: String, declaration: String, operation: Operation) throws -> String {
        var parser = Parser(text)
        let root = try parser.parseDocument()
        guard case .object(let object) = root.kind else { throw Error.malformed("root must be an object") }
        if let property = object.properties.first(where: { $0.key == "plugin" }) {
            guard case .array(let array) = property.value.kind else { throw Error.pluginIsNotAnArray }
            let matching = array.elements.first { $0.stringValue == declaration }
            switch (operation, matching) {
            case (.enable, .some), (.disable, .none): return text
            case (.enable, .none):
                let prefix: String
                if array.elements.isEmpty {
                    prefix = "\"\(escaped(declaration))\""
                } else if array.hasTrailingComma {
                    prefix = " \"\(escaped(declaration))\","
                } else {
                    prefix = ", \"\(escaped(declaration))\""
                }
                return replacing(text, range: array.closeBracket..<array.closeBracket, with: prefix)
            case (.disable, .some(let element)):
                let removal = removalRange(for: element, in: array)
                return replacing(text, range: removal, with: "")
            }
        }
        guard operation == .enable else { return text }
        return insertingPluginProperty(in: text, object: object, declaration: declaration, bytes: parser.bytes)
    }
    private static func insertingPluginProperty(
        in text: String,
        object: ObjectValue,
        declaration: String,
        bytes: [UInt8]
    ) -> String {
        let indentation = object.indentation(in: bytes)
        let property = "\"plugin\": [\"\(escaped(declaration))\"]"
        let insertion: String
        if object.properties.isEmpty {
            insertion = "\n\(indentation)\(property)\n"
        } else if object.hasTrailingComma {
            insertion = "\n\(indentation)\(property),\n"
        } else {
            insertion = ",\n\(indentation)\(property)\n"
        }
        return replacing(text, range: object.closeBrace..<object.closeBrace, with: insertion)
    }
    static func containsDeclaration(_ declaration: String, in text: String) throws -> Bool {
        var parser = Parser(text)
        let root = try parser.parseDocument()
        guard case .object(let object) = root.kind else { throw Error.malformed("root must be an object") }
        guard let property = object.properties.first(where: { $0.key == "plugin" }) else { return false }
        guard case .array(let array) = property.value.kind else { throw Error.pluginIsNotAnArray }
        return array.elements.contains { $0.stringValue == declaration }
    }
    private static func removalRange(for element: Value, in array: ArrayValue) -> Range<Int> {
        guard let index = array.elements.firstIndex(where: { $0.range == element.range }) else { return element.range }
        if index < array.elements.count - 1 {
            guard let separator = array.elements[index + 1].leadingSeparator else { return element.range }
            return element.range.lowerBound..<(separator + 1)
        }
        return element.range
    }
    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    private static func replacing(_ text: String, range: Range<Int>, with replacement: String) -> String {
        let bytes = Array(text.utf8)
        return (String(bytes: bytes[..<range.lowerBound], encoding: .utf8) ?? "")
            + replacement
            + (String(bytes: bytes[range.upperBound...], encoding: .utf8) ?? "")
    }
}
extension JSONCEditor {
    fileprivate enum ValueKind {
        case object(ObjectValue)
        case array(ArrayValue)
        case scalar
    }
    fileprivate struct Value {
        let kind: ValueKind
        let range: Range<Int>
        let stringValue: String?
        let leadingSeparator: Int?
    }
    fileprivate struct Property {
        let key: String, value: Value
    }
    fileprivate struct ObjectValue {
        let properties: [Property]
        let closeBrace: Int
        let hasTrailingComma: Bool

        func indentation(in bytes: [UInt8]) -> String {
            guard let property = properties.first else { return "  " }
            var start = property.value.range.lowerBound
            while start > 0, bytes[start - 1] != 10 { start -= 1 }
            let line = bytes[start..<property.value.range.lowerBound]
            let spaces = line.prefix { $0 == 32 || $0 == 9 }
            return String(bytes: spaces, encoding: .utf8) ?? ""
        }
    }
    fileprivate struct ArrayValue {
        let elements: [Value], openBracket: Int, closeBracket: Int, hasTrailingComma: Bool
    }
    fileprivate struct Parser {
        let bytes: [UInt8]
        var position = 0

        init(_ text: String) { bytes = Array(text.utf8) }
        mutating func parseDocument() throws -> Value {
            try skipTrivia()
            let value = try parseValue()
            try skipTrivia()
            guard position == bytes.count else { throw Error.malformed("unexpected content at byte \(position)") }
            return value
        }
        mutating func parseValue() throws -> Value {
            try skipTrivia()
            let start = position
            guard position < bytes.count else { throw Error.malformed("unexpected end of file") }
            switch bytes[position] {
            case 123: return try parseObject(start: start)
            case 91: return try parseArray(start: start)
            case 34:
                let string = try parseString()
                return Value(kind: .scalar, range: start..<position, stringValue: string, leadingSeparator: nil)
            default:
                while position < bytes.count, !isScalarBoundary(at: position) { position += 1 }
                guard start != position else { throw Error.malformed("unexpected token at byte \(position)") }
                let token = String(bytes: bytes[start..<position], encoding: .utf8) ?? ""
                guard token == "true" || token == "false" || token == "null" || JSONCEditor.isNumber(token) else {
                    throw Error.malformed("invalid value at byte \(start)")
                }
                return Value(kind: .scalar, range: start..<position, stringValue: nil, leadingSeparator: nil)
            }
        }

        private func isScalarBoundary(at index: Int) -> Bool {
            if [44, 93, 125, 32, 9, 10, 13].contains(bytes[index]) { return true }
            return bytes[index] == 47
                && index + 1 < bytes.count
                && (bytes[index + 1] == 47 || bytes[index + 1] == 42)
        }
        mutating func parseObject(start: Int) throws -> Value {
            position += 1
            try skipTrivia()
            var properties: [Property] = []
            var hasTrailingComma = false
            while position < bytes.count, bytes[position] != 125 {
                guard bytes[position] == 34 else { throw Error.malformed("object key expected at byte \(position)") }
                let key = try parseString()
                try skipTrivia()
                guard consume(58) else { throw Error.malformed("colon expected at byte \(position)") }
                let value = try parseValue()
                properties.append(Property(key: key, value: value))
                try skipTrivia()
                if consume(44) {
                    try skipTrivia()
                    hasTrailingComma = position < bytes.count && bytes[position] == 125
                } else if position < bytes.count, bytes[position] != 125 {
                    throw Error.malformed("comma expected at byte \(position)")
                }
            }
            guard consume(125) else { throw Error.malformed("unterminated object") }
            return Value(
                kind: .object(
                    ObjectValue(
                        properties: properties,
                        closeBrace: position - 1,
                        hasTrailingComma: hasTrailingComma
                    )),
                range: start..<position,
                stringValue: nil,
                leadingSeparator: nil
            )
        }
        mutating func parseArray(start: Int) throws -> Value {
            position += 1
            try skipTrivia()
            var elements: [Value] = []
            var hasTrailingComma = false
            var leadingSeparator: Int?
            while position < bytes.count, bytes[position] != 93 {
                var element = try parseValue()
                element = Value(
                    kind: element.kind,
                    range: element.range,
                    stringValue: element.stringValue,
                    leadingSeparator: leadingSeparator)
                elements.append(element)
                try skipTrivia()
                if consume(44) {
                    leadingSeparator = position - 1
                    try skipTrivia()
                    hasTrailingComma = position < bytes.count && bytes[position] == 93
                } else if position < bytes.count, bytes[position] != 93 {
                    throw Error.malformed("comma expected at byte \(position)")
                }
            }
            guard consume(93) else { throw Error.malformed("unterminated array") }
            return Value(
                kind: .array(
                    ArrayValue(
                        elements: elements,
                        openBracket: start,
                        closeBracket: position - 1,
                        hasTrailingComma: hasTrailingComma
                    )),
                range: start..<position,
                stringValue: nil,
                leadingSeparator: nil
            )
        }
        mutating func parseString() throws -> String {
            guard consume(34) else { throw Error.malformed("string expected") }
            var value = ""
            var unescapedStart = position
            while position < bytes.count {
                switch bytes[position] {
                case 34:
                    try appendUTF8(bytes[unescapedStart..<position], to: &value)
                    position += 1
                    return value
                case 92:
                    try appendUTF8(bytes[unescapedStart..<position], to: &value)
                    position += 1
                    guard position < bytes.count else { throw Error.malformed("unterminated escape") }
                    try appendEscapedCharacter(to: &value)
                    unescapedStart = position
                case 0...31:
                    throw Error.malformed("unescaped control character at byte \(position)")
                default:
                    position += 1
                }
            }
            throw Error.malformed("unterminated string")
        }
        private mutating func appendEscapedCharacter(to value: inout String) throws {
            switch bytes[position] {
            case 34:
                value.append("\"")
                position += 1
            case 92:
                value.append("\\")
                position += 1
            case 47:
                value.append("/")
                position += 1
            case 98:
                value.append("\u{08}")
                position += 1
            case 102:
                value.append("\u{0C}")
                position += 1
            case 110:
                value.append("\n")
                position += 1
            case 114:
                value.append("\r")
                position += 1
            case 116:
                value.append("\t")
                position += 1
            case 117: try appendUnicodeEscape(to: &value)
            default: throw Error.malformed("unsupported escape at byte \(position)")
            }
        }

        private mutating func appendUnicodeEscape(to value: inout String) throws {
            let first = try consumeUnicodeCodeUnit()
            switch first {
            case 0xD800...0xDBFF:
                guard position + 1 < bytes.count, bytes[position] == 92, bytes[position + 1] == 117 else {
                    throw Error.malformed("high surrogate without low surrogate at byte \(position - 4)")
                }
                position += 1
                let second = try consumeUnicodeCodeUnit()
                guard (0xDC00...0xDFFF).contains(second) else {
                    throw Error.malformed("high surrogate followed by invalid code unit at byte \(position - 4)")
                }
                let scalar = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                value.unicodeScalars.append(UnicodeScalar(scalar)!)
            case 0xDC00...0xDFFF:
                throw Error.malformed("low surrogate without high surrogate at byte \(position - 4)")
            default:
                value.unicodeScalars.append(UnicodeScalar(first)!)
            }
        }

        private mutating func consumeUnicodeCodeUnit() throws -> UInt32 {
            let escapeStart = position
            guard position + 4 < bytes.count else {
                throw Error.malformed("incomplete Unicode escape at byte \(escapeStart)")
            }
            var value: UInt32 = 0
            for index in (position + 1)...(position + 4) {
                guard let digit = hexDigit(bytes[index]) else {
                    throw Error.malformed("invalid Unicode escape at byte \(index)")
                }
                value = value << 4 | digit
            }
            position += 5
            return value
        }

        private func appendUTF8(_ raw: ArraySlice<UInt8>, to value: inout String) throws {
            guard let text = String(bytes: raw, encoding: .utf8) else {
                throw Error.malformed("invalid UTF-8 string at byte \(position)")
            }
            value += text
        }

        private func hexDigit(_ byte: UInt8) -> UInt32? {
            switch byte {
            case 48...57: UInt32(byte - 48)
            case 65...70: UInt32(byte - 55)
            case 97...102: UInt32(byte - 87)
            default: nil
            }
        }

        mutating func skipTrivia() throws {
            while position < bytes.count {
                if [32, 9, 10, 13].contains(bytes[position]) {
                    position += 1
                    continue
                }
                if bytes[position] == 47, position + 1 < bytes.count, bytes[position + 1] == 47 {
                    position += 2
                    while position < bytes.count, bytes[position] != 10 { position += 1 }
                    continue
                }
                if bytes[position] == 47, position + 1 < bytes.count, bytes[position + 1] == 42 {
                    position += 2
                    while position + 1 < bytes.count, !(bytes[position] == 42 && bytes[position + 1] == 47) {
                        position += 1
                    }
                    guard position + 1 < bytes.count else {
                        throw Error.malformed("unterminated block comment at byte \(position - 2)")
                    }
                    position += 2
                    continue
                }
                break
            }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard position < bytes.count, bytes[position] == byte else { return false }
            position += 1
            return true
        }
    }
}

extension JSONCEditor {
    fileprivate static func isNumber(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        var position = bytes.first == 45 ? 1 : 0
        guard let integerEnd = integerEnd(in: bytes, from: position) else { return false }
        position = integerEnd
        if byte(at: position, in: bytes) == 46 {
            guard let end = digitsEnd(in: bytes, from: position + 1) else { return false }
            position = end
        }
        if let exponent = byte(at: position, in: bytes), exponent == 69 || exponent == 101 {
            position += 1
            if let sign = byte(at: position, in: bytes), sign == 43 || sign == 45 { position += 1 }
            guard let end = digitsEnd(in: bytes, from: position) else { return false }
            position = end
        }
        return position == bytes.count
    }
    fileprivate static func integerEnd(in bytes: [UInt8], from position: Int) -> Int? {
        guard let first = byte(at: position, in: bytes) else { return nil }
        if first == 48 { return position + 1 }
        return (49...57).contains(first) ? digitsEnd(in: bytes, from: position) : nil
    }
    fileprivate static func digitsEnd(in bytes: [UInt8], from position: Int) -> Int? {
        guard byte(at: position, in: bytes).map({ (48...57).contains($0) }) == true else { return nil }
        var end = position + 1
        while byte(at: end, in: bytes).map({ (48...57).contains($0) }) == true { end += 1 }
        return end
    }
    fileprivate static func byte(at position: Int, in bytes: [UInt8]) -> UInt8? {
        bytes.indices.contains(position) ? bytes[position] : nil
    }
}
