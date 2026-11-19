import Foundation
import CoreAudio

// Настройки из ~/.config/sysviz/config.toml (см. Config.swift).
let config = Config.load()

let fftSize = 2048
let bandCount = config.bars
let barGap = config.barGap  // пустых колонок между полосами
let minFrequency = 40.0
let maxFrequency = 16_000.0
let frameRate = Double(config.framerate)

// Фиксированная шкала в dB: всё, что тише dbFloor, даёт 0, громче dbCeil — полную высоту.
let dbFloor: Float = -75
let dbCeil: Float = -18

var shouldQuit = false
var originalTermios = termios()
var rawModeEnabled = false

/// Спектр по логарифмическим полосам через прямое DFT на нужных частотах.
/// При 64 полосах и окне 2048 это дешёво, а FFT-обвязка не нужна.
final class Analyzer {
    private let window: [Float]
    private let windowSum: Float
    private let freqs: [Double]
    private let cosTable: [Float]
    private let sinTable: [Float]
    private var peakDB: [Float] = [Float](repeating: -60, count: bandCount)

    init(sampleRate: Double) {
        window = (0..<fftSize).map { n -> Float in
            Float(0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(fftSize - 1)))
        }
        windowSum = window.reduce(0, +)

        let top = min(maxFrequency, sampleRate / 2 - 200)
        freqs = (0..<bandCount).map { b in
            minFrequency * pow(top / minFrequency, Double(b) / Double(bandCount - 1))
        }

        var cosValues: [Float] = []
        var sinValues: [Float] = []
        cosValues.reserveCapacity(bandCount * fftSize)
        sinValues.reserveCapacity(bandCount * fftSize)
        for f in freqs {
            for n in 0..<fftSize {
                let phase = 2 * Double.pi * f * Double(n) / sampleRate
                cosValues.append(Float(cos(phase)))
                sinValues.append(Float(sin(phase)))
            }
        }
        cosTable = cosValues
        sinTable = sinValues
    }

    /// Уровни 0...1 для каждой полосы по фиксированной шкале dB.
    func levels(_ x: [Float]) -> [Float] {
        let windowed = (0..<fftSize).map { x[$0] * window[$0] }
        var levels = [Float](repeating: 0, count: bandCount)

        for b in 0..<bandCount {
            var re: Float = 0
            var im: Float = 0
            let base = b * fftSize
            for n in 0..<fftSize {
                re += windowed[n] * cosTable[base + n]
                im += windowed[n] * sinTable[base + n]
            }
            let amplitude = 2 * sqrt(re * re + im * im) / windowSum
            // Лёгкий наклон: частично компенсирует то, что музыка в басах громче.
            let tilt = Float(1.0 * log2(freqs[b] / 100))
            let db = 20 * log10(max(amplitude, 1e-6)) + tilt
            // Каждая полоса нормируется по своему недавнему пику: спад 0.2 dB за кадр.
            peakDB[b] = max(db, peakDB[b] - 0.2)
            let range: Float = 40
            levels[b] = min(max((db - (peakDB[b] - range)) / range, 0), 1)
        }
        return levels
    }
}

let blocks = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

/// Отрисовка столбиков на всю высоту окна. Цвет из конфига:
/// solid — один цвет, gradient — от colorLow внизу до colorHigh вверху, по строкам.
func render(bars: [Float], cols: Int, rows: Int) -> String {
    let barRows = max(rows, 1)
    let count = bars.count
    let totalEighths = barRows * 8
    var out = "\u{1b}[H"
    if config.colorMode == .solid {
        out += config.color.ansiForeground
    }

    // Границы полос в колонках: сумма ширин ровно равна cols, остаток не теряется.
    let edges = (0...count).map { $0 * cols / count }

    for row in 0..<barRows {
        let fromBottom = barRows - 1 - row
        if config.colorMode == .gradient {
            let t = barRows > 1 ? Double(fromBottom) / Double(barRows - 1) : 0
            out += config.colorLow.mixed(with: config.colorHigh, t).ansiForeground
        }
        for (i, bar) in bars.enumerated() {
            let width = edges[i + 1] - edges[i]
            // Промежуток между полосами; у узкой полосы (1 колонка) промежутка нет,
            // чтобы сумма ширин всегда оставалась равна cols.
            let gap = width > barGap ? barGap : 0
            let cell = min(max(Int(bar * Float(totalEighths)) - fromBottom * 8, 0), 8)
            let glyph = cell == 0 ? " " : blocks[cell - 1]
            out += String(repeating: glyph, count: width - gap)
            out += String(repeating: " ", count: gap)
        }
        out += "\u{1b}[K"
        if row < barRows - 1 {
            out += "\n"
        }
    }
    return out + "\u{1b}[0m"
}

/// Переводит терминал в режим посимвольного ввода без эха.
/// ISIG оставляем включённым, чтобы Ctrl+C продолжал работать.
func enableRawInput() {
    guard tcgetattr(STDIN_FILENO, &originalTermios) == 0 else { return }
    var raw = originalTermios
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
    withUnsafeMutableBytes(of: &raw.c_cc) { bytes in
        bytes[Int(VMIN)] = 0
        bytes[Int(VTIME)] = 0
    }
    if tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 {
        rawModeEnabled = true
    }
}

/// Читает всё, что нажато к этому моменту, и обрабатывает q.
func handleKeys() {
    var c: UInt8 = 0
    while read(STDIN_FILENO, &c, 1) == 1 {
        if c == UInt8(ascii: "q") || c == UInt8(ascii: "Q") {
            shouldQuit = true
        }
    }
}

func restoreTerminal() {
    fputs("\u{1b}[0m\u{1b}[?25h\u{1b}[?1049l", stdout)
    fflush(stdout)
    if rawModeEnabled {
        tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
    }
}

let tap = SystemAudioTap(keepCount: fftSize * 4)
do {
    try tap.start()
} catch {
    fputs("Ошибка: \(error)\n", stderr)
    tap.stop()
    exit(1)
}

let analyzer = Analyzer(sampleRate: tap.sampleRate)

// Ctrl+C только выставляет флаг, выход делает основной цикл.
signal(SIGINT) { _ in shouldQuit = true }

enableRawInput()
fputs("\u{1b}[?1049h\u{1b}[?25l\u{1b}[2J", stdout)
fflush(stdout)

var bars = [Float](repeating: 0, count: bandCount)

while !shouldQuit {
    let frameStart = Date()

    handleKeys()

    var ws = winsize()
    _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws)
    let cols = Int(ws.ws_col)
    let rows = Int(ws.ws_row)

    let levels = analyzer.levels(tap.latest(count: fftSize))

    // Быстрая атака и медленный спад, чтобы столбики не дёргались.
    for i in 0..<bandCount {
        let v = levels[i]
        bars[i] = v > bars[i] ? bars[i] * 0.4 + v * 0.6 : bars[i] * 0.8 + v * 0.2
    }

    fputs(render(bars: bars, cols: cols, rows: rows), stdout)
    fflush(stdout)

    let spent = Date().timeIntervalSince(frameStart)
    let wait = 1 / frameRate - spent
    if wait > 0 {
        usleep(UInt32(wait * 1_000_000))
    }
}

restoreTerminal()
tap.stop()
