import UIKit
import AVFoundation
import ZegoExpressEngine

/// Host:     Nosmai owns the camera -> filtered CVPixelBuffers -> ZEGO custom video capture.
/// Audience: plain ZEGO player rendering the host's stream.
final class LiveViewController: UIViewController {
    enum Role { case host, audience }

    private let role: Role
    private let config: DemoConfig
    private var isHost: Bool { role == .host }

    private var engine: ZegoExpressEngine?
    /// Audience: the host stream currently being played.
    private var playingStreamID: String?
    private let frameQueue = DispatchQueue(label: "com.nosmai.zego.demo.frames")
    private var cameraRunning = false
    private var stopped = false
    /// Read from Nosmai's processing thread and the frame queue.
    private let pushLock = NSLock()
    private var _pushing = false
    private var pushing: Bool {
        get { pushLock.lock(); defer { pushLock.unlock() }; return _pushing }
        set { pushLock.lock(); _pushing = newValue; pushLock.unlock() }
    }

    private var liveStatus = "Preparing…"
    private var toastToken = 0

    private let videoView = UIView()
    private let statusLabel = PaddedLabel()
    private let fpsLabel = PaddedLabel()
    /// Host: frames handed to ZEGO since the last tick. Guarded by pushLock.
    private var framesSinceTick = 0
    private var fpsTimer: Timer?
    private let controls = UIStackView()
    private let effectsPanel = EffectsPanelView()

    init(role: Role, config: DemoConfig) {
        self.role = role
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isHost ? "Live" : "Watching"
        view.backgroundColor = .black
        buildUI()
        setUpZego()
        if isHost {
            requestPermissions { [weak self] in self?.startNosmaiCamera() }
        } else {
            loginRoom()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        if isMovingFromParent || isBeingDismissed { stopSession() }
    }

    // MARK: - UI

    private func buildUI() {
        videoView.backgroundColor = .black
        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)

        statusLabel.text = "Preparing…"
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        statusLabel.layer.cornerRadius = 10
        statusLabel.clipsToBounds = true
        statusLabel.numberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        fpsLabel.text = "-- FPS"
        fpsLabel.textColor = .systemGreen
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        fpsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        fpsLabel.layer.cornerRadius = 10
        fpsLabel.clipsToBounds = true
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fpsLabel)

        controls.axis = .vertical
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        if isHost {
            effectsPanel.onStatus = { [weak self] text in self?.showToast(text) }
            controls.addArrangedSubview(effectsPanel)
        }

        let buttons = UIStackView()
        buttons.axis = .horizontal
        buttons.spacing = 12
        buttons.distribution = .fillEqually
        if isHost {
            buttons.addArrangedSubview(makeButton(title: "Flip", color: .darkGray, action: #selector(flipCamera)))
            buttons.addArrangedSubview(makeButton(title: "Effects", color: .systemPink, action: #selector(toggleEffects)))
        }
        buttons.addArrangedSubview(makeButton(title: isHost ? "End Live" : "Leave", color: .systemRed, action: #selector(close)))
        buttons.heightAnchor.constraint(equalToConstant: 48).isActive = true
        controls.addArrangedSubview(buttons)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            fpsLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            fpsLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),

            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
        ])
    }

    private func makeButton(title: String, color: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.backgroundColor = color
        button.layer.cornerRadius = 12
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async {
            self.liveStatus = text
            self.statusLabel.text = text
        }
    }

    /// Briefly shows effect feedback in the status pill, then restores the live status.
    private func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        statusLabel.text = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.toastToken == token else { return }
            self.statusLabel.text = self.liveStatus
        }
    }

    // MARK: - ZEGO

