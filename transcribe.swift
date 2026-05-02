import Foundation
import Speech
import AVFoundation

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

// 独立 async 函数，与 analyzeSequence 并发运行
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

func transcribeFile(url: URL, locale: Locale, showTimestamps: Bool) async throws {
    guard FileManager.default.fileExists(atPath: url.path) else {
        print("❌ 文件不存在: \(url.path)"); exit(1)
    }

    let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: showTimestamps ? [.audioTimeRange] : []
    )

    try await ensureModel(for: transcriber, locale: locale)
    print("🎵 正在转写: \(url.lastPathComponent)\n")

    // 并发：结果收集与文件分析同时进行
    async let textFuture = collectResults(from: transcriber, showTimestamps: showTimestamps)

    let audioFile = try AVAudioFile(forReading: url)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
        try await analyzer.finalizeAndFinish(through: lastSample)
    }

    let text = try await textFuture

    if showTimestamps { print("\n📝 完整文本:") } else { print("📝 转写结果:") }
    print(text)
}

// MARK: - Live Transcription

func startLive(locale: Locale) async throws {
    let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [.volatileResults],
        attributeOptions: []
    )

    try await ensureModel(for: transcriber, locale: locale)

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        print("❌ 无法获取音频格式"); exit(1)
    }

    let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
    try await analyzer.start(inputSequence: inputSequence)

    // 音频引擎 + 格式转换
    let audioEngine = AVAudioEngine()
    let inputNode = audioEngine.inputNode
    let hardwareFormat = inputNode.outputFormat(forBus: 0)

    guard let converter = AVAudioConverter(from: hardwareFormat, to: analyzerFormat) else {
        print("❌ 无法创建音频格式转换器"); exit(1)
    }

    inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buffer, _ in
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * analyzerFormat.sampleRate / hardwareFormat.sampleRate
        )
        guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: frameCapacity) else { return }
        var err: NSError?
        converter.convert(to: converted, error: &err) { _, status in
            status.pointee = .haveData
            return buffer
        }
        if err == nil { inputBuilder.yield(AnalyzerInput(buffer: converted)) }
    }

    try audioEngine.start()
    print("🎤 实时识别中（本地）... 按 Ctrl+C 结束\n")

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
                // 内容没变就不刷新，避免刷屏
                let preview = String(text.prefix(80))
                guard preview != lastVolatilePreview else { continue }
                print("\r\u{1B}[K\u{1B}[2m⟳ \(preview)\u{1B}[0m", terminator: "")
                lastVolatilePreview = preview
                onVolatileLine = true
            }
            fflush(stdout)
        }
    }

    // Ctrl+C：停止录音，通知 analyzer 结束，最多等 5 秒输出剩余内容
    signal(SIGINT, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler {
        print("\n⏸ 停止录音，正在完成剩余转写（最多等 5 秒）...\n")
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputBuilder.finish()
        Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    }
    sigintSource.resume()

    // 等待识别完成，超时则强制退出
    let timeout = Task {
        try? await Task.sleep(for: .seconds(8))
        recognizerTask.cancel()
    }
    try? await recognizerTask.value
    timeout.cancel()
    if onVolatileLine { print() }
    print("⏹ 完成")
}

// MARK: - Usage

func printUsage() {
    print("""
    用法:
      转写文件:   ./transcribe file <路径> [--timestamps]
      实时麦克风: ./transcribe live
      指定语言:   ./transcribe file <路径> --lang en-US

    支持格式: mp3, m4a, wav, aiff, flac, caf 等
    支持语言: zh-CN, zh-TW, en-US, ja-JP 等
    需要: macOS 26+
    """)
}

// MARK: - Entry Point

let args = CommandLine.arguments
guard args.count >= 2 else { printUsage(); exit(1) }

let langIndex = args.firstIndex(of: "--lang").map { $0 + 1 }
let locale = Locale(identifier: langIndex.map { args[$0] } ?? "zh-CN")
let showTimestamps = args.contains("--timestamps")

Task {
    do {
        switch args[1] {
        case "file":
            guard args.count >= 3 else { print("❌ 请提供音频文件路径"); exit(1) }
            try await transcribeFile(url: URL(fileURLWithPath: args[2]), locale: locale, showTimestamps: showTimestamps)
        case "live":
            try await startLive(locale: locale)
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
