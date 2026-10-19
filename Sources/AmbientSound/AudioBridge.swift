import AudioToolbox
import CoreAudio
import Foundation

/// マイク入力 → リングバッファ → イヤホン出力 を行う。
/// 入力・出力それぞれに独立した AUHAL(HAL Output) を使うので、別デバイスの組み合わせも可能。
/// 音声はリングバッファ（メモリ上の約 1 秒分）を通るだけで、ディスクやネットワークには出さない。
final class AudioBridge {
    struct Config {
        let inputID: AudioDeviceID
        let outputID: AudioDeviceID
    }

    enum BridgeError: LocalizedError {
        case audio(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case let .audio(what, status): return "\(what) に失敗しました (OSStatus \(status))"
            }
        }
    }

    // MARK: 公開状態（メインスレッドから読む。多少の競合は表示用なので許容）

    /// 取り込み倍率。リアルタイム側でなめらかに追従する。
    var targetGain: Float = 0.5
    /// 直近の入力ピーク (0...1)。
    private(set) var inputPeak: Float = 0
    private(set) var inputRate: Double = 0
    private(set) var outputRate: Double = 0
    /// 出力が飽和し続けている（ハウリングの疑い）。
    private(set) var feedbackSuspected = false
    /// 音切れ（バッファ枯渇）と、遅延超過で音を捨てた回数。ブチブチ音の診断用。
    var underruns: Int { ring.underruns }
    var drops: Int { ring.drops }
    var isRunning: Bool { inputUnit != nil }

    /// 入出力デバイスの消失・サンプルレート変化など、自動で止める／作り直す必要が出たとき。
    var onStopRequest: ((String) -> Void)?
    var onRestartRequest: (() -> Void)?

    // MARK: 内部状態

    private var config: Config?
    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private let ring = Ring(capacity: 1 << 16)
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
    private var currentGain: Float = 0
    private var saturatedMs: Double = 0

    deinit { scratch.deallocate() }

    // MARK: 開始・停止

    /// 入力 → 少し待つ → 出力 の順に開く。
    /// Bluetooth ヘッドセットはマイクを開いた時点で通話用プロファイルに切り替わり、
    /// 出力側のサンプルレートが変わるため、出力は入力が動いてから構成する。
    func start(_ config: Config) throws {
        stop()
        self.config = config
        ring.reset()
        currentGain = 0
        saturatedMs = 0
        feedbackSuspected = false
        inputPeak = 0

        do {
            try startInput(config.inputID)
            Thread.sleep(forTimeInterval: 0.4)
            try startOutput(config.outputID)
        } catch {
            stop()
            throw error
        }
        installListeners()
    }

    func stop() {
        removeListeners()
        for unit in [inputUnit, outputUnit].compactMap({ $0 }) {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        inputUnit = nil
        outputUnit = nil
        config = nil
        inputPeak = 0
    }

    /// 遅延の目安 (ms)。リングバッファ滞留 + 各デバイスの latency/safety/buffer。
    func estimatedLatencyMs() -> Double? {
        guard let config, inputRate > 0, outputRate > 0 else { return nil }
        let inMs = Double(AudioDevices.latencyFrames(config.inputID, input: true)) / inputRate
        let outMs = Double(AudioDevices.latencyFrames(config.outputID, input: false)) / outputRate
        let ringMs = ring.fillFrames() / inputRate
        return (inMs + outMs + ringMs) * 1000
    }

    // MARK: AUHAL 構築

    private func makeHALUnit() throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw BridgeError.audio("AUHAL の検索", -1)
        }
        var unit: AudioUnit?
        let st = AudioComponentInstanceNew(comp, &unit)
        guard st == noErr, let unit else { throw BridgeError.audio("AUHAL の生成", st) }
        return unit
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw BridgeError.audio(what, status) }
    }

    private func floatFormat(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0
        )
    }

    private func startInput(_ deviceID: AudioDeviceID) throws {
        let unit = try makeHALUnit()
        inputUnit = unit
        var on: UInt32 = 1, off: UInt32 = 0
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, u32), "入力 EnableIO")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, u32), "出力側 EnableIO 無効化")
        var dev = deviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "入力デバイス設定")

        // デバイス側のレートに合わせ、アプリ側はモノラル Float32 で受ける。
        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &size), "入力フォーマット取得")
        var appFormat = floatFormat(rate: deviceFormat.mSampleRate, channels: 1)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &appFormat, size), "入力フォーマット設定")
        var maxFrames: UInt32 = 4096
        _ = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, u32)
        inputRate = deviceFormat.mSampleRate

        var cb = AURenderCallbackStruct(inputProc: inputCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "入力コールバック設定")
        try check(AudioUnitInitialize(unit), "入力初期化")
        try check(AudioOutputUnitStart(unit), "入力開始")
    }

    private func startOutput(_ deviceID: AudioDeviceID) throws {
        let unit = try makeHALUnit()
        outputUnit = unit
        var dev = deviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "出力デバイス設定")

        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &deviceFormat, &size), "出力フォーマット取得")
        var appFormat = floatFormat(rate: deviceFormat.mSampleRate, channels: 2)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &appFormat, size), "出力フォーマット設定")
        var maxFrames: UInt32 = 4096
        _ = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))
        outputRate = deviceFormat.mSampleRate

        var cb = AURenderCallbackStruct(inputProc: outputCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "出力コールバック設定")
        try check(AudioUnitInitialize(unit), "出力初期化")
        try check(AudioOutputUnitStart(unit), "出力開始")
    }

    // MARK: リアルタイム処理

    fileprivate func handleInput(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let unit = inputUnit, frames <= 16384 else { return noErr }
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: scratch)
        )
        let st = AudioUnitRender(unit, flags, ts, bus, frames, &list)
        guard st == noErr else { return st }
        var peak: Float = 0
        for i in 0..<Int(frames) { peak = max(peak, abs(scratch[i])) }
        inputPeak = peak
        ring.write(scratch, Int(frames))
        return noErr
    }

    fileprivate func handleOutput(_ frames: UInt32, _ ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard let first = buffers.first, let base = first.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        let n = Int(frames)
        let ratio = outputRate > 0 ? inputRate / outputRate : 1

        // 滞留が溜まったら捨てて遅延を抑える。足りなければ溜まるまで無音。
        ring.pull(into: base, frames: n, ratio: ratio, targetFrames: Int(inputRate * 0.08), maxFrames: Int(inputRate * 0.30))

        // 倍率（約 50ms でなめらかに追従）+ ソフトリミッタ。出力は ±0.9 を超えない。
        let target = targetGain
        let k = Float(1 - exp(-1 / (0.05 * outputRate)))
        var saturated = 0
        for i in 0..<n {
            currentGain += (target - currentGain) * k
            let x = base[i] * currentGain
            if abs(x) > 1.5 { saturated += 1 }
            base[i] = 0.9 * tanhf(x / 0.9)
        }
        // 全チャンネルに同じ音を出す。
        for b in 1..<max(buffers.count, 1) {
            if let p = buffers[b].mData?.assumingMemoryBound(to: Float.self) { p.update(from: base, count: n) }
        }

        // 半分以上のサンプルが飽和した状態が 1.5 秒続いたらハウリングとみなす。
        let blockMs = Double(n) / max(outputRate, 1) * 1000
        saturatedMs = saturated * 2 > n ? saturatedMs + blockMs : 0
        if saturatedMs > 1500 { feedbackSuspected = true }
        return noErr
    }

    // MARK: デバイス監視

    private func installListeners() {
        guard let config else { return }
        func add(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ handler: @escaping () -> Void) {
            var addr = address
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            if AudioObjectAddPropertyListenerBlock(object, &addr, .main, block) == noErr {
                listeners.append((object, address, block))
            }
        }
        add(AudioDevices.system, AudioDevices.address(kAudioHardwarePropertyDevices)) { [weak self] in
            guard let self, let c = self.config else { return }
            if AudioDevices.info(c.inputID) == nil || AudioDevices.info(c.outputID) == nil {
                self.onStopRequest?("入力または出力のデバイスが切断されたため、外音取り込みを停止しました。")
            }
        }
        // Bluetooth のプロファイル切替などでレートが変わったら作り直す。
        for (id, input) in [(config.inputID, true), (config.outputID, false)] {
            add(id, AudioDevices.address(kAudioDevicePropertyNominalSampleRate)) { [weak self] in
                guard let self else { return }
                let now = AudioDevices.nominalRate(id)
                let configured = input ? self.inputRate : self.outputRate
                if abs(now - configured) > 1 { self.onRestartRequest?() }
            }
        }
    }

    private func removeListeners() {
        for (object, address, block) in listeners {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(object, &addr, .main, block)
        }
        listeners.removeAll()
    }
}