    private func setUpZego() {
        let logConfig = ZegoLogConfig()
        logConfig.logSize = 0
        ZegoExpressEngine.setLogConfig(logConfig)
        let profile = ZegoEngineProfile()
        profile.appID = config.zegoAppID
        profile.appSign = config.zegoAppSign
        profile.scenario = .broadcast
        let engine = ZegoExpressEngine.createEngine(with: profile, eventHandler: self)
        if isHost {
            // Nosmai owns the camera, so ZEGO must take frames from us.
            // This has to be configured before publishing starts.
            let capture = ZegoCustomVideoCaptureConfig()
            capture.bufferType = .cvPixelBuffer
            engine.enableCustomVideoCapture(true, config: capture)
            engine.setCustomVideoCaptureHandler(self)

            let video = ZegoVideoConfig(preset: .preset720P)
            video.captureResolution = CGSize(width: 720, height: 1280)
            video.encodeResolution = CGSize(width: 720, height: 1280)
            video.fps = 30
            engine.setVideoConfig(video)
        }
        self.engine = engine
    }

    private func loginRoom() {
        guard let engine else { return }
        // Every participant in a room needs a unique user ID.
        let userID = (isHost ? "host_" : "viewer_") + UUID().uuidString.prefix(8)
        engine.loginRoom(config.roomID, user: ZegoUser(userID: userID), config: ZegoRoomConfig())
        setStatus("Joining \(config.roomID)…")
    }

    // MARK: - Nosmai (host only)

    private func requestPermissions(then start: @escaping () -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] camera in
            guard camera else { self?.setStatus("Camera permission denied"); return }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] mic in
                guard mic else { self?.setStatus("Microphone permission denied"); return }
                DispatchQueue.main.async(execute: start)
            }
        }
    }

    private func startNosmaiCamera() {
        guard !stopped else { return }
        setStatus("Starting Nosmai…")
        NosmaiCore.shared().initialize(withAPIKey: config.nosmaiAPIKey) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                guard success else {
                    self.setStatus("Nosmai init failed: \(error?.localizedDescription ?? "unknown")")
                    return
                }
                guard let camera = NosmaiCore.shared().camera else {
                    self.setStatus("Nosmai camera unavailable")
                    return
                }
                let cameraConfig = NosmaiCameraConfig()
                cameraConfig.position = .front
                cameraConfig.sessionPreset = AVCaptureSession.Preset.hd1280x720.rawValue
                cameraConfig.frameRate = 30
                camera.updateConfiguration(cameraConfig)
                camera.attach(to: self.videoView)

                guard camera.startCapture() else {
                    self.setStatus("Nosmai camera failed to start")
                    return
                }
                // Required for beauty / filters to render.
                NosmaiSDK.sharedInstance()?.startProcessing()
                self.cameraRunning = true
                self.effectsPanel.nosmaiReady()
                self.loginRoom()
            }
        }
    }

    /// Forward every filtered frame from Nosmai to ZEGO.
    private func startPushingFrames() {
        guard cameraRunning, !pushing, !stopped else { return }
        pushing = true
        // Host FPS = filtered frames Nosmai actually delivers to ZEGO each second.
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pushLock.lock()
            let frames = self.framesSinceTick
            self.framesSinceTick = 0
            self.pushLock.unlock()
            self.fpsLabel.text = "\(frames) FPS"
        }
        NosmaiCore.shared().liveFrameStreamCallback = { [weak self] pixelBuffer, timestamp in
            guard let self, self.pushing else { return }
            self.pushLock.lock()
            self.framesSinceTick += 1
            self.pushLock.unlock()
            // Swift retains the buffer for the lifetime of the closure below.
            self.frameQueue.async {
                guard self.pushing, let engine = self.engine else { return }
                engine.sendCustomVideoCapture(pixelBuffer,
                                               timestamp: CMTime(seconds: timestamp, preferredTimescale: 1000))
            }
        }
    }

    // MARK: - Actions

    @objc private func toggleEffects() {
        UIView.animate(withDuration: 0.2) {
            self.effectsPanel.isHidden.toggle()
            self.effectsPanel.alpha = self.effectsPanel.isHidden ? 0 : 1
        }
    }

    private func stopPushingFrames() {
        pushing = false
        fpsTimer?.invalidate()
        fpsTimer = nil
    }

    @objc private func flipCamera() {
        guard cameraRunning else { return }
        _ = NosmaiCore.shared().camera?.switch()
    }

    @objc private func close() {
        navigationController?.popViewController(animated: true)
    }

    private func stopSession() {
        guard !stopped else { return }
        stopped = true
        stopPushingFrames()
        if isHost {
            NosmaiCore.shared().liveFrameStreamCallback = nil
            frameQueue.sync {} // drain frames already queued before tearing ZEGO down
            engine?.stopPublishingStream()
        } else if let playingStreamID {
            engine?.stopPlayingStream(playingStreamID)
        }
        engine?.logoutRoom()
        engine = nil
        ZegoExpressEngine.destroy(nil)

        if cameraRunning {
            cameraRunning = false
            let core = NosmaiCore.shared()
            core.effects?.clearAll() // the SDK is a singleton; don't leak effects into the next session
            core.camera?.stopCapture()
            core.camera?.detachFromView()
            core.cleanup()
        }
    }
}

