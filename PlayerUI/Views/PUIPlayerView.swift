//
//  PUIPlayerView.swift
//  PlayerProto
//
//  Created by Guilherme Rambo on 29/04/17.
//  Copyright © 2017 Guilherme Rambo. All rights reserved.
//

import Cocoa
import AVFoundation

public final class PUIPlayerView: NSView {

    // MARK: - Public API

    public weak var delegate: PUIPlayerViewDelegate?

    public internal(set) var isInPictureInPictureMode: Bool = false {
        didSet {
            guard isInPictureInPictureMode != oldValue else { return }

            pipButton.state = isInPictureInPictureMode ? .on : .off

            if isInPictureInPictureMode {
                externalStatusController.providerIcon = .PUIPictureInPictureLarge
                externalStatusController.providerName = "Picture in Picture"
                externalStatusController.providerDescription = "Playing in Picture in Picture"
                externalStatusController.view.isHidden = false
            } else {
                externalStatusController.view.isHidden = true
            }
        }
    }

    public weak var appearanceDelegate: PUIPlayerViewAppearanceDelegate? {
        didSet {
            invalidateAppearance()
        }
    }

    public var timelineDelegate: PUITimelineDelegate? {
        get {
            return timelineView.delegate
        }
        set {
            timelineView.delegate = newValue
        }
    }

    public var annotations: [PUITimelineAnnotation] {
        get {
            return sortedAnnotations
        }
        set {
            sortedAnnotations = newValue.filter({ $0.isValid }).sorted(by: { $0.timestamp < $1.timestamp })

            timelineView.annotations = sortedAnnotations
        }
    }

    public weak var player: AVPlayer? {
        didSet {
            guard oldValue != player else { return }

            if let oldPlayer = oldValue {
                teardown(player: oldPlayer)
            }

            guard player != nil else { return }

            setupPlayer()
        }
    }

    public var isInFullScreenPlayerWindow: Bool {
        return window is PUIPlayerWindow
    }

    public var remoteMediaUrl: URL?
    public var mediaPosterUrl: URL?
    public var mediaTitle: String?
    public var mediaIsLiveStream: Bool = false

    var pictureContainer: PUIPictureContainerViewController!

