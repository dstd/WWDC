//
//  VideoWindowController.swift
//  WWDC
//
//  Created by Guilherme Rambo on 19/04/15.
//  Copyright (c) 2015 Guilherme Rambo. All rights reserved.
//

import Cocoa
import AVFoundation
import AVKit
import ASCIIwwdc
import ViewUtils

private let _nibName = "VideoWindowController"

class VideoWindowController: NSWindowController {

    var session: Session?
    var event: LiveEvent?
    
    var videoURL: String?
    
    var asset: AVAsset!
    var item: AVPlayerItem!
    
    var transcriptWC: TranscriptWindowController!
    var playerWindow: GRPlayerWindow {
        get {
            return window as! GRPlayerWindow
        }
    }
    var videoNaturalSize = CGSizeZero

    convenience init(session: Session, videoURL: String) {
        self.init(windowNibName: _nibName)
        self.session = session
        self.videoURL = videoURL
    }
    
    convenience init(event: LiveEvent, videoURL: String) {
        self.init(windowNibName: _nibName)
        self.event = event
        self.videoURL = videoURL
        NSNotificationCenter.defaultCenter().addObserverForName(LiveEventTitleAvailableNotification, object: nil, queue: NSOperationQueue.mainQueue()) { note in
            if let title = note.object as? String {
                self.window?.title = "\(title) (Live)"
            }
        }
    }
    
    @IBOutlet weak var customPlayerView: GRCustomPlayerView!
    @IBOutlet weak var playerView: AVPlayerView!
    @IBOutlet weak var progressIndicator: NSProgressIndicator!
    var player: AVPlayer? {
        didSet {
            if let player = player {
                if let args = NSProcessInfo.processInfo().arguments as? [String] {
                    if args.contains("zerovolume") {
                        player.volume = 0
                    }
                }
            }
        }
    }
    
    var selectedPlaybackRate: Float = 1.0
    var notificationObservers: [AnyObject] = []
    var playbackStateObserver: AVPlayerPlaybackStateObserver?
    var keysMonitorLocal, keysMonitorGlobal: AnyObject?
    
    private var activity: NSObjectProtocol?
    
    override func windowDidLoad() {
        super.windowDidLoad()
        
        activity = NSProcessInfo.processInfo().beginActivityWithOptions(.IdleDisplaySleepDisabled | .IdleSystemSleepDisabled, reason: "Playing WWDC session video")

        progressIndicator.startAnimation(nil)
        window?.backgroundColor = NSColor.blackColor()

        self.updateFloatOnTopMenuState()
        self.updatePlaybackRateMenuState()

        if let url = NSURL(string: videoURL!) {
            if event == nil {
                player = AVPlayer(URL: url)
                playerView.player = player
                
                // SESSION
                player?.currentItem.asset.loadValuesAsynchronouslyForKeys(["tracks"]) {
                    dispatch_async(dispatch_get_main_queue()) {
                        self.setupWindowSizing()
                        self.setupTimeObserver()
                        
                        if let session = self.session {
                            if session.currentPosition > 0 {
                                self.player?.seekToTime(CMTimeMakeWithSeconds(session.currentPosition, 1))
                            }
                        }
                        
                        self.player?.play()
                        self.progressIndicator.stopAnimation(nil)
                    }
                }
                
                self.updateFloatOnTopWindowState()
                if let player = self.player {
                    self.playbackStateObserver = AVPlayerPlaybackStateObserver(player: player, period: 1.0) { isPlaying in
                        self.updateFloatOnTopWindowState()
                        if isPlaying {
                            self.player?.rate = self.selectedPlaybackRate
                        }
                    }
                }
            }
        }
        
        if let session = self.session {
            window?.title = "WWDC \(session.year) | \(session.title)"
            
            // pause playback when a live event starts playing
            self.notificationObservers.append(NSNotificationCenter.defaultCenter().addObserverForName(LiveEventWillStartPlayingNotification, object: nil, queue: nil) { _ in
                self.player?.pause()
            })
        }
        
        if let event = self.event {
            window?.title = "\(event.title) (Live)"
            
            loadEventVideo()
        }
        
        self.notificationObservers.append(NSNotificationCenter.defaultCenter().addObserverForName(NSWindowWillCloseNotification, object: self.window, queue: nil) { _ in
            if let activity = self.activity {
                NSProcessInfo.processInfo().endActivity(activity)
            }
            
            if self.event != nil {
                if self.item != nil {
                    self.item.removeObserver(self, forKeyPath: "status")
                }
            }
            
            self.transcriptWC?.close()
            
            self.player?.pause()
            
            self.removeAllObservers()
        })
        
        setupKeyHoldObservers()
    }
    
