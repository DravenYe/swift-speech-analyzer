import Foundation
import Speech
import AVFoundation
import NaturalLanguage

// MARK: - Language Detection

// NLLanguage → SpeechTranscriber locale 映射
let languageLocaleMap: [NLLanguage: String] = [
    .simplifiedChinese:  "zh-CN",
    .traditionalChinese: "zh-TW",
    .english:            "en-US",
    .japanese:           "ja-JP",
    .korean:             "ko-KR",
    .french:             "fr-FR",
    .german:             "de-DE",
    .spanish:            "es-ES",
    .portuguese:         "pt-BR",
    .italian:            "it-IT",
    .dutch:              "nl-NL",
    .russian:            "ru-RU",
    .arabic:             "ar-SA",
]

func detectLocale(from text: String) -> Locale {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let lang = recognizer.dominantLanguage,
          let identifier = languageLocaleMap[lang] else {
        return .current
    }
    return Locale(identifier: identifier)
}

// MARK: - Locale Normalization

// 把系统 Locale（如 zh-Hans_US）规范化为 SpeechTranscriber 支持的格式（如 zh-CN）
func normalizeLocale(_ locale: Locale) -> Locale {
    let lang = locale.language.languageCode?.identifier ?? "en"
    let script = locale.language.script?.identifier ?? ""

    switch lang {
    case "zh": return Locale(identifier: script == "Hant" ? "zh-TW" : "zh-CN")
    case "en": return Locale(identifier: "en-US")
    case "ja": return Locale(identifier: "ja-JP")
    case "ko": return Locale(identifier: "ko-KR")
    case "fr": return Locale(identifier: "fr-FR")
    case "de": return Locale(identifier: "de-DE")
    case "es": return Locale(identifier: "es-ES")
    case "pt": return Locale(identifier: "pt-BR")
    case "it": return Locale(identifier: "it-IT")
    case "nl": return Locale(identifier: "nl-NL")
    case "ru": return Locale(identifier: "ru-RU")
    case "ar": return Locale(identifier: "ar-SA")
    default:   return Locale(identifier: "\(lang)-\(locale.region?.identifier ?? "US")")
    }
}

// MARK: - Model Management

func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
    let bcp47 = locale.identifier(.bcp47)

    let supported = await SpeechTranscriber.supportedLocales
    guard supported.contains(where: { $0.identifier(.bcp47) == bcp47 }) else {
        print("❌ 不支持该语言: \(locale.identifier)"); exit(1)
    }

    let installed = await SpeechTranscriber.installedLocales
    guard !installed.contains(where: { $0.identifier(.bcp47) == bcp47 }) else { return }

    print("📥 正在下载语言模型（仅首次需要）...")
    if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await downloader.downloadAndInstall()
        print("✅ 语言模型下载完成\n")
    }
}

// MARK: - File Transcription

func collectResults(from transcriber: SpeechTranscriber, showTimestamps: Bool) async throws -> String {
    var fullText = ""
    for try await result in transcriber.results {
        if showTimestamps {
            for run in result.text.runs {
                let word = String(result.text[run.range].characters)
                if let timeRange = run.audioTimeRange {
                    let ts = String(format: "[%.2fs]", timeRange.start.seconds)
                    print("  \(ts) \(word)")
                }
            }
        }
        fullText += String(result.text.characters)
    }
    return fullText
}

func runTranscription(url: URL, locale: Locale, showTimestamps: Bool) async throws -> String {
    let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: showTimestamps ? [.audioTimeRange] : []
    )
    try await ensureModel(for: transcriber, locale: locale)

    async let textFuture = collectResults(from: transcriber, showTimestamps: showTimestamps)
    let audioFile = try AVAudioFile(forReading: url)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
        try await analyzer.finalizeAndFinish(through: lastSample)
    }
    return try await textFuture
}

func transcribeFile(url: URL, langArg: String?, showTimestamps: Bool) async throws {
    guard FileManager.default.fileExists(atPath: url.path) else {
        print("❌ 文件不存在: \(url.path)"); exit(1)
    }

    let locale: Locale

    if langArg == "auto" {
        // 第一遍用 en-US 探测，取样本检测语言
        print("🔍 正在检测语言...\n")
        let probeTranscriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        try await ensureModel(for: probeTranscriber, locale: Locale(identifier: "en-US"))

        async let probeFuture = collectResults(from: probeTranscriber, showTimestamps: false)
        let probeFile = try AVAudioFile(forReading: url)
        let probeAnalyzer = SpeechAnalyzer(modules: [probeTranscriber])
        if let last = try await probeAnalyzer.analyzeSequence(from: probeFile) {
            try await probeAnalyzer.finalizeAndFinish(through: last)
        }
        let probeText = try await probeFuture

        locale = detectLocale(from: probeText)
        print("🌐 检测到语言: \(locale.identifier)\n")

        // 如果检测结果就是 en-US，直接用探测结果，不需要第二遍
        if locale.identifier.hasPrefix("en") {
            print("🎵 正在转写: \(url.lastPathComponent)\n")
            if showTimestamps { print("📝 完整文本:") } else { print("📝 转写结果:") }
            print(probeText)
            return
        }
    } else {
        locale = langArg.map { Locale(identifier: $0) } ?? normalizeLocale(.current)
    }

    print("🎵 正在转写: \(url.lastPathComponent)\n")
    let text = try await runTranscription(url: url, locale: locale, showTimestamps: showTimestamps)
    if showTimestamps { print("\n📝 完整文本:") } else { print("📝 转写结果:") }
    print(text)
}

