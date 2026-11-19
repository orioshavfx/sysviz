import Foundation

/// Цвет в 24-битном RGB.
struct RGB: Equatable {
    var r: Int
    var g: Int
    var b: Int

    /// Разбирает строку вида "#rrggbb". Всё остальное даёт nil.
    init?(hex: String) {
        guard hex.count == 7, hex.hasPrefix("#") else { return nil }
        let digits = hex.dropFirst()
        guard digits.allSatisfy({ $0.isHexDigit }),
              let value = Int(digits, radix: 16) else { return nil }
        r = (value >> 16) & 0xff
        g = (value >> 8) & 0xff
        b = value & 0xff
    }

    init(r: Int, g: Int, b: Int) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Линейная интерполяция: t = 0 даёт self, t = 1 даёт other.
    func mixed(with other: RGB, _ t: Double) -> RGB {
        let k = min(max(t, 0), 1)
        func lerp(_ a: Int, _ b: Int) -> Int { Int((Double(a) + (Double(b) - Double(a)) * k).rounded()) }
        return RGB(r: lerp(r, other.r), g: lerp(g, other.g), b: lerp(b, other.b))
    }

    /// ESC[38;2;r;g;bm — цвет символов.
    var ansiForeground: String { "\u{1b}[38;2;\(r);\(g);\(b)m" }
}

enum ColorMode: String {
    case gradient
    case solid
}

/// Настройки из ~/.config/sysviz/config.toml.
/// Формат: `key = value`, строки с # — комментарии, текст в кавычках.
/// Нет файла или ключа — берётся значение по умолчанию (как было в коде до конфига).
/// Число вне диапазона зажимается в границы, некорректное значение игнорируется.
struct Config {
    var bars = 64
    var barGap = 1
    var framerate = 30
    var colorMode = ColorMode.solid
    var color = RGB(r: 255, g: 255, b: 255)
    var colorLow = RGB(r: 255, g: 255, b: 255)
    var colorHigh = RGB(r: 255, g: 255, b: 255)

    static let barsRange = 8...128
    static let barGapRange = 0...16
    static let framerateRange = 15...120

    static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sysviz/config.toml").path
    }

    static func load(path: String = defaultPath) -> Config {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return Config()
        }
        return parse(text)
    }

    static func parse(_ text: String) -> Config {
        var config = Config()
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard let value = parseValue(String(line[line.index(after: eq)...])) else { continue }

            switch key {
            case "bars":
                if let n = Int(value) { config.bars = clamp(n, barsRange) }
            case "bar_gap":
                if let n = Int(value) { config.barGap = clamp(n, barGapRange) }
            case "framerate":
                if let n = Int(value) { config.framerate = clamp(n, framerateRange) }
            case "color_mode":
                if let mode = ColorMode(rawValue: value.lowercased()) { config.colorMode = mode }
            case "color":
                if let c = RGB(hex: value) { config.color = c }
            case "color_low":
                if let c = RGB(hex: value) { config.colorLow = c }
            case "color_high":
                if let c = RGB(hex: value) { config.colorHigh = c }
            default:
                break  // неизвестные ключи пропускаем
            }
        }
        return config
    }

    /// Значение после `=`: строка в кавычках берётся до закрывающей кавычки,
    /// у значения без кавычек отрезается хвостовой комментарий `# ...`.
    private static func parseValue(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let quote = s.first, quote == "\"" || quote == "'" {
            let rest = s.dropFirst()
            guard let end = rest.firstIndex(of: quote) else { return nil }
            return String(rest[..<end])
        }
        let bare = s.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let value = bare.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func clamp(_ n: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(n, range.lowerBound), range.upperBound)
    }
}