    func removeAllObservers() {
        let defaultCenter = NSNotificationCenter.defaultCenter()
        for observer in self.notificationObservers {
            defaultCenter.removeObserver(observer)
        }
        self.notificationObservers.removeAll(keepCapacity: false)
        
        if let observer: AnyObject = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let observer: AnyObject = boundaryObserver {
            player?.removeTimeObserver(observer)
            boundaryObserver = nil
        }
        
        if let observer = playbackStateObserver {
            observer.disposeObserver()
            playbackStateObserver = nil
        }
        
        if let observer: AnyObject = keysMonitorLocal {
            NSEvent.removeMonitor(observer)
            keysMonitorLocal = nil
        }
        
        if let observer: AnyObject = keysMonitorGlobal {
            NSEvent.removeMonitor(observer)
            keysMonitorGlobal = nil
        }
        
        if let trackingRect = self.trackingRect {
            playerView!.removeTrackingRect(trackingRect)
            self.trackingRect = nil
        }
    }
    
    // MARK: - Monitoring for Quick Switch to Fullscreen feature
    
    func setupKeyHoldObservers() {
        // use the mouse tracking as a workaround if global monitoring is not available
        updateTrackingAreas()
        
        keysMonitorLocal = NSEvent.addLocalMonitorForEventsMatchingMask(NSEventMask.KeyDownMask|NSEventMask.FlagsChangedMask, handler: keyPressedLocal)
        keysMonitorGlobal = NSEvent.addGlobalMonitorForEventsMatchingMask(NSEventMask.KeyDownMask|NSEventMask.FlagsChangedMask, handler: keyPressedGlobal)
    }
    
    func keyPressedLocal(event: NSEvent!) -> NSEvent {
        checkFullscreenQuickSwitch()
        return event
    }
    
    func keyPressedGlobal(event: NSEvent!) {
        let mouse = NSEvent.mouseLocation()
        let mouseInside = NSWindow.windowNumberAtPoint(mouse, belowWindowWithWindowNumber: 0) == playerWindow.windowNumber
        if mouseInside {
            let kVK_LeftArrow: UInt16 = 123
            let kVK_RightArrow: UInt16 = 124
            if event.keyCode == kVK_LeftArrow {
                jumpTimeWithDelta(seconds: -5.0)
                return
            }
            if event.keyCode == kVK_RightArrow {
                jumpTimeWithDelta(seconds: 5.0)
                return
            }
        }
        
        checkFullscreenQuickSwitch()
    }
    
    func windowDidResize(notification: NSNotification) {
        updateTrackingAreas()
    }
    
    var trackingRect: NSTrackingRectTag?
    func updateTrackingAreas() {
        if let trackingRect = self.trackingRect {
            playerView!.removeTrackingRect(trackingRect)
            self.trackingRect = nil
        }
        
        trackingRect = playerView!.addTrackingRect(playerView!.bounds, owner: self, userData: nil, assumeInside: false)
    }
    
    override func mouseMoved(theEvent: NSEvent) {
        checkFullscreenQuickSwitch()
    }
    
    var frameForNonFullscreenMode: CGRect?
    func checkFullscreenQuickSwitch() {
        let mouse = NSEvent.mouseLocation()
        let mouseInside = NSWindow.windowNumberAtPoint(mouse, belowWindowWithWindowNumber: 0) == playerWindow.windowNumber
        let isZoomKeyPressed = mouseInside && NSEvent.modifierFlags() & .ControlKeyMask != nil
        
        if isZoomKeyPressed && frameForNonFullscreenMode == nil {
            frameForNonFullscreenMode = playerWindow.frame
            let screen = NSScreen.screens()?.first as! NSScreen
            playerWindow.setFrame(screen.frame, display: true, animate: false)
        }
        else if !isZoomKeyPressed && frameForNonFullscreenMode != nil {
            playerWindow.setFrame(frameForNonFullscreenMode!, display: true, animate: false)
            frameForNonFullscreenMode = nil
        }
    }

    private func loadEventVideo() {
        if let url = event!.appropriateURL {
            
            println("LIVE EVENT URL: \(url)")
            
            if let asset = AVURLAsset(URL: url, options: nil) {
                self.asset = asset
                let keys = ["playable", "tracks"]
                asset.loadValuesAsynchronouslyForKeys(keys) {
                    for key in keys {
                        var error: NSError?
                        let status = asset.statusOfValueForKey(key, error: &error)
                        if status == .Failed {
                            println("[Live Session Playback] Failed to load status for key \(key) \(error)")
                            return
                        }
                    }
                    
                    dispatch_async(dispatch_get_main_queue()) {
                        self.playEventVideo()
                    }
                }
            }
        }
    }
    