// MARK: - Live Transcription

func startLive(locale: Locale) async throws {
    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

    try await ensureModel(for: transcriber, locale: locale)

    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        print("❌ 无法获取音频格式"); exit(1)
    }

    let audioEngine = AVAudioEngine()
    let inputNode = audioEngine.inputNode
    let hardwareFormat = inputNode.outputFormat(forBus: 0)
    let converter = AVAudioConverter(from: hardwareFormat, to: analyzerFormat)!

    let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
    let analyzer = SpeechAnalyzer(inputSequence: inputSequence, modules: [transcriber])

    inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buffer, _ in
        let ratio = analyzerFormat.sampleRate / hardwareFormat.sampleRate
        let frameCount = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard frameCount > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: frameCount) else { return }
        var didProvide = false
        var convError: NSError?
        converter.convert(to: outBuffer, error: &convError) { _, status in
            guard !didProvide else { status.pointee = .noDataNow; return nil }
            didProvide = true
            status.pointee = .haveData
            return buffer
        }
        guard convError == nil, outBuffer.frameLength > 0 else { return }
        inputBuilder.yield(AnalyzerInput(buffer: outBuffer))
    }

    try audioEngine.start()
    print("🎤 实时识别中（\(locale.identifier)）... 按 Ctrl+C 结束\n")

    var onVolatileLine = false
    var lastVolatilePreview = ""

    let recognizerTask = Task {
        for try await result in transcriber.results {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if result.isFinal {
                if onVolatileLine { print("\r\u{1B}[K", terminator: "") }
                print(text)
                onVolatileLine = false
                lastVolatilePreview = ""
            } else {
                let preview = String(text.prefix(80))
                guard preview != lastVolatilePreview else { continue }
                print("\r\u{1B}[K\u{1B}[2m⟳ \(preview)\u{1B}[0m", terminator: "")
                lastVolatilePreview = preview
                onVolatileLine = true
            }
            fflush(stdout)
        }
    }

    var timeoutTask: Task<Void, Never>? = nil

    signal(SIGINT, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler {
        print("\n⏸ 停止录音，正在完成剩余转写...\n")
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputBuilder.finish()
        Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(8))
            recognizerTask.cancel()
        }
    }
    sigintSource.resume()

    try? await recognizerTask.value
    timeoutTask?.cancel()
    if onVolatileLine { print() }
    print("⏹ 完成")
}

// MARK: - Usage

func printUsage() {
    print("""
    用法:
      转写文件:     ./transcribe file <路径> [--timestamps]
      实时麦克风:   ./transcribe live
      指定语言:     ./transcribe file <路径> --lang en-US
      自动检测语言: ./transcribe file <路径> --lang auto

    支持格式: mp3, m4a, wav, aiff, flac, caf 等
    支持语言: zh-CN, zh-TW, en-US, ja-JP, ko-KR, fr-FR, de-DE 等
    需要: macOS 26+
    """)
}

// MARK: - Entry Point

let args = CommandLine.arguments
guard args.count >= 2 else { printUsage(); exit(1) }

let langIndex = args.firstIndex(of: "--lang").map { $0 + 1 }
let langArg = langIndex.map { args[$0] }  // nil = 系统语言, "auto" = 自动检测, 其他 = 指定语言
let showTimestamps = args.contains("--timestamps")

// live 模式：auto 回退到系统语言（规范化）
let liveLocale = (langArg == nil || langArg == "auto")
    ? normalizeLocale(.current)
    : Locale(identifier: langArg!)

Task {
    do {
        switch args[1] {
        case "file":
            guard args.count >= 3 else { print("❌ 请提供音频文件路径"); exit(1) }
            try await transcribeFile(url: URL(fileURLWithPath: args[2]), langArg: langArg, showTimestamps: showTimestamps)
        case "live":
            try await startLive(locale: liveLocale)
        default:
            print("❌ 未知命令: \(args[1])")
            printUsage()
        }
    } catch {
        print("❌ 错误: \(error.localizedDescription)")
    }
    exit(0)
}

RunLoop.main.run()