private let inputCallback: AURenderCallback = { refCon, flags, ts, bus, frames, _ in
    Unmanaged<AudioBridge>.fromOpaque(refCon).takeUnretainedValue().handleInput(flags, ts, bus, frames)
}

private let outputCallback: AURenderCallback = { refCon, _, _, _, frames, ioData in
    guard let ioData else { return noErr }
    return Unmanaged<AudioBridge>.fromOpaque(refCon).takeUnretainedValue().handleOutput(frames, ioData)
}

/// モノラル Float のリングバッファ。入力レートで書き、出力レートへ線形補間しながら読む。
private final class Ring {
    private let capacity: Int
    private let mask: Int
    private let data: UnsafeMutablePointer<Float>
    private var lock = os_unfair_lock()
    private var writeIndex = 0
    private var readPos = 0.0
    private var primed = false
    private(set) var underruns = 0
    private(set) var drops = 0

    init(capacity: Int) {
        self.capacity = capacity
        mask = capacity - 1
        data = .allocate(capacity: capacity)
        data.initialize(repeating: 0, count: capacity)
    }

    deinit { data.deallocate() }

    func reset() {
        os_unfair_lock_lock(&lock)
        writeIndex = 0; readPos = 0; primed = false; underruns = 0; drops = 0
        os_unfair_lock_unlock(&lock)
    }