    private func playEventVideo() {
        if let playerItem = AVPlayerItem(asset: self.asset) {
            self.item = playerItem
            self.player = AVPlayer(playerItem: self.item)
            self.item.addObserver(self, forKeyPath: "status", options: .Initial | .New, context: nil)
            
            if NSProcessInfo.processInfo().isElCapitan {
                self.playerView.hidden = true
                self.customPlayerView.hidden = false
                self.customPlayerView.player = self.player
            } else {
                self.playerView.player = player
            }
        }
    }
    
    override func observeValueForKeyPath(keyPath: String, ofObject object: AnyObject, change: [NSObject : AnyObject], context: UnsafeMutablePointer<Void>) {
        if keyPath == "status" {
            if item.status == .ReadyToPlay {
                dispatch_async(dispatch_get_main_queue()) {
                    self.progressIndicator.stopAnimation(nil)
                    self.player?.play()
                }
            }
        } else {
            super.observeValueForKeyPath(keyPath, ofObject: object, change: change, context: context)
        }
    }
    
    func toggleFullScreen(sender: AnyObject?) {
        window!.toggleFullScreen(sender)
    }
    
    func showTranscriptWindow(sender: AnyObject?) {
        if session == nil {
            return
        }
        
        if transcriptWC != nil {
            if let window = transcriptWC.window {
                window.orderFront(sender)
            }
            
            return
        }
        
        if let session = session {
            transcriptWC = TranscriptWindowController(session: session)
            transcriptWC.showWindow(sender)
            transcriptWC.jumpToTimeCallback = { [unowned self] time in
                if let player = self.player {
                    player.seekToTime(CMTimeMakeWithSeconds(time, 30))
                }
            }
            transcriptWC.transcriptReadyCallback = { [unowned self] transcript in
                self.setupTranscriptSync(transcript)
            }
        }
    }
    
    var timeObserver: AnyObject?
    
    func setupTimeObserver() {
        if session == nil {
            return
        }
        
        timeObserver = player?.addPeriodicTimeObserverForInterval(CMTimeMakeWithSeconds(5, 1), queue: dispatch_get_main_queue()) { [unowned self] currentTime in
            let progress = Double(CMTimeGetSeconds(currentTime)/CMTimeGetSeconds(self.player!.currentItem.duration))

            self.session!.progress = progress
            self.session!.currentPosition = CMTimeGetSeconds(currentTime)

            if Preferences.SharedPreferences().floatOnTopStyle == .WhilePlaying {
                self.playbackStateObserver?.startObserving()
            }
        }
    }
    
    var boundaryObserver: AnyObject?
    
    func setupTranscriptSync(transcript: WWDCSessionTranscript) {
        if self.transcriptWC == nil {
            return
        }
        
        boundaryObserver = player?.addBoundaryTimeObserverForTimes(transcript.timecodes, queue: dispatch_get_main_queue()) { [unowned self] in
            if self.transcriptWC == nil {
                return
            }
            
            let roundedTimecode = WWDCTranscriptLine.roundedStringFromTimecode(CMTimeGetSeconds(self.player!.currentTime()))
            self.transcriptWC.highlightLineAt(roundedTimecode)
        }
    }
    
    func setupWindowSizing()
    {
        if let asset = player?.currentItem?.asset {
            // get video dimensions and set window aspect ratio
            if let tracks = asset.tracksWithMediaType(AVMediaTypeVideo) as? [AVAssetTrack] {
                if tracks.count > 0 {
                    let track = tracks[0]
                    videoNaturalSize = track.naturalSize
                    playerWindow.aspectRatio = videoNaturalSize
                } else {
                    return
                }
            } else {
                return
            }
        } else {
            return
        }
        
        // get saved scale
        let lastScale = Preferences.SharedPreferences().lastVideoWindowScale
        
        if lastScale != 100.0 {
            // saved scale matters, resize to preference
            sizeWindowTo(lastScale)
        } else {
            // saved scale is default, size to fit screen (default sizing)
            sizeWindowToFill(nil)
        }
    }
    
    // resizes the window so the video fills the entire screen without cropping
    @IBAction func sizeWindowToFill(sender: AnyObject?)
    {
        if (videoNaturalSize == CGSizeZero) {
            return
        }
        
        Preferences.SharedPreferences().lastVideoWindowScale = 100.0
        
        playerWindow.sizeToFitVideoSize(videoNaturalSize, ignoringScreenSize: false, animated: false)
    }
    
    // resizes the window to a fraction of the video's size
    func sizeWindowTo(fraction: CGFloat)
    {
        if (videoNaturalSize == CGSizeZero) {
            return
        }
        
        Preferences.SharedPreferences().lastVideoWindowScale = fraction
        
        let scaledSize = CGSize(width: videoNaturalSize.width*fraction, height: videoNaturalSize.height*fraction)
        playerWindow.sizeToFitVideoSize(scaledSize, ignoringScreenSize: true, animated: true)
    }
    
