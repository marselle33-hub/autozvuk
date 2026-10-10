import AVFoundation
import WebKit
import UIKit

/// Мостик между страницей и звуком iOS.
/// Страница присылает команды (включить микрофон, сыграть сигнал, тон генератора),
/// а мы играем и записываем звук сами — в режиме «играть и записывать одновременно»,
/// где iOS не уводит звук с провода AUX на динамик телефона, как это делает Safari.
final class AudioBridge: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    weak var webView: WKWebView?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var toneNode: AVAudioSourceNode!
    private let rate: Double = 48000
    private var micOn = false
    private var engineReady = false
    private var strategy = "measure"
    private var inputRate: Double = 48000
    private var loadedFallback = false

    // Генератор тона: меняется из главного потока, читается в звуковом
    private var toneOn = false
    private var toneFreq: Double = 50
    private var toneTarget: Float = 0
    private var toneGain: Float = 0
    private var tonePan: Float = 0
    private var tonePulse = false
    private var phase: Double = 0
    private var pulsePos = 0

    override init() {
        super.init()
        engine.attach(player)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        toneNode = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frameCount, abl -> OSStatus in
            self.renderTone(frameCount: Int(frameCount), abl: abl)
            return noErr
        }
        engine.attach(toneNode)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)),
                                               name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(engineChanged(_:)),
                                               name: .AVAudioEngineConfigurationChange, object: engine)
    }

    // MARK: - Загрузка страницы

    func loadRemote() {
        loadedFallback = false
        let req = URLRequest(url: remotePageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        webView?.load(req)
    }

    private func loadBundled() {
        guard !loadedFallback, let url = Bundle.main.url(forResource: "polarity", withExtension: "html") else { return }
        loadedFallback = true
        webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    @objc func pullToRefresh(_ sender: UIRefreshControl) {
        if micOn { micStop() }
        loadRemote()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { sender.endRefreshing() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadBundled()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadBundled()
    }

    // MARK: - Команды от страницы

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            replyHandler(nil, "Неверная команда"); return
        }
        switch cmd {
        case "micStart": micStart(strategy: body["strategy"] as? String ?? "measure", reply: replyHandler)
        case "micStop": micStop(); replyHandler(routeInfo(), nil)
        case "play": play(body, reply: replyHandler)
        case "stop": player.stop(); replyHandler(true, nil)
        case "tone": tone(body); replyHandler(true, nil)
        case "route": replyHandler(routeInfo(), nil)
        default: replyHandler(nil, "Неизвестная команда \(cmd)")
        }
    }

    // MARK: - Микрофон

    private func micStart(strategy: String, reply: @escaping (Any?, String?) -> Void) {
        let go: (Bool) -> Void = { granted in
            DispatchQueue.main.async {
                guard granted else { reply(nil, "denied"); return }
                do {
                    if self.micOn { self.micStop() }
                    try self.configureSession(strategy)
                    try self.startEngine(mic: true)
                    reply(self.routeInfo(), nil)
                } catch {
                    reply(nil, error.localizedDescription)
                }
            }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: go)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(go)
        }
    }

    private func micStop() {
        if micOn { engine.inputNode.removeTap(onBus: 0) }
        micOn = false
    }

    private func configureSession(_ strategy: String) throws {
        self.strategy = strategy
        let s = AVAudioSession.sharedInstance()
        if engine.isRunning { engine.stop() }
        switch strategy {
        case "a2dp":
            try s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
        case "multi":
            try s.setCategory(.multiRoute, mode: .default, options: [])
        case "playback":
            try s.setCategory(.playback, mode: .default, options: [])
        default:
            // Режим измерения: без шумоподавления и автоусиления
            try s.setCategory(.playAndRecord, mode: .measurement, options: [])
        }
        try? s.setPreferredSampleRate(rate)
        try s.setActive(true)
        if s.category != .playback,
           let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? s.setPreferredInput(mic)
        }
    }

    private func startEngine(mic: Bool) throws {
        if engine.isRunning { engine.stop() }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        engine.connect(toneNode, to: engine.mainMixerNode, format: fmt)
        if mic {
            let input = engine.inputNode
            let inFmt = input.outputFormat(forBus: 0)
            guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else {
                throw NSError(domain: "audio", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Микрофон недоступен"])
            }
            inputRate = inFmt.sampleRate
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buffer, _ in
                self?.send(buffer)
            }
        }
        micOn = mic
        engine.prepare()
        try engine.start()
        engineReady = true
    }

    /// Кусок записи с микрофона — отправляем странице
    private func send(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        let b64 = Data(bytes: ch, count: n * MemoryLayout<Float>.size).base64EncodedString()
        let r = inputRate
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("window.__nativeChunk&&window.__nativeChunk('\(b64)',\(r))",
                                              completionHandler: nil)
        }
    }

    // MARK: - Воспроизведение

    private func play(_ body: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard let ls = body["L"] as? String, let dl = Data(base64Encoded: ls) else {
            reply(nil, "Нет данных для воспроизведения"); return
        }
        let dr = (body["R"] as? String).flatMap { Data(base64Encoded: $0) } ?? dl
        let n = dl.count / 4
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else {
            reply(nil, "Пустой сигнал"); return
        }
        buf.frameLength = AVAudioFrameCount(n)
        dl.withUnsafeBytes { raw in
            if let p = raw.baseAddress { memcpy(buf.floatChannelData![0], p, n * 4) }
        }
        dr.withUnsafeBytes { raw in
            if let p = raw.baseAddress { memcpy(buf.floatChannelData![1], p, min(n, dr.count / 4) * 4) }
        }
        do { try ensureRunning() } catch { reply(nil, error.localizedDescription); return }
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        player.play()
        reply(routeInfo(), nil)
    }

    private func ensureRunning() throws {
        if engine.isRunning { return }
        if !engineReady { try configureSession("playback") }
        try startEngine(mic: micOn)
    }

    // MARK: - Генератор тона

    private func tone(_ body: [String: Any]) {
        if let f = body["freq"] as? Double { toneFreq = f }
        if let v = body["vol"] as? Double { toneTarget = Float(v) }
        if let p = body["pan"] as? Double { tonePan = Float(p) }
        if let w = body["wave"] as? String { tonePulse = (w == "pulse"); pulsePos = 0 }
        if let on = body["on"] as? Bool {
            toneOn = on
            if on { try? ensureRunning() }
        }
    }

    private func renderTone(frameCount: Int, abl: UnsafeMutablePointer<AudioBufferList>) {
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        guard bufs.count >= 2,
              let l = bufs[0].mData?.assumingMemoryBound(to: Float.self),
              let r = bufs[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        let target: Float = toneOn ? toneTarget : 0
        let f = toneFreq, pan = tonePan, pulse = tonePulse
        let gl = min(1, 1 - pan), gr = min(1, 1 + pan)
        let period = max(1, Int(rate / max(1, min(f, 20))))
        let fc = max(30, f), sig = 0.2 / fc, h = Int(4 * sig * rate)
        for i in 0..<frameCount {
            toneGain += (target - toneGain) * 0.002
            var v: Float
            if pulse {
                let k = pulsePos - h
                if abs(k) <= h {
                    let t = Double(k) / rate
                    v = Float(cos(2 * .pi * fc * t) * exp(-t * t / (2 * sig * sig)))
                } else { v = 0 }
                pulsePos = (pulsePos + 1) % period
            } else {
                v = Float(sin(phase))
                phase += 2 * .pi * f / rate
                if phase > 2 * .pi { phase -= 2 * .pi }
            }
            v *= toneGain
            l[i] = v * gl
            r[i] = v * gr
        }
    }

    // MARK: - Маршрут звука

    private func routeInfo() -> [String: Any] {
        let s = AVAudioSession.sharedInstance()
        let route = s.currentRoute
        return [
            "outputs": route.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" },
            "inputs": route.inputs.map { "\($0.portName) [\($0.portType.rawValue)]" },
            "category": s.category.rawValue,
            "mode": s.mode.rawValue,
            "inputRate": inputRate,
            "rate": s.sampleRate,
            "strategy": strategy
        ]
    }

    @objc private func routeChanged(_ n: Notification) {
        DispatchQueue.main.async { self.push("__nativeRoute", self.routeInfo()) }
    }

    @objc private func engineChanged(_ n: Notification) {
        DispatchQueue.main.async {
            if self.engineReady { try? self.startEngine(mic: self.micOn) }
            self.push("__nativeRoute", self.routeInfo())
        }
    }

    private func push(_ fn: String, _ obj: Any) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: d, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.\(fn)&&window.\(fn)(\(json))", completionHandler: nil)
    }
}
