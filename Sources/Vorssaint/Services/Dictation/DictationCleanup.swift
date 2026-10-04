// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Accelerate
import Foundation

// MARK: - Ollama cleanup

/// Runs superwhisper's s1-mini through a local Ollama server to polish a
/// transcript, and lists or pulls models for Settings.
struct DictationOllamaClient {
    var host: String

    init(host: String) {
        self.host = host.hasSuffix("/") ? String(host.dropLast()) : host
    }

    struct Options {
        var styling: String
        var structure: String
        var context: String
    }

    enum Failure: LocalizedError {
        case unreachable
        case badResponse(String)
        var errorDescription: String? {
            switch self {
            case .unreachable: return "Ollama isn't reachable. Is it running? (ollama serve)"
            case .badResponse(let message): return "Ollama error: \(message)"
            }
        }
    }

    private static let systemPrompt =
        "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."

    func clean(_ transcript: String, model: String, options: Options) async throws -> String {
        let control = "[Styling: \(options.styling)] [Structure: \(options.structure)] [Context: \(options.context)]"
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "think": false,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": "\(control)\n\(transcript)"],
            ],
            "options": ["temperature": 0.0],
        ]
        let data = try await post("/api/chat", body: body)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badResponse("Unparseable response")
        }
        if let error = json["error"] as? String { throw Failure.badResponse(error) }
        guard let message = json["message"] as? [String: Any], let content = message["content"] as? String else {
            throw Failure.badResponse("Missing message content")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isReachable() async -> Bool {
        guard let url = URL(string: "\(host)/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func listModels() async throws -> [String] {
        guard let url = URL(string: "\(host)/api/tags") else { throw Failure.unreachable }
        let data: Data
        do { data = try await URLSession.shared.data(from: url).0 } catch { throw Failure.unreachable }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    /// Streams a pull, reporting a 0...1 fraction (or -1 while indeterminate)
    /// and Ollama's status line.
    func pull(model: String, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard let url = URL(string: "\(host)/api/pull") else { throw Failure.unreachable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.badResponse("pull failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = object["error"] as? String { throw Failure.badResponse(error) }
            let status = object["status"] as? String ?? ""
            if let total = object["total"] as? Double, let completed = object["completed"] as? Double, total > 0 {
                progress(completed / total, status)
            } else {
                progress(-1, status)
            }
        }
    }

    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: "\(host)\(path)") else { throw Failure.unreachable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw Failure.unreachable }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.badResponse(String(data: data, encoding: .utf8) ?? "HTTP error")
        }
        return data
    }
}

// MARK: - Waveform

/// Spectral energy in `bars` bands, low to high, normalized to 0...1 so quiet
/// speech still moves the bars.
final class DictationFFT {
    private let size: Int
    private let halfSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]

    init(size: Int = 1024) {
        self.size = size
        halfSize = size / 2
        log2n = vDSP_Length(log2(Float(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func magnitudes(from input: [Float], bars: Int) -> [Float] {
        guard !input.isEmpty, bars > 0 else { return [Float](repeating: 0, count: max(0, bars)) }
        var frame = [Float](repeating: 0, count: size)
        let take = min(size, input.count)
        let start = input.count - take
        for index in 0..<take { frame[index] = input[start + index] }
        var windowed = [Float](repeating: 0, count: size)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(size))

        var real = [Float](repeating: 0, count: halfSize)
        var imaginary = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        // Voice energy sits low in the spectrum; give it most of the bars.
        let usable = max(bars, halfSize / 2)
        let perBar = max(1, usable / bars)
        var result = [Float](repeating: 0, count: bars)
        for bar in 0..<bars {
            let lower = bar * perBar
            let upper = min(lower + perBar, magnitudes.count)
            guard lower < upper else { continue }
            var sum: Float = 0
            for index in lower..<upper { sum += magnitudes[index] }
            result[bar] = log10(1 + sum / Float(upper - lower) * 40)
        }
        let ceiling = max(result.max() ?? 0, 0.6)
        return result.map { min(1, $0 / ceiling) }
    }
}