    @IBAction func sizeWindowToHalfSize(sender: AnyObject?) {
        sizeWindowTo(0.5)
    }
    
    @IBAction func sizeWindowToQuarterSize(sender: AnyObject?) {
        sizeWindowTo(0.25)
    }
    
    @IBAction func changeFloatOnTop(sender: AnyObject?) {
        if let menuItem = sender as? NSMenuItem {
            if let floatOnTopStyle = Preferences.WindowFloatOnTopStyle(rawValue: menuItem.tag) {
                Preferences.SharedPreferences().floatOnTopStyle = floatOnTopStyle
                
                self.updateFloatOnTopWindowState()
                self.updateFloatOnTopMenuState()
                
                if floatOnTopStyle == .WhilePlaying {
                    self.playbackStateObserver?.startObserving()
                }
                else {
                    self.playbackStateObserver?.stopObserving()
                }
            }
        }
    }
    
    func updateFloatOnTopMenuState() {
        if let mainMenu = NSApplication.sharedApplication().mainMenu {
            self.updateFloatOnTopMenuState(inMenu: mainMenu)
        }
    }
    
    func updateFloatOnTopMenuState(inMenu menu: NSMenu) {
        var floatOnTopStyle = Preferences.SharedPreferences().floatOnTopStyle.rawValue
        for subAnyItem in menu.itemArray {
            if let subItem = subAnyItem as? NSMenuItem {
                if subItem.submenu != nil {
                    updateFloatOnTopMenuState(inMenu: subItem.submenu!)
                }
                else if subItem.action == "changeFloatOnTop:" {
                    subItem.state = subItem.tag == floatOnTopStyle ? NSOnState : NSOffState
                }
            }
        }
    }
    
    func updateFloatOnTopWindowState() {
        switch Preferences.SharedPreferences().floatOnTopStyle {
        case .Never:
            self.window?.level = Int(CGWindowLevelForKey(Int32(kCGNormalWindowLevelKey)));
        case .Always:
            self.window?.level = Int(CGWindowLevelForKey(Int32(kCGMainMenuWindowLevelKey)))
        case .WhilePlaying:
            if let player = self.player {
                let isPlaying = player.rate != 0
                self.window?.level = isPlaying ? Int(CGWindowLevelForKey(Int32(kCGMainMenuWindowLevelKey)))
                    : Int(CGWindowLevelForKey(Int32(kCGNormalWindowLevelKey)))
            }
        }
    }
    
    @IBAction func changePlaybackRate(sender: AnyObject?) {
        if let menuItem = sender as? NSMenuItem {
            let rate = Float(menuItem.tag) / 100.0
            selectedPlaybackRate = rate
            if self.player?.rate != 0 {
                self.player?.rate = rate
            }
            
            updatePlaybackRateMenuState()
        }
    }
    
    func updatePlaybackRateMenuState() {
        if let mainMenu = NSApplication.sharedApplication().mainMenu {
            self.updatePlaybackRateMenuState(inMenu: mainMenu)
        }
    }
    
    func updatePlaybackRateMenuState(inMenu menu: NSMenu) {
        for subAnyItem in menu.itemArray {
            if let subItem = subAnyItem as? NSMenuItem {
                if subItem.submenu != nil {
                    updatePlaybackRateMenuState(inMenu: subItem.submenu!)
                }
                else if subItem.action == "changePlaybackRate:" {
                    let rate = Float(subItem.tag) / 100.0
                    subItem.state = rate == selectedPlaybackRate ? NSOnState : NSOffState
                }
            }
        }
    }
    
    @IBAction func jumpTime(sender: AnyObject?) {
        if let menuItem = sender as? NSMenuItem {
            let delta = Double(menuItem.tag)
            jumpTimeWithDelta(seconds: delta)
        }
    }
    
    func jumpTimeWithDelta(seconds delta: Double) {
        if let player = self.player {
            var position = player.currentTime()
            position = CMTimeMakeWithSeconds(CMTimeGetSeconds(position) + delta, position.timescale)
            player.seekToTime(position)
        }
    }
}

private extension NSProcessInfo {
    var isElCapitan: Bool {
        get {
            let v = self.operatingSystemVersion
            return (v.majorVersion == 10 && v.minorVersion >= 11)
        }
    }
}

private extension LiveEvent {
    var appropriateURL: NSURL? {
        get {
            if NSProcessInfo.processInfo().isElCapitan && stream2 != nil {
                return stream2
            } else {
                return stream
            }
        }
    }
}