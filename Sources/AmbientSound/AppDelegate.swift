import AVFoundation
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let bridge = AudioBridge()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private let statusLine = NSMenuItem()
    private let toggleItem = NSMenuItem()
    private let gainLabel = NSMenuItem()
    private let gainSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 4, target: nil, action: nil)
    private let levelLine = NSMenuItem()
    private let inputLine = NSMenuItem()
    private let outputLine = NSMenuItem()
    private let latencyLine = NSMenuItem()
    private let inputMenu = NSMenu()
    private let outputMenu = NSMenu()

    /// UID。nil は「システム既定」。次回起動時に引き継ぐ。
    private var inputUID: String? = UserDefaults.standard.string(forKey: "inputUID")
    private var outputUID: String? = UserDefaults.standard.string(forKey: "outputUID")

    private var timer: Timer?
    private var restartTimes: [Date] = []
    private var starting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        updateIcon()
        bridge.onStopRequest = { [weak self] message in self?.stopBridge(notify: message) }
        bridge.onRestartRequest = { [weak self] in self?.restartBridge() }
        timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common) // メニューを開いている間も更新する
        refreshLabels()
    }

    func applicationWillTerminate(_ notification: Notification) { bridge.stop() }

    // MARK: メニュー構築

    private func buildMenu() {
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        toggleItem.target = self
        toggleItem.action = #selector(toggle)
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        gainLabel.isEnabled = false
        menu.addItem(gainLabel)
        gainSlider.target = self
        gainSlider.action = #selector(gainChanged)
        gainSlider.frame = NSRect(x: 16, y: 2, width: 200, height: 22)
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 232, height: 26))
        holder.addSubview(gainSlider)
        let sliderItem = NSMenuItem()
        sliderItem.view = holder
        menu.addItem(sliderItem)
        levelLine.isEnabled = false
        menu.addItem(levelLine)
        menu.addItem(.separator())

        for item in [inputLine, outputLine, latencyLine] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let inputParent = NSMenuItem(title: "入力デバイス（マイク）", action: nil, keyEquivalent: "")
        inputParent.submenu = inputMenu
        menu.addItem(inputParent)
        let outputParent = NSMenuItem(title: "出力デバイス（イヤホン）", action: nil, keyEquivalent: "")
        outputParent.submenu = outputMenu
        menu.addItem(outputParent)

        let sound = NSMenuItem(title: "サウンド設定を開く…", action: #selector(openSoundSettings), keyEquivalent: "")
        sound.target = self
        menu.addItem(sound)
        menu.addItem(.separator())
        menu.addItem(withTitle: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu { rebuildDeviceMenus(); refreshLabels() }
    }

    private func rebuildDeviceMenus() {
        fill(inputMenu, input: true)
        fill(outputMenu, input: false)
    }

    private func fill(_ menu: NSMenu, input: Bool) {
        menu.removeAllItems()
        let selected = input ? inputUID : outputUID
        let def = AudioDevices.defaultDevice(input: input)
        let first = NSMenuItem(title: "システム既定（\(def?.name ?? "なし")）", action: #selector(pickDevice(_:)), keyEquivalent: "")
        first.target = self
        first.representedObject = ["input": input, "uid": ""] as [String: Any]
        first.state = selected == nil ? .on : .off
        menu.addItem(first)
        menu.addItem(.separator())
        for d in AudioDevices.all() where (input ? d.inputChannels : d.outputChannels) > 0 {
            let item = NSMenuItem(title: d.name, action: #selector(pickDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["input": input, "uid": d.uid] as [String: Any]
            item.state = selected == d.uid ? .on : .off
            menu.addItem(item)
        }
    }

    // MARK: 操作

    @objc private func pickDevice(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let input = info["input"] as? Bool, let uid = info["uid"] as? String else { return }
        let value: String? = uid.isEmpty ? nil : uid
        if input { inputUID = value } else { outputUID = value }
        UserDefaults.standard.set(inputUID, forKey: "inputUID")
        UserDefaults.standard.set(outputUID, forKey: "outputUID")
        if bridge.isRunning { restartBridge() }
        refreshLabels()
    }

    @objc private func gainChanged() {
        bridge.targetGain = Float(gainSlider.doubleValue)
        refreshLabels()
    }

    @objc private func openSoundSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }

    @objc private func toggle() {
        if bridge.isRunning || starting { stopBridge(notify: nil) } else { startBridge() }
    }

    // MARK: 開始・停止

    private func resolve() -> AudioBridge.Config? {
        let input = inputUID.flatMap { AudioDevices.find(uid: $0) } ?? AudioDevices.defaultDevice(input: true)
        let output = outputUID.flatMap { AudioDevices.find(uid: $0) } ?? AudioDevices.defaultDevice(input: false)
        guard let input, input.inputChannels > 0 else {
            alert("入力デバイスが見つかりません", "メニューの「入力デバイス」か、サウンド設定の「入力」でマイクを選んでください。")
            return nil
        }
        guard let output, output.outputChannels > 0 else {
            alert("出力デバイスが見つかりません", "イヤホンが接続されているか確認し、メニューの「出力デバイス」か、サウンド設定の「出力」で選んでください。")
            return nil
        }
        return .init(inputID: input.id, outputID: output.id)
    }

    private func startBridge() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            launch()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted { self.launch() } else { self.showPermissionDenied() }
                }
            }
        default:
            showPermissionDenied()
        }
    }

    private func launch() {
        guard let config = resolve() else { return }
        bridge.targetGain = Float(gainSlider.doubleValue)
        starting = true
        refreshLabels()
        // 入力を開いてから出力を構成するまで待つので、メインを塞がないよう別スレッドで。
        DispatchQueue.global(qos: .userInteractive).async {
            let result = Result { try self.bridge.start(config) }
            DispatchQueue.main.async {
                self.starting = false
                if case let .failure(error) = result {
                    self.alert("外音取り込みを開始できません", error.localizedDescription)
                }
                self.updateIcon()
                self.refreshLabels()
            }
        }
    }

    private func restartBridge() {
        // 切替が収まらない場合に無限に作り直さない。
        let now = Date()
        restartTimes = restartTimes.filter { now.timeIntervalSince($0) < 10 } + [now]
        if restartTimes.count > 4 {
            stopBridge(notify: "デバイスの状態が安定しないため停止しました。もう一度開始してください。")
            return
        }
        bridge.stop()
        launch()
    }

    private func stopBridge(notify message: String?) {
        bridge.stop()
        starting = false
        updateIcon()
        refreshLabels()
        if let message { alert("外音取り込みを停止しました", message) }
    }

    private func showPermissionDenied() {
        stopBridge(notify: nil)
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "マイクの使用が許可されていません"
        a.informativeText = "システム設定 > プライバシーとセキュリティ > マイク で「AmbientSound」を許可してから、もう一度開始してください。"
        a.addButton(withTitle: "マイク設定を開く")
        a.addButton(withTitle: "閉じる")
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: 表示更新

    private func tick() {
        if bridge.feedbackSuspected {
            stopBridge(notify: "出力が飽和し続けたため（ハウリングの疑い）停止しました。取り込み音量を下げるか、マイクとイヤホンを離してから再開してください。")
            return
        }
        refreshLabels()
    }

    private func updateIcon() {
        let running = bridge.isRunning
        let button = statusItem.button
        button?.image = NSImage(systemSymbolName: running ? "ear.fill" : "ear", accessibilityDescription: "外音取り込み")
        if button?.image == nil { button?.title = running ? "外音●" : "外音" }
    }

    private func refreshLabels() {
        let running = bridge.isRunning
        statusLine.title = starting ? "状態: 開始中…" : (running ? "状態: 取り込み中" : "状態: 停止中")
        toggleItem.title = (running || starting) ? "停止" : "外音取り込みを開始"
        gainLabel.title = String(format: "取り込み音量: ×%.2f（初期値 ×0.50）", gainSlider.doubleValue)

        let dbText: String
        if running, bridge.inputPeak > 0 {
            let db = 20 * log10(Double(bridge.inputPeak))
            let bars = max(0, min(10, Int((db + 60) / 6)))
            dbText = String(repeating: "■", count: bars) + String(repeating: "□", count: 10 - bars) + String(format: " %.0f dB", db)
        } else {
            dbText = "—"
        }
        levelLine.title = "入力レベル: \(dbText)"

        let inDev = inputUID.flatMap { AudioDevices.find(uid: $0) } ?? AudioDevices.defaultDevice(input: true)
        let outDev = outputUID.flatMap { AudioDevices.find(uid: $0) } ?? AudioDevices.defaultDevice(input: false)
        func rate(_ r: Double) -> String { running && r > 0 ? String(format: " / %.0f Hz", r) : "" }
        inputLine.title = "入力: \(inDev?.name ?? "なし")\(rate(bridge.inputRate))"
        outputLine.title = "出力: \(outDev?.name ?? "なし")\(rate(bridge.outputRate))"
        latencyLine.title = running ? String(format: "遅延の目安: 約 %.0f ms", bridge.estimatedLatencyMs() ?? 0) : "遅延の目安: —"
        updateIcon()
    }
}