    func fillFrames() -> Double {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Double(writeIndex) - readPos
    }

    func write(_ src: UnsafePointer<Float>, _ count: Int) {
        os_unfair_lock_lock(&lock)
        for i in 0..<count { data[(writeIndex + i) & mask] = src[i] }
        writeIndex += count
        os_unfair_lock_unlock(&lock)
    }

    func pull(into dst: UnsafeMutablePointer<Float>, frames: Int, ratio: Double, targetFrames: Int, maxFrames: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        var avail = Double(writeIndex) - readPos
        if avail > Double(maxFrames) {
            readPos = Double(writeIndex - targetFrames)
            avail = Double(targetFrames)
            drops += 1
        }
        if !primed {
            if avail >= Double(targetFrames) { primed = true } else {
                dst.update(repeating: 0, count: frames)
                return
            }
        }
        // 入出力クロックのずれは、滞留量に応じて読み出し速度を ±1% 以内で補正して吸収する
        // （音を捨てたり無音を挟んだりしない）。
        let error = (avail - Double(targetFrames)) / Double(targetFrames)
        let ratio = ratio * (1 + max(-0.01, min(0.01, error * 0.01)))
        for i in 0..<frames {
            if Double(writeIndex) - readPos < 2 {
                underruns += 1
                primed = false
                dst.advanced(by: i).update(repeating: 0, count: frames - i)
                return
            }
            let idx = Int(readPos)
            let frac = Float(readPos - Double(idx))
            let a = data[idx & mask], b = data[(idx + 1) & mask]
            dst[i] = a + (b - a) * frac
            readPos += ratio
        }
    }
}