    public init(player: AVPlayer) {
        self.player = player

        super.init(frame: .zero)

        wantsLayer = true
        layer = PUIBoringLayer()
        layer?.backgroundColor = NSColor.black.cgColor

        setupPlayer()
        setupControls()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public var isPlaying: Bool {
        if let externalProvider = currentExternalPlaybackProvider {
            return !externalProvider.status.rate.isZero
        } else {
            return isInternalPlayerPlaying
        }
    }

    public var isInternalPlayerPlaying: Bool {
        guard let player = player else { return false }

        return !player.rate.isZero
    }

    public var currentTimestamp: Double {
        guard let player = player else { return 0 }

        if let externalProvider = currentExternalPlaybackProvider {
            return Double(externalProvider.status.currentTime)
        } else {
            return Double(CMTimeGetSeconds(player.currentTime()))
        }
    }

    public var firstAnnotationBeforeCurrentTime: PUITimelineAnnotation? {
        return annotations.reversed().first { $0.isValid && $0.timestamp + 1 < currentTimestamp }
    }

    public var firstAnnotationAfterCurrentTime: PUITimelineAnnotation? {
        return annotations.first { $0.isValid && $0.timestamp > currentTimestamp + 1 }
    }

    public func seek(to annotation: PUITimelineAnnotation) {
        guard let player = player else { return }

        let time = CMTimeMakeWithSeconds(Float64(annotation.timestamp), 9000)

        if isPlayingExternally {
            currentExternalPlaybackProvider?.seek(to: annotation.timestamp)
        } else {
            player.seek(to: time)
        }
    }

    public var playbackSpeed: PUIPlaybackSpeed = .normal {
        didSet {
            guard let player = player else { return }

            if isPlaying && !isPlayingExternally {
                player.rate = playbackSpeed.rawValue
                player.seek(to: player.currentTime()) // Helps the AV sync when speeds change with the TimeDomain algorithm enabled
            }

            updatePlaybackSpeedState()
            updateSelectedMenuItem(forPlaybackSpeed: playbackSpeed)
        }
    }

    public var isPlayingExternally: Bool {
        return currentExternalPlaybackProvider != nil
    }

    public var hideAllControls: Bool = false {
        didSet {
            controlsContainerView.isHidden = hideAllControls
            extrasMenuContainerView.isHidden = hideAllControls
        }
    }

    // MARK: External playback

    fileprivate(set) var externalPlaybackProviders: [PUIExternalPlaybackProviderRegistration] = [] {
        didSet {
            updateExternalPlaybackMenus()
        }
    }

    public func registerExternalPlaybackProvider(_ provider: PUIExternalPlaybackProvider.Type) {
        // prevent registering the same provider multiple times
        guard !externalPlaybackProviders.contains(where: { type(of: $0.provider).name == provider.name }) else {
            NSLog("PUIPlayerView WARNING: tried to register provider \(provider.name) which was already registered")
            return
        }

        let instance = provider.init(consumer: self)
        let button = self.button(for: instance)
        let registration = PUIExternalPlaybackProviderRegistration(provider: instance, button: button, menu: NSMenu())

        externalPlaybackProviders.append(registration)
    }

    public func invalidateAppearance() {
        configureWithAppearanceFromDelegate()
    }

    // MARK: - Private API

    fileprivate var lastKnownWindow: NSWindow? = nil

    private var sortedAnnotations: [PUITimelineAnnotation] = [] {
        didSet {
            updateAnnotationsState()
        }
    }

    private var playerTimeObserver: Any?

    fileprivate var asset: AVAsset? {
        return player?.currentItem?.asset
    }

    private var playerLayer = PUIBoringPlayerLayer()

    private func setupPlayer() {
        guard let player = player else { return }

        playerLayer.player = player
        playerLayer.videoGravity = AVLayerVideoGravity.resizeAspect

        if pictureContainer == nil {
            pictureContainer = PUIPictureContainerViewController(playerLayer: playerLayer)
            pictureContainer.delegate = self
            pictureContainer.view.frame = bounds
            pictureContainer.view.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]

            addSubview(pictureContainer.view)
        }

        player.addObserver(self, forKeyPath: #keyPath(AVPlayer.status), options: [.initial, .new], context: nil)
        player.addObserver(self, forKeyPath: #keyPath(AVPlayer.volume), options: [.initial, .new], context: nil)
        player.addObserver(self, forKeyPath: #keyPath(AVPlayer.rate), options: [.initial, .new], context: nil)
        player.addObserver(self, forKeyPath: #keyPath(AVPlayer.currentItem), options: [.initial, .new], context: nil)
        player.addObserver(self, forKeyPath: #keyPath(AVPlayer.currentItem.loadedTimeRanges), options: [.initial, .new], context: nil)
        player.addObserver(self, forKeyPath: #keyPath(AVPlayer.currentItem.duration), options: [.initial, .new], context: nil)
        player.addObserver(self, forKeyPath: #keyPath(AVPlayer.currentItem.currentMediaSelection), options: [.initial, .new], context: nil)

        asset?.loadValuesAsynchronously(forKeys: ["tracks"], completionHandler: metadataBecameAvailable)

        playerTimeObserver = player.addPeriodicTimeObserver(forInterval: CMTimeMakeWithSeconds(0.5, 9000), queue: DispatchQueue.main) { [weak self] currentTime in
            self?.playerTimeDidChange(time: currentTime)
        }
    }

    private func teardown(player oldValue: AVPlayer) {
        oldValue.pause()
        oldValue.cancelPendingPrerolls()

        if let observer = playerTimeObserver {
            oldValue.removeTimeObserver(observer)
            playerTimeObserver = nil
        }

        oldValue.removeObserver(self, forKeyPath: #keyPath(AVPlayer.status))
        oldValue.removeObserver(self, forKeyPath: #keyPath(AVPlayer.rate))
        oldValue.removeObserver(self, forKeyPath: #keyPath(AVPlayer.volume))
        oldValue.removeObserver(self, forKeyPath: #keyPath(AVPlayer.currentItem.loadedTimeRanges))
        oldValue.removeObserver(self, forKeyPath: #keyPath(AVPlayer.currentItem.duration))
        oldValue.removeObserver(self, forKeyPath: #keyPath(AVPlayer.currentItem.currentMediaSelection))
        oldValue.removeObserver(self, forKeyPath: #keyPath(AVPlayer.currentItem))
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            guard let keyPath = keyPath else { return }

            switch keyPath {
            case #keyPath(AVPlayer.status):
                self.playerStatusChanged()
            case #keyPath(AVPlayer.currentItem.loadedTimeRanges):
                self.updateBufferedSegments()
            case #keyPath(AVPlayer.volume):
                self.playerVolumeChanged()
            case #keyPath(AVPlayer.rate):
                self.updatePlayingState()
                self.updatePowerAssertion()
            case #keyPath(AVPlayer.currentItem.duration):
                self.metadataBecameAvailable()
            case #keyPath(AVPlayer.currentItem.currentMediaSelection):
                self.updateMediaSelection()
            case #keyPath(AVPlayer.currentItem):
                if let playerItem = self.player?.currentItem {
                    playerItem.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithm.timeDomain
                }
            default:
                super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            }
        }
    }

    private func playerVolumeChanged() {
        guard let player = player else { return }

        if player.volume.isZero {
            volumeButton.image = .PUIVolumeMuted
            volumeSlider.doubleValue = 0
        } else {
            volumeButton.image = .PUIVolume
            volumeSlider.doubleValue = Double(player.volume)
        }
    }

    private func updateBufferedSegments() {
        guard let player = player else { return }

        guard let loadedRanges = player.currentItem?.loadedTimeRanges else { return }
        guard let durationTime = player.currentItem?.duration else { return }

        let duration = Double(CMTimeGetSeconds(durationTime))

        let segments = loadedRanges.map { value -> PUIBufferSegment in
            let range = value.timeRangeValue
            let startTime = Double(CMTimeGetSeconds(range.start))
            let segmentDuration = Double(CMTimeGetSeconds(range.duration))

            return PUIBufferSegment(start: startTime / duration, duration: segmentDuration / duration)
        }

        timelineView.loadedSegments = Set<PUIBufferSegment>(segments)
    }

    private func updateAnnotationsState() {
        let canGoBack = firstAnnotationBeforeCurrentTime != nil
        let canGoForward = firstAnnotationAfterCurrentTime != nil

        previousAnnotationButton.isEnabled = canGoBack
        nextAnnotationButton.isEnabled = canGoForward
    }

    fileprivate func updatePlayingState() {
        pipController?.setPlaying(isPlaying)

        if isPlaying {
            playButton.image = .PUIPause
        } else {
            playButton.image = .PUIPlay
        }
    }

    fileprivate var activity: NSObjectProtocol?

    fileprivate func updatePowerAssertion() {
        if player?.rate == 0 {
            if let activity = activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
        } else {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Playing WWDC session video")
            }
        }
    }

    fileprivate func updatePlaybackSpeedState() {
        speedButton.image = playbackSpeed.icon
    }

    fileprivate var currentPresentationSize: NSSize? {
        guard let size = player?.currentItem?.presentationSize, size != NSZeroSize else { return nil }

        return size
    }

    private func playerStatusChanged() {
        guard let player = player else { return }

        switch player.status {
        case .readyToPlay:
            updateTimeLabels()
        default: break
        }
    }

    private func metadataBecameAvailable() {
        guard let duration = asset?.duration else { return }

        DispatchQueue.main.async {

            self.timelineView.mediaDuration = Double(CMTimeGetSeconds(duration))
        }
    }

    fileprivate func playerTimeDidChange(time: CMTime) {
        guard let player = player else { return }
        guard player.hasValidMediaDuration else { return }
        guard let duration = asset?.duration else { return }

        DispatchQueue.main.async {

            let progress = Double(CMTimeGetSeconds(time) / CMTimeGetSeconds(duration))
            self.timelineView.playbackProgress = progress

            self.updateAnnotationsState()
            self.updateTimeLabels()
        }
    }

    private func updateTimeLabels() {
        guard let player = player else { return }

        guard player.hasValidMediaDuration else { return }
        guard let duration = asset?.duration else { return }

        let time = player.currentTime()

        elapsedTimeLabel.stringValue = String(time: time) ?? ""

        let remainingTime = CMTimeSubtract(duration, time)
        remainingTimeLabel.stringValue = String(time: remainingTime) ?? ""
    }

    deinit {
        if let player = player {
            teardown(player: player)
        }
    }

    // MARK: Controls

    fileprivate var wasPlayingBeforeStartingInteractiveSeek = false

    private var extrasMenuContainerView: NSStackView!

    //    fileprivate var controlsVisualEffectView: NSVisualEffectView!
    fileprivate var scrimContainerView: PUIScrimContainerView!

    private var timeLabelsContainerView: NSStackView!
    private var controlsContainerView: NSStackView!
    private var volumeControlsContainerView: NSStackView!
    private var centerButtonsContainerView: NSStackView!

    fileprivate var timelineView: PUITimelineView!

    private lazy var elapsedTimeLabel: NSTextField = {
        let l = NSTextField(labelWithString: "00:00:00")

        l.alignment = .left
        l.font = .systemFont(ofSize: 14, weight: NSFont.Weight.medium)
        l.textColor = .timeLabel

        return l
    }()

    private lazy var remainingTimeLabel: NSTextField = {
        let l = NSTextField(labelWithString: "-00:00:00")

        l.alignment = .right
        l.font = .systemFont(ofSize: 14, weight: NSFont.Weight.medium)
        l.textColor = .timeLabel

        return l
    }()

    private lazy var fullScreenButton: PUIButton = {
        let b = PUIButton(frame: .zero)

        b.image = .PUIFullScreen
        b.target = self
        b.action = #selector(toggleFullscreen)
        b.toolTip = "Toggle full screen"

        return b
    }()

    private lazy var volumeButton: PUIButton = {
        let b = PUIButton(frame: .zero)

        b.image = .PUIVolume
        b.target = self
        b.action = #selector(toggleMute)
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.toolTip = "Mute/unmute"

        return b
    }()

    fileprivate lazy var volumeSlider: PUISlider = {
        let s = PUISlider(frame: .zero)

        s.widthAnchor.constraint(equalToConstant: 88).isActive = true
        s.isContinuous = true
        s.target = self
        s.minValue = 0
        s.maxValue = 1
        s.action = #selector(volumeSliderAction)

        return s
    }()

    private lazy var subtitlesButton: PUIButton = {
        let b = PUIButton(frame: .zero)

        b.image = .PUISubtitles
        b.target = self
        b.action = #selector(showSubtitlesMenu)
        b.toolTip = "Subtitles"

        return b
    }()

    fileprivate lazy var playButton: PUIButton = {
        let b = PUIButton(frame: .zero)

        b.image = .PUIPlay
        b.target = self
        b.action = #selector(togglePlaying)
        b.toolTip = "Play/pause"

        return b
    }()

    private lazy var previousAnnotationButton: PUIButton = {
        let b = PUIButton(frame: .zero)

        b.image = .PUIPreviousBookmark
        b.target = self
        b.action = #selector(previousAnnotation)
        b.toolTip = "Go to previous bookmark"

        return b
    }()

    private lazy var nextAnnotationButton: PUIButton = {
        let b = PUIButton(frame: .zero)

        b.image = .PUINextBookmark
        b.target = self
        b.action = #selector(nextAnnotation)
        b.toolTip = "Go to next bookmark"

        return b
    }()

    private lazy var backButton: PUIButton = {
        let b = PUIButton(frame: .zero)

        b.image = .PUIBack15s
        b.target = self
        b.action = #selector(goBackInTime15)
        b.toolTip = "Go back 15s"

        return b
    }()

    private lazy var forwardButton: PUIButton = {
        let b = PUIButton(frame: .zero)

        b.image = .PUIForward15s
        b.target = self
        b.action = #selector(goForwardInTime15)
        b.toolTip = "Go forward 15s"

        return b
    }()

    fileprivate lazy var speedButton: PUIButton = {
        let b = PUIButton(frame: .zero)

        b.image = .PUISpeedOne
        b.target = self
        b.action = #selector(toggleSpeed)
        b.toolTip = "Change playback speed"
        b.menu = self.speedsMenu
        b.showsMenuOnRightClick = true

        return b
    }()

    private lazy var addAnnotationButton: PUIButton = {
        let b = PUIButton(frame: .zero)

        b.image = .PUIBookmark
        b.target = self
        b.action = #selector(addAnnotation)
        b.toolTip = "Add bookmark"

        return b
    }()

    private lazy var pipButton: PUIButton = {
        let b = PUIButton(frame: .zero)

        b.isToggle = true
        b.image = .PUIPictureInPicture
        b.target = self
        b.action = #selector(togglePip)
        b.toolTip = "Toggle picture in picture"

        return b
    }()

    private var extrasMenuTopConstraint: NSLayoutConstraint!

    private lazy var externalStatusController = PUIExternalPlaybackStatusViewController()

    private func setupControls() {
        externalStatusController.view.isHidden = true
        externalStatusController.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(externalStatusController.view)
        externalStatusController.view.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        externalStatusController.view.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        externalStatusController.view.topAnchor.constraint(equalTo: topAnchor).isActive = true
        externalStatusController.view.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true

        //        // VFX view
        //        controlsVisualEffectView = NSVisualEffectView(frame: bounds)
        //        controlsVisualEffectView.translatesAutoresizingMaskIntoConstraints = false
        //        controlsVisualEffectView.material = .ultraDark
        //        controlsVisualEffectView.appearance = NSAppearance(named: NSAppearanceNameVibrantDark)
        //        controlsVisualEffectView.blendingMode = .withinWindow
        //        controlsVisualEffectView.wantsLayer = true
        //        controlsVisualEffectView.layer?.masksToBounds = false
        //        controlsVisualEffectView.state = .active
        scrimContainerView = PUIScrimContainerView(frame: bounds)

        // Time labels
        timeLabelsContainerView = NSStackView(views: [elapsedTimeLabel, remainingTimeLabel])
        timeLabelsContainerView.distribution = .fillEqually
        timeLabelsContainerView.orientation = .horizontal
        timeLabelsContainerView.alignment = .centerY

        // Timeline view
        timelineView = PUITimelineView(frame: .zero)
        timelineView.viewDelegate = self

        // Volume controls
        volumeControlsContainerView = NSStackView(views: [volumeButton, volumeSlider])

        volumeControlsContainerView.orientation = .horizontal
        volumeControlsContainerView.spacing = 6
        volumeControlsContainerView.alignment = .centerY

        // Center Buttons
        centerButtonsContainerView = NSStackView(frame: bounds)

        // Leading controls (volume, subtitles)
        centerButtonsContainerView.addView(volumeButton, in: NSStackView.Gravity.leading)
        centerButtonsContainerView.addView(volumeSlider, in: NSStackView.Gravity.leading)
        centerButtonsContainerView.addView(subtitlesButton, in: NSStackView.Gravity.leading)

        centerButtonsContainerView.setCustomSpacing(6, after: volumeButton)

        // Center controls (play, annotations, forward, backward)
        centerButtonsContainerView.addView(backButton, in: .center)
        centerButtonsContainerView.addView(previousAnnotationButton, in: .center)
        centerButtonsContainerView.addView(playButton, in: .center)
        centerButtonsContainerView.addView(nextAnnotationButton, in: .center)
        centerButtonsContainerView.addView(forwardButton, in: .center)

        // Trailing controls (speed, add annotation, pip)
        centerButtonsContainerView.addView(speedButton, in: NSStackView.Gravity.trailing)
        centerButtonsContainerView.addView(addAnnotationButton, in: NSStackView.Gravity.trailing)
        centerButtonsContainerView.addView(pipButton, in: NSStackView.Gravity.trailing)

        centerButtonsContainerView.orientation = .horizontal
        centerButtonsContainerView.spacing = 24
        centerButtonsContainerView.distribution = .gravityAreas
        centerButtonsContainerView.alignment = .centerY

        // Visibility priorities
        centerButtonsContainerView.setVisibilityPriority(NSStackView.VisibilityPriority.detachOnlyIfNecessary, for: volumeButton)
        centerButtonsContainerView.setVisibilityPriority(NSStackView.VisibilityPriority.detachOnlyIfNecessary, for: volumeSlider)
        centerButtonsContainerView.setVisibilityPriority(NSStackView.VisibilityPriority.detachOnlyIfNecessary, for: subtitlesButton)
        centerButtonsContainerView.setVisibilityPriority(NSStackView.VisibilityPriority.detachOnlyIfNecessary, for: backButton)
        centerButtonsContainerView.setVisibilityPriority(NSStackView.VisibilityPriority.detachOnlyIfNecessary, for: previousAnnotationButton)
        centerButtonsContainerView.setVisibilityPriority(NSStackView.VisibilityPriority.mustHold, for: playButton)
        centerButtonsContainerView.setVisibilityPriority(NSStackView.VisibilityPriority.detachOnlyIfNecessary, for: forwardButton)
        centerButtonsContainerView.setVisibilityPriority(NSStackView.VisibilityPriority.detachOnlyIfNecessary, for: nextAnnotationButton)
        centerButtonsContainerView.setVisibilityPriority(NSStackView.VisibilityPriority.detachOnlyIfNecessary, for: speedButton)
        centerButtonsContainerView.setVisibilityPriority(NSStackView.VisibilityPriority.detachOnlyIfNecessary, for: addAnnotationButton)
        centerButtonsContainerView.setVisibilityPriority(NSStackView.VisibilityPriority.detachOnlyIfNecessary, for: pipButton)
        centerButtonsContainerView.setContentCompressionResistancePriority(NSLayoutConstraint.Priority.defaultLow, for: .horizontal)

        // Main stack view
        controlsContainerView = NSStackView(views: [
            timeLabelsContainerView,
            timelineView,
            centerButtonsContainerView
            ])

        controlsContainerView.orientation = .vertical
        controlsContainerView.spacing = 12
        controlsContainerView.distribution = .fill
        controlsContainerView.translatesAutoresizingMaskIntoConstraints = false
        controlsContainerView.wantsLayer = true
        controlsContainerView.layer?.masksToBounds = false
        controlsContainerView.layer?.zPosition = 10

        addSubview(scrimContainerView)
        addSubview(controlsContainerView)

        scrimContainerView.translatesAutoresizingMaskIntoConstraints = false
        scrimContainerView.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        scrimContainerView.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        scrimContainerView.topAnchor.constraint(equalTo: topAnchor).isActive = true
        scrimContainerView.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true

        controlsContainerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12).isActive = true
        controlsContainerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12).isActive = true
        controlsContainerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12).isActive = true

        timeLabelsContainerView.leadingAnchor.constraint(equalTo: controlsContainerView.leadingAnchor).isActive = true
        timeLabelsContainerView.trailingAnchor.constraint(equalTo: controlsContainerView.trailingAnchor).isActive = true

        centerButtonsContainerView.leadingAnchor.constraint(equalTo: controlsContainerView.leadingAnchor).isActive = true
        centerButtonsContainerView.trailingAnchor.constraint(equalTo: controlsContainerView.trailingAnchor).isActive = true

        // Extras menu (external playback, fullscreen button)
        extrasMenuContainerView = NSStackView(views: [fullScreenButton])
        extrasMenuContainerView.orientation = .horizontal
        extrasMenuContainerView.alignment = .centerY
        extrasMenuContainerView.distribution = .equalSpacing
        extrasMenuContainerView.spacing = 30

        addSubview(extrasMenuContainerView)

        extrasMenuContainerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12).isActive = true
        updateExtrasMenuPosition()
    }

    private func configureWithAppearanceFromDelegate() {
        guard let d = appearanceDelegate else { return }

        subtitlesButton.isHidden = !d.playerViewShouldShowSubtitlesControl(self)
        pipButton.isHidden = !d.playerViewShouldShowPictureInPictureControl(self)
        speedButton.isHidden = !d.playerViewShouldShowSpeedControl(self)

        let disableAnnotationControls = !d.playerViewShouldShowAnnotationControls(self)
        addAnnotationButton.isHidden = disableAnnotationControls
        previousAnnotationButton.isHidden = disableAnnotationControls
        nextAnnotationButton.isHidden = disableAnnotationControls

        let disableBackAndForward = !d.playerViewShouldShowBackAndForwardControls(self)
        backButton.isHidden = disableBackAndForward
        forwardButton.isHidden = disableBackAndForward

        let skipBy30 = d.PlayerViewShouldShowBackAndForward30SecondsButtons(self)
        backButton.image = skipBy30 ? .PUIBack30s : .PUIBack15s
        backButton.action = skipBy30 ? #selector(goBackInTime30) : #selector(goBackInTime15)
        backButton.toolTip = skipBy30 ? "Go back 30s" : "Go back 15s"
        forwardButton.image = skipBy30 ? .PUIForward30s : .PUIForward15s
        forwardButton.action = skipBy30 ? #selector(goForwardInTime30) : #selector(goForwardInTime15)
        forwardButton.toolTip = skipBy30 ? "Go forward 30s" : "Go forward 15s"

        updateExternalPlaybackControlsAvailability()

        fullScreenButton.isHidden = !d.playerViewShouldShowFullScreenButton(self)
        timelineView.isHidden = !d.playerViewShouldShowTimelineView(self)
        timeLabelsContainerView.isHidden = !d.playerViewShouldShowTimestampLabels(self)
    }

    fileprivate func updateExternalPlaybackControlsAvailability() {
        guard let d = appearanceDelegate else { return }

        let disableExternalPlayback = !d.playerViewShouldShowExternalPlaybackControls(self)
        externalPlaybackProviders.forEach({ $0.button.isHidden = disableExternalPlayback })
    }

    private var isDominantViewInWindow: Bool {
        guard let contentView = window?.contentView else { return false }
        guard contentView != self else { return true }

        return bounds.height >= contentView.bounds.height
    }

    private func updateExtrasMenuPosition() {
        let topConstant: CGFloat = isDominantViewInWindow ? 34 : 12

        if extrasMenuTopConstraint == nil {
            extrasMenuTopConstraint = extrasMenuContainerView.topAnchor.constraint(equalTo: topAnchor, constant: topConstant)
            extrasMenuTopConstraint.isActive = true
        } else {
            extrasMenuTopConstraint.constant = topConstant
        }
    }

    fileprivate func updateExternalPlaybackMenus() {
        // clean menu
        extrasMenuContainerView.arrangedSubviews.enumerated().forEach { idx, v in
            guard idx < extrasMenuContainerView.arrangedSubviews.count - 1 else { return }

            extrasMenuContainerView.removeArrangedSubview(v)
        }

        // repopulate
        externalPlaybackProviders.filter({ $0.provider.isAvailable }).forEach { registration in
            registration.button.menu = registration.menu
            extrasMenuContainerView.insertArrangedSubview(registration.button, at: 0)
        }
    }

    private func button(for provider: PUIExternalPlaybackProvider) -> PUIButton {
        let b = PUIButton(frame: .zero)

        b.image = provider.icon
        b.toolTip = type(of: provider).name
        b.showsMenuOnLeftClick = true

        return b
    }

    // MARK: - Control actions

    private var playerVolumeBeforeMuting: Float = 1.0

    @IBAction public func toggleMute(_ sender: Any?) {
        guard let player = player else { return }

        if player.volume.isZero {
            player.volume = playerVolumeBeforeMuting
        } else {
            playerVolumeBeforeMuting = player.volume
            player.volume = 0
        }
    }

    @IBAction func volumeSliderAction(_ sender: Any?) {
        guard let player = player else { return }

        let v = Float(volumeSlider.doubleValue)

        if isPlayingExternally {
            currentExternalPlaybackProvider?.setVolume(v)
        } else {
            player.volume = v
        }
    }

    @IBAction public func togglePlaying(_ sender: Any?) {
        if isPlaying {
            pause(sender)
        } else {
            play(sender)
        }
    }

    @IBAction public func pause(_ sender: Any?) {
        if isPlayingExternally {
            currentExternalPlaybackProvider?.pause()
        } else {
            player?.rate = 0
        }
    }

    @IBAction public func play(_ sender: Any?) {
        if isPlayingExternally {
            currentExternalPlaybackProvider?.play()
        } else {
            player?.rate = playbackSpeed.rawValue
        }
    }

    @IBAction public func previousAnnotation(_ sender: Any?) {
        guard let annotation = firstAnnotationBeforeCurrentTime else { return }

        seek(to: annotation)
    }

    @IBAction public func nextAnnotation(_ sender: Any?) {
        guard let annotation = firstAnnotationAfterCurrentTime else { return }

        seek(to: annotation)
    }

    @IBAction public func goBackInTime15(_ sender: Any?) {
        modifyCurrentTime(with: 15, using: CMTimeSubtract)
    }

    @IBAction public func goForwardInTime15(_ sender: Any?) {
        modifyCurrentTime(with: 15, using: CMTimeAdd)
    }

    @IBAction public func goBackInTime30(_ sender: Any?) {
        modifyCurrentTime(with: 30, using: CMTimeSubtract)
    }

    @IBAction public func goForwardInTime30(_ sender: Any?) {
        modifyCurrentTime(with: 30, using: CMTimeAdd)
    }

    @IBAction public func toggleSpeed(_ sender: Any?) {
        playbackSpeed = playbackSpeed.next
    }

    @IBAction public func addAnnotation(_ sender: NSView?) {
        guard let player = player else { return }

        let timestamp = Double(CMTimeGetSeconds(player.currentTime()))

        delegate?.playerViewDidSelectAddAnnotation(self, at: timestamp)
    }

    @IBAction public func togglePip(_ sender: NSView?) {
        if isInPictureInPictureMode {
            exitPictureInPictureMode()
        } else {
            enterPictureInPictureMode()
        }
    }

    @IBAction public func toggleFullscreen(_ sender: Any?) {
        delegate?.playerViewDidSelectToggleFullScreen(self)
    }

    private func modifyCurrentTime(with seconds: Double, using function: (CMTime, CMTime) -> CMTime) {
        guard let player = player else { return }

        guard let durationTime = player.currentItem?.duration else { return }

        let modifier = CMTimeMakeWithSeconds(seconds, durationTime.timescale)
        let targetTime = function(player.currentTime(), modifier)

        guard targetTime.isValid && targetTime.isNumeric else { return }

        if isPlayingExternally {
            currentExternalPlaybackProvider?.seek(to: seconds)
        } else {
            player.seek(to: targetTime)
        }
    }

    // MARK: - Subtitles

    private var subtitlesMenu: NSMenu?
    private var subtitlesGroup: AVMediaSelectionGroup?

    private func updateMediaSelection() {
        guard let playerItem = player?.currentItem else { return }

        guard let subtitlesGroup = playerItem.asset.mediaSelectionGroup(forMediaCharacteristic: AVMediaCharacteristic.legible) else {
            subtitlesButton.isHidden = true
            return
        }

        self.subtitlesGroup = subtitlesGroup

        subtitlesButton.isHidden = false

        let menu = NSMenu()

        subtitlesGroup.options.forEach { option in
            let item = NSMenuItem(title: option.displayName, action: #selector(didSelectSubtitleOption), keyEquivalent: "")
            item.representedObject = option
            item.target = self

            menu.addItem(item)
        }

        subtitlesMenu = menu
    }

    @objc fileprivate func didSelectSubtitleOption(_ sender: NSMenuItem) {
        guard let subtitlesGroup = subtitlesGroup else { return }
        guard let option = sender.representedObject as? AVMediaSelectionOption else { return }

        // reset all item's states
        sender.menu?.items.forEach({ $0.state = .on })

        if option.extendedLanguageTag == player?.currentItem?.selectedMediaOption(in: subtitlesGroup)?.extendedLanguageTag {
            player?.currentItem?.select(nil, in: subtitlesGroup)
            sender.state = .off
            return
        }

        player?.currentItem?.select(option, in: subtitlesGroup)

        sender.state = .on
    }

    @IBAction func showSubtitlesMenu(_ sender: PUIButton) {
        subtitlesMenu?.popUp(positioning: nil, at: .zero, in: sender)
    }

    // MARK: - Playback speeds

    fileprivate lazy var speedsMenu: NSMenu = {
        let m = NSMenu()
        for speed in PUIPlaybackSpeed.all {
            let item = NSMenuItem(title: "\(String(format: "%g", speed.rawValue))x", action: #selector(didSelectSpeed), keyEquivalent: "")
            item.target = self
            item.representedObject = speed
            item.state = speed == self.playbackSpeed ? .on : .off
            m.addItem(item)
        }
        return m
    }()

    fileprivate func updateSelectedMenuItem(forPlaybackSpeed speed: PUIPlaybackSpeed) {
        for item in speedsMenu.items {
            item.state = (item.representedObject as? PUIPlaybackSpeed) == speed ? .on : .off
        }
    }

    @objc private func didSelectSpeed(_ sender: NSMenuItem) {
        guard let speed = sender.representedObject as? PUIPlaybackSpeed else {
            return
        }
        playbackSpeed = speed
    }

    // MARK: - Key commands

    private var keyDownEventMonitor: Any?

    private enum KeyCommands: UInt16 {
        case spaceBar = 49
    }

    private func startMonitoringKeyEvents() {
        if keyDownEventMonitor != nil {
            stopMonitoringKeyEvents()
        }

        keyDownEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [NSEvent.EventTypeMask.keyDown]) { [unowned self] event in
            guard let command = KeyCommands(rawValue: event.keyCode) else {
                return event
            }

            // ignore keystrokes when editing text
            guard !(self.window?.firstResponder is NSTextView) else { return event }
            guard !self.timelineView.isEditingAnnotation else { return event }

            switch command {
            case .spaceBar:
                self.togglePlaying(nil)
                return nil
            }
        }
    }

    private func stopMonitoringKeyEvents() {
        if let keyDownEventMonitor = keyDownEventMonitor {
            NSEvent.removeMonitor(keyDownEventMonitor)
        }

        keyDownEventMonitor = nil
    }



    // MARK: - PiP Support

    public func snapshotPlayer(completion: @escaping (NSImage?) -> Void) {
        guard let currentTime = player?.currentTime() else {
            completion(nil)
            return
        }
        guard let asset = player?.currentItem?.asset else {
            completion(nil)
            return
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        let time = NSValue(time: currentTime)
        generator.generateCGImagesAsynchronously(forTimes: [time]) { _, rawImage, _, result, error in
            guard let rawImage = rawImage, error == nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let image = NSImage(cgImage: rawImage, size: NSSize(width: rawImage.width, height: rawImage.height))
            DispatchQueue.main.async { completion(image) }
        }
    }

    fileprivate var pipController: PIPViewController?

    fileprivate func enterPictureInPictureMode() {
        delegate?.playerViewWillEnterPictureInPictureMode(self)

        snapshotPlayer { [weak self] image in
            self?.externalStatusController.snapshot = image
        }

        pipController = PIPViewController()
        pipController?.delegate = self
        pipController?.setPlaying(isPlaying)
        pipController?.aspectRatio = currentPresentationSize ?? NSSize(width: 640, height: 360)
        pipController?.view.layer?.backgroundColor = NSColor.black.cgColor

        pipController?.presentAsPicture(inPicture: pictureContainer)

        isInPictureInPictureMode = true
    }

    fileprivate func exitPictureInPictureMode() {
        if pictureContainer.presenting == pipController {
            pipController?.dismissViewController(pictureContainer)
        }
    }

    // MARK: - Visibility management

    fileprivate var canHideControls: Bool {
        guard let player = player else { return false }

        guard isPlaying else { return false }
        guard player.status == .readyToPlay else { return false }
        guard let window = window else { return false }

        guard !timelineView.isEditingAnnotation else { return false }

        let windowMouseRect = window.convertFromScreen(NSRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 1)))
        let viewMouseRect = convert(windowMouseRect, from: nil)

        // don't hide the controls when the mouse is over them
        return !viewMouseRect.intersects(controlsContainerView.frame)
    }

    fileprivate var mouseIdleTimer: Timer!

    fileprivate func resetMouseIdleTimer(start: Bool = true) {
        if mouseIdleTimer != nil {
            mouseIdleTimer.invalidate()
            mouseIdleTimer = nil
        }

        if start {
            mouseIdleTimer = Timer.scheduledTimer(timeInterval: 3.0, target: self, selector: #selector(mouseIdleTimerAction), userInfo: nil, repeats: false)
        }
    }

    @objc fileprivate func mouseIdleTimerAction(_ sender: Timer) {
        guard canHideControls else { return }

        if !isInPictureInPictureMode {
            NSCursor.hide()
        }

        hideControls(animated: true)
    }

    private func hideControls(animated: Bool) {
        guard canHideControls else { return }

        setControls(opacity: 0, animated: animated)
    }

    private func showControls(animated: Bool) {
        NSCursor.unhide()

        setControls(opacity: 1, animated: animated)
    }

    private func setControls(opacity: CGFloat, animated: Bool) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animated ? 0.4 : 0.0
            scrimContainerView.animator().alphaValue = opacity
            controlsContainerView.animator().alphaValue = opacity
            extrasMenuContainerView.animator().alphaValue = opacity
        }, completionHandler: nil)
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willEnterFullScreenNotification, object: window)
        NotificationCenter.default.removeObserver(self, name: NSWindow.willExitFullScreenNotification, object: window)

        NotificationCenter.default.addObserver(self, selector: #selector(windowWillEnterFullScreen), name: NSWindow.willEnterFullScreenNotification, object: newWindow)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillExitFullScreen), name: NSWindow.willExitFullScreenNotification, object: newWindow)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        resetMouseIdleTimer()
        updateExtrasMenuPosition()

        if window != nil {
            lastKnownWindow = window
            startMonitoringKeyEvents()
        }
    }

    private var windowIsInFullScreen: Bool {
        guard let window = window else { return false }

        return window.styleMask.contains(NSWindow.StyleMask.fullScreen)
    }

    @objc private func windowWillEnterFullScreen() {
        fullScreenButton.isHidden = true
        updateExtrasMenuPosition()
    }

    @objc private func windowWillExitFullScreen() {
        fullScreenButton.isHidden = false
        updateExtrasMenuPosition()
    }

    // MARK: - Events

    private var mouseTrackingArea: NSTrackingArea!

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if mouseTrackingArea != nil {
            removeTrackingArea(mouseTrackingArea)
        }

        let options: NSTrackingArea.Options = [NSTrackingArea.Options.mouseEnteredAndExited, NSTrackingArea.Options.mouseMoved, NSTrackingArea.Options.activeAlways, NSTrackingArea.Options.inVisibleRect]
        mouseTrackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)

        addTrackingArea(mouseTrackingArea)
    }

    public override func mouseEntered(with event: NSEvent) {
        showControls(animated: true)
        resetMouseIdleTimer()

        super.mouseExited(with: event)
    }

    public override func mouseMoved(with event: NSEvent) {
        showControls(animated: true)
        resetMouseIdleTimer()

        super.mouseMoved(with: event)
    }

    public override func mouseExited(with event: NSEvent) {
        resetMouseIdleTimer(start: false)

        hideControls(animated: true)

        super.mouseExited(with: event)
    }

    public override var acceptsFirstResponder: Bool {
        return true
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    public override func mouseDown(with event: NSEvent) {
        if event.type == .leftMouseDown && event.clickCount == 2 {
            toggleFullscreen(self)
        } else {
            super.mouseDown(with: event)
        }
    }

    // MARK: - External playback state management

    private func unhighlightExternalPlaybackButtons() {
        externalPlaybackProviders.forEach { registration in
            registration.button.tintColor = .buttonColor
        }
    }

    fileprivate var currentExternalPlaybackProvider: PUIExternalPlaybackProvider? {
        didSet {
            if currentExternalPlaybackProvider != nil {
                perform(#selector(transitionToExternalPlayback), with: nil, afterDelay: 0)
            } else {
                transitionToInternalPlayback()
            }
        }
    }

    @objc private func transitionToExternalPlayback() {
        guard let current = currentExternalPlaybackProvider else {
            transitionToInternalPlayback()
            return
        }

        let currentProviderName = type(of: current).name

        unhighlightExternalPlaybackButtons()

        guard let registration = externalPlaybackProviders.first(where: { type(of: $0.provider).name == currentProviderName }) else { return }

        registration.button.tintColor = .playerHighlight

        snapshotPlayer { [weak self] image in
            self?.externalStatusController.snapshot = image
        }

        externalStatusController.providerIcon = current.image
        externalStatusController.providerName = currentProviderName
        externalStatusController.providerDescription = "Playing in \(currentProviderName)" + "\n" + current.info
        externalStatusController.view.isHidden = false

        pipButton.isEnabled = false
        subtitlesButton.isEnabled = false
        speedButton.isEnabled = false
        forwardButton.isEnabled = false
        backButton.isEnabled = false

        controlsContainerView.alphaValue = 0.5
    }

    @objc private func transitionToInternalPlayback() {
        unhighlightExternalPlaybackButtons()

        pipButton.isEnabled = true
        subtitlesButton.isEnabled = true
        speedButton.isEnabled = true
        forwardButton.isEnabled = true
        backButton.isEnabled = true

        controlsContainerView.alphaValue = 1

        externalStatusController.view.isHidden = true
    }

}

// MARK: - PUITimelineViewDelegate

extension PUIPlayerView: PUITimelineViewDelegate {

    func timelineDidReceiveForceTouch(at timestamp: Double) {
        guard let player = player else { return }

        let timestamp = Double(CMTimeGetSeconds(player.currentTime()))

        delegate?.playerViewDidSelectAddAnnotation(self, at: timestamp)
    }

    func timelineViewWillBeginInteractiveSeek() {
        wasPlayingBeforeStartingInteractiveSeek = isPlaying

        pause(nil)
    }

    func timelineViewDidSeek(to progress: Double) {
        guard let duration = asset?.duration else { return }

        let targetTime = progress * Double(CMTimeGetSeconds(duration))
        let time = CMTimeMakeWithSeconds(targetTime, duration.timescale)

        if isPlayingExternally {
            currentExternalPlaybackProvider?.seek(to: targetTime)
        } else {
            player?.seek(to: time)
        }
    }

    func timelineViewDidFinishInteractiveSeek() {
        if wasPlayingBeforeStartingInteractiveSeek {
            play(nil)
        }
    }

}

// MARK: - External playback support

extension PUIPlayerView: PUIExternalPlaybackConsumer {

    private func isCurrentProvider(_ provider: PUIExternalPlaybackProvider) -> Bool {
        guard let currentProvider = currentExternalPlaybackProvider else { return false }

        return type(of: provider).name == type(of: currentProvider).name
    }

    public func externalPlaybackProviderDidChangeMediaStatus(_ provider: PUIExternalPlaybackProvider) {
        volumeSlider.doubleValue = Double(provider.status.volume)

        if let speed = PUIPlaybackSpeed(rawValue: provider.status.rate) {
            playbackSpeed = speed
        }

        let time = CMTimeMakeWithSeconds(Float64(provider.status.currentTime), 9000)
        playerTimeDidChange(time: time)

        updatePlayingState()
    }

    public func externalPlaybackProviderDidChangeAvailabilityStatus(_ provider: PUIExternalPlaybackProvider) {
        updateExternalPlaybackMenus()
        updateExternalPlaybackControlsAvailability()

        if !provider.isAvailable && isCurrentProvider(provider) {
            // current provider got invalidated, go back to internal playback
            currentExternalPlaybackProvider = nil
        }
    }

    public func externalPlaybackProviderDidInvalidatePlaybackSession(_ provider: PUIExternalPlaybackProvider) {
        if isCurrentProvider(provider) {
            let wasPlaying = !provider.status.rate.isZero

            // provider session invalidated, go back to internal playback
            currentExternalPlaybackProvider = nil

            if wasPlaying {
                player?.play()
                updatePlayingState()
            }
        }
    }

    public func externalPlaybackProvider(_ provider: PUIExternalPlaybackProvider, deviceSelectionMenuDidChangeWith menu: NSMenu) {
        guard let registrationIndex = externalPlaybackProviders.index(where: { type(of: $0.provider).name == type(of: provider).name }) else { return }

        externalPlaybackProviders[registrationIndex].menu = menu
    }

    public func externalPlaybackProviderDidBecomeCurrent(_ provider: PUIExternalPlaybackProvider) {
        if isInternalPlayerPlaying {
            player?.rate = 0
        }

        currentExternalPlaybackProvider = provider
    }

}

// MARK: - PiP delegate

extension PUIPlayerView: PIPViewControllerDelegate, PUIPictureContainerViewControllerDelegate {

    public func pipActionStop(_ pip: PIPViewController) {
        pause(pip)
        delegate?.playerViewWillExitPictureInPictureMode(self, isReturningFromPiP: false)
    }

    public func pipActionReturn(_ pip: PIPViewController) {
        delegate?.playerViewWillExitPictureInPictureMode(self, isReturningFromPiP: true)

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        if let window = lastKnownWindow {
            window.makeKeyAndOrderFront(pip)

            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
        }
    }

    public func pipActionPause(_ pip: PIPViewController) {
        pause(pip)
    }

    public func pipActionPlay(_ pip: PIPViewController) {
        play(pip)
    }

    public func pipDidClose(_ pip: PIPViewController) {
        pictureContainer.view.frame = bounds

        addSubview(pictureContainer.view, positioned: .below, relativeTo: scrimContainerView)

        isInPictureInPictureMode = false
        pipController = nil
    }

    public func pipWillClose(_ pip: PIPViewController) {
        pip.replacementRect = frame
        pip.replacementView = self
        pip.replacementWindow = lastKnownWindow
    }

    func pictureContainerViewSuperviewDidChange(to superview: NSView?) {
        guard let superview = superview else { return }

        pictureContainer.view.frame = superview.bounds

        if superview == self, pipController != nil {
            if pictureContainer.presenting == pipController {
                pipController?.dismissViewController(pictureContainer)
            }
            
            pipController = nil
        }
    }
    
}
