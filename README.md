# swift-speech-analyzer

A macOS command-line tool for real-time and batch speech-to-text transcription, built on Apple's native **SpeechAnalyzer** and **SpeechTranscriber** frameworks introduced in macOS 26.

## Why This Instead of Whisper?

| | swift-speech-analyzer | Whisper |
|---|---|---|
| On-device | ✅ Always | ✅ |
| Privacy | ✅ Zero network requests | ✅ |
| Latency | ✅ Real-time, ultra-low | ⚠️ Higher |
| macOS integration | ✅ Native | ❌ |
| Setup | ✅ No dependencies | ⚠️ Python + model download |
| Languages | ✅ Auto model download | ✅ |

## Requirements

- macOS 26+
- Xcode 26 Beta (for SDK — not needed at runtime)

## Installation

```bash
git clone https://github.com/DravenYe/swift-speech-analyzer.git
cd swift-speech-analyzer
make build
```

> **Note:** Requires Xcode 26 Beta to compile. Set it as the active developer directory before building:
> ```bash
> sudo xcode-select -s /path/to/Xcode-beta.app/Contents/Developer
> ```

## Usage

### Transcribe an Audio File

```bash
./transcribe file recording.m4a
```

With word-level timestamps:

```bash
./transcribe file recording.m4a --timestamps
```

### Real-time Microphone Transcription

```bash
./transcribe live
```

Press `Ctrl+C` to stop.

### Specify Language

```bash
./transcribe file recording.m4a --lang en-US
./transcribe live --lang ja-JP
```

Defaults to `zh-CN` if not specified.

### Supported Audio Formats

`mp3` `m4a` `wav` `aiff` `flac` `caf` `aac`

### Supported Languages

Any locale supported by Apple's SpeechTranscriber. Common examples:

| Code | Language |
|---|---|
| `zh-CN` | Mandarin (Simplified) |
| `zh-TW` | Mandarin (Traditional) |
| `en-US` | English |
| `ja-JP` | Japanese |
| `ko-KR` | Korean |
| `fr-FR` | French |
| `de-DE` | German |

Language models are downloaded automatically on first use.

## How It Works

This tool uses two Apple frameworks introduced at WWDC 2025:

- **`SpeechAnalyzer`** — manages the analysis session and coordinates modules
- **`SpeechTranscriber`** — performs on-device speech-to-text using Apple's neural models

```
Audio Input
    │
    ▼
SpeechAnalyzer (session)
    │
    └── SpeechTranscriber (module)
            │
            ├── volatile results  →  real-time preview
            └── final results     →  committed transcription
```

For file transcription, `AVAudioFile` handles decoding — enabling support for all formats AVFoundation can read, including MP3.

For live transcription, `AVAudioEngine` captures microphone input, converts it to the format expected by `SpeechAnalyzer`, and streams buffers via `AsyncStream<AnalyzerInput>`.

All processing happens **on-device**. No audio data leaves your Mac.

## License

MIT
