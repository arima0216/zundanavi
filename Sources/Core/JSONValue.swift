import Foundation

/// サーバーの JSON を型に厳しくなく読むための汎用値。
/// 契約の型が揺れても（数値/文字列/真偽）落ちないようにする。
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    static func parse(_ data: Data) throws -> JSONValue {
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// 文字列として読む（数値・真偽も文字にする）。null と入れ物は nil。
    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let d): return JSONValue.formatNumber(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var intValue: Int? {
        guard let d = doubleValue, d.isFinite else { return nil }
        return Int(d)
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .string(let s):
            let l = s.lowercased()
            if ["true", "ok", "yes", "1", "up"].contains(l) { return true }
            if ["false", "ng", "no", "0", "down"].contains(l) { return false }
            return nil
        default: return nil
        }
    }

    /// 画面表示用の短い文字列。入れ物は JSON 文字列にする。
    var displayText: String? {
        switch self {
        case .null: return nil
        case .string, .number, .bool: return stringValue
        case .array(let a):
            let parts = a.compactMap { $0.displayText }
            return parts.isEmpty ? nil : parts.joined(separator: " / ")
        case .object:
            if let data = try? JSONEncoder().encode(self), let s = String(data: data, encoding: .utf8) {
                return s
            }
            return nil
        }
    }

    static func formatNumber(_ d: Double) -> String {
        if d.isFinite && d == d.rounded() && abs(d) < 1e15 {
            return String(Int64(d))
        }
        return String(d)
    }
}