// MARK: - ZegoEventHandler

extension LiveViewController: ZegoEventHandler {
    func onRoomStateChanged(_ reason: ZegoRoomStateChangedReason, errorCode: Int32,
                            extendedData: [AnyHashable: Any], roomID: String) {
        switch reason {
        case .logined:
            if isHost {
                // Publishing triggers ZegoCustomVideoCaptureHandler.onStart below.
                engine?.startPublishingStream(config.streamID)
            } else if playingStreamID == nil {
                setStatus("Connected — waiting for host")
            }
        case .loginFailed, .reconnectFailed, .kickOut:
            setStatus("ZEGO room error \(errorCode) — check AppID / AppSign")
        case .reconnecting:
            setStatus("Reconnecting…")
        default:
            break
        }
    }

    func onPublisherStateUpdate(_ state: ZegoPublisherState, errorCode: Int32,
                                extendedData: [AnyHashable: Any]?, streamID: String) {
        if errorCode != 0 {
            setStatus("ZEGO publish error \(errorCode)")
        } else if state == .publishing {
            setStatus("Live in \(config.roomID)")
        }
    }

    /// Audience: the host started or stopped publishing.
    func onRoomStreamUpdate(_ updateType: ZegoUpdateType, streamList: [ZegoStream],
                            extendedData: [AnyHashable: Any]?, roomID: String) {
        guard !isHost, let engine else { return }
        switch updateType {
        case .add:
            guard playingStreamID == nil, let stream = streamList.first else { return }
            let canvas = ZegoCanvas(view: videoView)
            canvas.viewMode = .aspectFill
            engine.startPlayingStream(stream.streamID, canvas: canvas)
            playingStreamID = stream.streamID
            setStatus("Watching host")
        case .delete:
            guard let current = playingStreamID,
                  streamList.contains(where: { $0.streamID == current }) else { return }
            engine.stopPlayingStream(current)
            playingStreamID = nil
            fpsLabel.text = "-- FPS"
            setStatus("Host left the stream")
        @unknown default:
            break
        }
    }

    /// Audience FPS = frames actually rendered from the host's stream (reported every 3s).
    func onPlayerQualityUpdate(_ quality: ZegoPlayStreamQuality, streamID: String) {
        guard !isHost else { return }
        fpsLabel.text = "\(Int(quality.videoRenderFPS.rounded())) FPS"
    }

    func onPlayerStateUpdate(_ state: ZegoPlayerState, errorCode: Int32,
                             extendedData: [AnyHashable: Any]?, streamID: String) {
        if errorCode != 0 { setStatus("ZEGO play error \(errorCode)") }
    }
}

// MARK: - ZegoCustomVideoCaptureHandler

extension LiveViewController: ZegoCustomVideoCaptureHandler {
    /// ZEGO is ready to receive our frames.
    func onStart(_ channel: ZegoPublishChannel) {
        DispatchQueue.main.async { self.startPushingFrames() }
    }

    /// ZEGO no longer needs frames (publishing stopped).
    func onStop(_ channel: ZegoPublishChannel) {
        DispatchQueue.main.async { self.stopPushingFrames() }
    }
}

private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right,
                      height: size.height + insets.top + insets.bottom)
    }
}
