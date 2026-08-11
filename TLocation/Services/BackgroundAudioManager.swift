//
//  BackgroundAudioManager.swift
//  TLocation
//

import AVFoundation

/// Keeps the app out of the suspended state by holding an active audio session
/// that plays pure silence.
///
/// iOS treats a playing audio session as a far stronger reason to keep a process
/// running than background location, which is what a simulation needs: the
/// coordinate has to be re-sent every few seconds or the device session dies and
/// the position reverts to the real one.
///
/// The cost is that holding an audio session makes this app the audio-playing
/// app — on CarPlay it takes over the now-playing slot. Version 1.0.0 paid that
/// cost permanently because it started the session at launch. This one is scoped
/// the same way `BackgroundLocationManager` is: nothing starts until a
/// simulation actually begins (`requestStart()`), and it stops the moment the
/// last one ends (`requestStop()`). It is additionally gated on the
/// `keepAliveAudio` preference, which defaults to off, so a user who never opts
/// in never has an audio session created at all.
final class BackgroundAudioManager {
    static let shared = BackgroundAudioManager()

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var isRunning = false
    /// How many simulations are currently asking to be kept alive. Balanced
    /// pairs of `requestStart()`/`requestStop()`, exactly as in
    /// `BackgroundLocationManager`, so an adopted external simulation cannot
    /// leave a stray activation behind.
    private var activityCount = 0
    private var healthCheckTimer: Timer?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }

    func requestStart() {
        activityCount += 1
        refreshRunningState()
    }

    func requestStop() {
        activityCount = max(activityCount - 1, 0)
        refreshRunningState()
    }

    /// Call after `keepAliveAudio` changes so flipping the switch in Settings
    /// takes effect on a simulation that is already running — on immediately
    /// starts the session, off immediately gives it back. With no simulation
    /// outstanding this is a no-op in both directions.
    func preferenceDidChange() {
        refreshRunningState()
    }

    private func refreshRunningState() {
        let shouldRun = activityCount > 0 && UserDefaults.standard.bool(forKey: "keepAliveAudio")
        guard shouldRun != isRunning else {
            if shouldRun {
                recoverIfNeeded()
            }
            return
        }

        isRunning = shouldRun
        if shouldRun {
            startEngine()
            startHealthCheck()
        } else {
            healthCheckTimer?.invalidate()
            healthCheckTimer = nil
            player.stop()
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func startEngine() {
        do {
            engine.stop()
            player.stop()
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()

            let session = AVAudioSession.sharedInstance()
            // `.mixWithOthers` is the whole point: this session exists only to
            // keep the process alive, so it must never interrupt or duck
            // whatever the user is actually listening to.
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)

            engine.attach(player)
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(player, to: engine.mainMixerNode, format: format)

            scheduleSilence()
            try engine.start()
            player.play()
        } catch {
            LogManager.shared.addErrorLog("BackgroundAudioManager: \(error.localizedDescription)")
        }
    }

    private func scheduleSilence() {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let frameCount = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        // PCM buffer is zero-initialized — pure silence
        player.scheduleBuffer(buffer, at: nil, options: .loops)
    }

    // Runs every 2 seconds to reclaim the session after an interruption whose
    // "ended" notification never arrives — without it a single missed
    // notification silently turns the keep-alive off for the rest of the
    // simulation. It only ever reactivates this app's own mixing session.
    private func startHealthCheck() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.recoverIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthCheckTimer = timer
    }

    private func recoverIfNeeded() {
        guard isRunning, !engine.isRunning || !player.isPlaying else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning {
                try engine.start()
            }
            player.play()
        } catch {
            // Session not available right now — will retry on the next tick.
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
              type == .ended,
              isRunning else { return }

        // Best-effort immediate resume; health check will cover failures.
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try? engine.start() }
        player.play()
    }

    @objc private func handleMediaServicesReset() {
        guard isRunning else { return }
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        startEngine()
    }
}
