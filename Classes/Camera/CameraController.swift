//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import AVFoundation
import Foundation
import UIKit
import MobileCoreServices
import Photos

// Media wrapper for media generated from the CameraController
public struct KanvasCameraMedia {
    public let unmodified: URL
    public let output: URL
    public let info: MediaInfo
    public let size: CGSize
    public let archive: URL
    public let type: KanvasCameraMediaType

    init(unmodified: URL,
         output: URL,
         info: MediaInfo,
         size: CGSize,
         archive: URL,
         type: KanvasCameraMediaType) {
        self.unmodified = unmodified
        self.output = output
        self.info = info
        self.size = size
        self.archive = archive
        self.type = type
    }

    init(asset: AVURLAsset, original: URL, info: MediaInfo, archive: URL) {
        self.init(unmodified: original,
             output: asset.url,
             info: info,
             size: asset.videoScreenSize ?? .zero,
             archive: archive,
             type: KanvasCameraMediaType.video
        )
    }

    init(image: UIImage, url: URL, original: URL, info: MediaInfo, archive: URL) {
        self.init(unmodified: original,
             output: url,
             info: info,
             size: image.size,
             archive: archive,
             type: KanvasCameraMediaType.image
        )
    }
}

public enum KanvasCameraMediaType {
    case image
    case video
    case frames
}

fileprivate extension UIImage {
    func save(info: MediaInfo, in directory: URL = FileManager.default.temporaryDirectory) -> URL? {
        do {
            guard let jpgImageData = jpegData(compressionQuality: 1.0) else {
                return nil
            }
            let fileURL = try jpgImageData.save(to: "\(hashValue)", in: directory, ext: "jpg")
            info.write(toImage: fileURL)
            return fileURL
        } catch {
            print("Failed to save to file. \(error)")
            return nil
        }
    }
}

fileprivate extension Data {
    func save(to filename: String, in directory: URL, ext fileExtension: String) throws -> URL {
        let fileURL = directory.appendingPathComponent(filename).appendingPathExtension(fileExtension)
        try write(to: fileURL, options: .atomic)
        return fileURL
    }
}

public enum KanvasExportAction {
    case previewConfirm
    case confirm
    case post
    case save
    case postOptions
    case confirmPostOptions
}

// Error handling
enum CameraControllerError: Swift.Error {
    case exportFailure
    case unknown
}

// Protocol for dismissing CameraController
// or exporting its created media.
public protocol CameraControllerDelegate: class {
    /**
     A function that is called when an image is exported. Can be nil if the export fails
     - parameter media: KanvasCameraMedia - this is the media created in the controller (can be image, video, etc)
     - seealso: enum KanvasCameraMedia
     */
    func didCreateMedia(_ cameraController: CameraController, media: [(KanvasCameraMedia?, Error?)], exportAction: KanvasExportAction)

    /**
     A function that is called when the main camera dismiss button is pressed
     */
    func dismissButtonPressed(_ cameraController: CameraController)

    /// Called when the tag button is pressed in the editor
    func tagButtonPressed()

    /// Called when the editor is dismissed
    func editorDismissed(_ cameraController: CameraController)
    
    /// Called after the welcome tooltip is dismissed
    func didDismissWelcomeTooltip()
    
    /// Called to ask if welcome tooltip should be shown
    ///
    /// - Returns: Bool for tooltip
    func cameraShouldShowWelcomeTooltip() -> Bool
    
    /// Called after the color selector tooltip is dismissed
    func didDismissColorSelectorTooltip()
    
    /// Called to ask if color selector tooltip should be shown
    ///
    /// - Returns: Bool for tooltip
    func editorShouldShowColorSelectorTooltip() -> Bool
    
    /// Called after the stroke animation has ended
    func didEndStrokeSelectorAnimation()
    
    /// Called to ask if stroke selector animation should be shown
    ///
    /// - Returns: Bool for animation
    func editorShouldShowStrokeSelectorAnimation() -> Bool
    
    /// Called when a drag interaction starts
    func didBeginDragInteraction()
    
    /// Called when a drag interaction ends
    func didEndDragInteraction()

    func openAppSettings(completion: ((Bool) -> ())?)
}

class Archive: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool = true

    let image: UIImage?
    let video: URL?
    let data: Data?

    init(image: UIImage, data: Data?) {
        self.image = image
        self.data = data
        self.video = nil
    }

    init(video: URL, data: Data?) {
        self.video = video
        self.data = data
        self.image = nil
    }

    func encode(with coder: NSCoder) {
        coder.encode(image, forKey: "image")
        coder.encode(video?.absoluteString, forKey: "video")
        coder.encode(data?.base64EncodedString(), forKey: "data")
    }

    required init?(coder: NSCoder) {
        image = coder.decodeObject(of: UIImage.self, forKey: "image")
        if let urlString = coder.decodeObject(of: NSString.self, forKey: "video") as? String {
            video = URL(string: urlString)
        } else {
            video = nil
        }
        if let dataString = coder.decodeObject(of: NSString.self, forKey: "data") as? String {
            data = Data(base64Encoded: dataString)
        } else {
            data = nil
        }
    }
}

// A controller that contains and layouts all camera handling views and controllers (mode selector, input, etc).
open class CameraController: UIViewController, MediaClipsEditorDelegate, CameraPreviewControllerDelegate, EditorControllerDelegate, CameraZoomHandlerDelegate, OptionsControllerDelegate, ModeSelectorAndShootControllerDelegate, CameraViewDelegate, CameraInputControllerDelegate, FilterSettingsControllerDelegate, CameraPermissionsViewControllerDelegate, KanvasMediaPickerViewControllerDelegate, MediaPickerThumbnailFetcherDelegate, MultiEditorComposerDelegate {

    enum ArchiveErrors: Error {
        case unknownMedia
    }

    public static func unarchive(_ url: URL) throws -> (CameraSegment, Data?) {
        let data = try Data(contentsOf: url)
        let archive = try NSKeyedUnarchiver.unarchivedObject(ofClass: Archive.self, from: data)
        let segment: CameraSegment
        if let image = archive?.image {
            let info: MediaInfo
            if let imageData = image.jpegData(compressionQuality: 1.0), let mInfo = MediaInfo(fromImageData: imageData) {
                info = mInfo
            } else {
                info = MediaInfo(source: .kanvas_camera)
            }
            let source = CGImageSourceCreateWithData(image.jpegData(compressionQuality: 1.0)! as CFData, nil)
            segment = CameraSegment.image(source!, nil, nil, info)
        } else if let video = archive?.video {
            segment = CameraSegment.video(video, MediaInfo(fromVideoURL: video))
        } else {
            throw ArchiveErrors.unknownMedia
        }
        return (segment, archive?.data)
    }

    public func show(media: [(CameraSegment, Data?)]) {
        showPreview = true
        self.segments = media.map({ return $0.0 })
        self.edits = media.map({ return $0.1 })

        if view.superview != nil {
            showPreviewWithSegments(segments, selected: segments.startIndex, edits: nil, animated: false)
        }
    }

    public func hideLoading() {
        multiEditorViewController?.hideLoading()
    }

    /// The delegate for camera callback methods
    public weak var delegate: CameraControllerDelegate?

    private lazy var options: [[Option<CameraOption>]] = {
        return getOptions(from: self.settings)
    }()
    private lazy var cameraView: CameraView = {
        let view = CameraView(settings: self.settings, numberOfOptionRows: CGFloat(options.count))
        view.delegate = self
        return view
    }()
    private lazy var modeAndShootController: ModeSelectorAndShootController = {
        let controller = ModeSelectorAndShootController(settings: self.settings)
        controller.delegate = self
        return controller
    }()
    private lazy var topOptionsController: OptionsController<CameraController> = {
        let controller = OptionsController<CameraController>(options: options, spacing: CameraConstants.optionHorizontalMargin, settings: self.settings)
        controller.delegate = self
        return controller
    }()
    private lazy var clipsController: MediaClipsEditorViewController = {
        let controller = MediaClipsEditorViewController(showsAddButton: false)
        controller.delegate = self
        return controller
    }()
    
    private var clips = [MediaClip]()

    private lazy var cameraInputController: CameraInputController = {
        let controller = CameraInputController(settings: self.settings, recorderClass: self.recorderClass, segmentsHandler: self.segmentsHandler, delegate: self)
        return controller
    }()
    private lazy var imagePreviewController: ImagePreviewController = {
        let controller = ImagePreviewController()
        return controller
    }()
    private lazy var filterSettingsController: FilterSettingsController = {
        let controller = FilterSettingsController(settings: self.settings)
        controller.delegate = self
        return controller
    }()
    private lazy var cameraPermissionsViewController: CameraPermissionsViewController = {
        let controller = CameraPermissionsViewController(shouldShowMediaPicker: settings.features.mediaPicking, captureDeviceAuthorizer: self.captureDeviceAuthorizer)
        controller.delegate = self
        return controller
    }()
    private lazy var mediaPickerThumbnailFetcher: MediaPickerThumbnailFetcher = {
        let fetcher = MediaPickerThumbnailFetcher()
        fetcher.delegate = self
        return fetcher
    }()
    private lazy var segmentsHandler: SegmentsHandlerType = {
        return segmentsHandlerClass.init()
    }()
        
    private let settings: CameraSettings
    private let analyticsProvider: KanvasCameraAnalyticsProvider?
    private var currentMode: CameraMode
    private var isRecording: Bool
    private var disposables: [NSKeyValueObservation] = []
    private var recorderClass: CameraRecordingProtocol.Type
    private var segmentsHandlerClass: SegmentsHandlerType.Type
    private let stickerProvider: StickerProvider?
    private let cameraZoomHandler: CameraZoomHandler
    private let feedbackGenerator: UINotificationFeedbackGenerator
    private let captureDeviceAuthorizer: CaptureDeviceAuthorizing
    private let quickBlogSelectorCoordinator: KanvasQuickBlogSelectorCoordinating?
    private let tagCollection: UIView?
    private let saveDirectory: URL

    private weak var mediaPlayerController: MediaPlayerController?

    /// Constructs a CameraController that will record from the device camera
    /// and export the result to the device, saving to the phone all in between information
    /// needed to attain the final output.
    ///
    /// - Parameters
    ///   - settings: Settings to configure in which ways should the controller
    /// interact with the user, which options should the controller give the user
    /// and which should be the result of the interaction.
    ///   - stickerProvider: Class that will provide the stickers in the editor.
    ///   - analyticsProvider: An class conforming to KanvasCameraAnalyticsProvider
    public init(settings: CameraSettings,
                stickerProvider: StickerProvider?,
                analyticsProvider: KanvasCameraAnalyticsProvider?,
                quickBlogSelectorCoordinator: KanvasQuickBlogSelectorCoordinating?,
                tagCollection: UIView?,
                saveDirectory: URL = try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)) {
        self.settings = settings
        currentMode = settings.initialMode
        isRecording = false
        self.recorderClass = CameraRecorder.self
        self.segmentsHandlerClass = CameraSegmentHandler.self
        self.captureDeviceAuthorizer = CaptureDeviceAuthorizer()
        self.stickerProvider = stickerProvider
        self.analyticsProvider = analyticsProvider
        self.quickBlogSelectorCoordinator = quickBlogSelectorCoordinator
        self.tagCollection = tagCollection
        self.saveDirectory = saveDirectory
        cameraZoomHandler = CameraZoomHandler(analyticsProvider: analyticsProvider)
        feedbackGenerator = UINotificationFeedbackGenerator()
        super.init(nibName: .none, bundle: .none)
        cameraZoomHandler.delegate = self
    }

    /// Constructs a CameraController that will take care of creating media
    /// as the result of user interaction.
    ///
    /// - Parameters:
    ///   - settings: Settings to configure in which ways should the controller
    /// interact with the user, which options should the controller give the user
    /// and which should be the result of the interaction.
    ///   - recorderClass: Class that will provide a recorder that defines how to record media.
    ///   - segmentsHandlerClass: Class that will provide a segments handler for storing stop
    /// motion segments and constructing final input.
    ///   - captureDeviceAuthorizer: Class responsible for authorizing access to capture devices.
    ///   - stickerProvider: Class that will provide the stickers in the editor.
    ///   - analyticsProvider: A class conforming to KanvasCameraAnalyticsProvider
    private init(settings: CameraSettings,
         recorderClass: CameraRecordingProtocol.Type,
         segmentsHandlerClass: SegmentsHandlerType.Type,
         captureDeviceAuthorizer: CaptureDeviceAuthorizing,
         stickerProvider: StickerProvider?,
         analyticsProvider: KanvasCameraAnalyticsProvider?,
         quickBlogSelectorCoordinator: KanvasQuickBlogSelectorCoordinating?,
         tagCollection: UIView?,
         saveDirectory: URL = try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)) {
        self.settings = settings
        currentMode = settings.initialMode
        isRecording = false
        self.recorderClass = recorderClass
        self.segmentsHandlerClass = segmentsHandlerClass
        self.captureDeviceAuthorizer = captureDeviceAuthorizer
        self.stickerProvider = stickerProvider
        self.analyticsProvider = analyticsProvider
        self.quickBlogSelectorCoordinator = quickBlogSelectorCoordinator
        self.tagCollection = tagCollection
        cameraZoomHandler = CameraZoomHandler(analyticsProvider: analyticsProvider)
        feedbackGenerator = UINotificationFeedbackGenerator()
        self.saveDirectory = saveDirectory
        super.init(nibName: .none, bundle: .none)
        cameraZoomHandler.delegate = self
    }

    @available(*, unavailable, message: "use init(settings:) instead")
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @available(*, unavailable, message: "use init(settings:) instead")
    public override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        fatalError("init(nibName:bundle:) has not been implemented")
    }

    override public var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    override public var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
        return .slide
    }

    override public var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .portrait
    }

    /// Requests permissions for video
    ///
    /// - Parameter completion: boolean on whether access was granted
    public func requestAccess(_ completion: ((_ granted: Bool) -> ())?) {
        captureDeviceAuthorizer.requestAccess(for: AVMediaType.video) { videoGranted in
            performUIUpdate {
                completion?(videoGranted)
            }
        }
    }
    
    /// logs opening the camera
    public func logOpen() {
        analyticsProvider?.logCameraOpen(mode: currentMode)
    }
    
    /// logs closing the camera
    public func logDismiss() {
        analyticsProvider?.logDismiss()
    }

    // MARK: - View Lifecycle

    override public func loadView() {
        view = cameraView
    }

    override public func viewDidLoad() {
        super.viewDidLoad()

        if settings.features.cameraFilters {
            cameraView.addFiltersView(filterSettingsController.view)
        }
        cameraView.addModeView(modeAndShootController.view)
        
        if settings.features.multipleExports == false {
            cameraView.addClipsView(clipsController.view)
        }

        addChild(cameraInputController)
        cameraView.addCameraInputView(cameraInputController.view)
        cameraView.addOptionsView(topOptionsController.view)
        cameraView.addImagePreviewView(imagePreviewController.view)

        addChild(cameraPermissionsViewController)
        cameraView.addPermissionsView(cameraPermissionsViewController.view)

        bindMediaContentAvailable()
    }
    
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard cameraInputController.willCloseSoon == false else {
            return
        }
        if segments.isEmpty == false && showPreview {
            showPreviewWithSegments(segments, selected: segments.startIndex, edits: edits, animated: false)
            showPreview = false
        }
        if delegate?.cameraShouldShowWelcomeTooltip() == true && cameraPermissionsViewController.hasFullAccess() {
            showWelcomeTooltip()
        }
    }

    // MARK: - navigation

    private var segments: [CameraSegment] = []
    private var edits: [Data?]?
    private var showPreview: Bool = false
    
    private func showPreviewWithSegments(_ segments: [CameraSegment], selected: Array<CameraSegment>.Index, edits: [Data?]? = nil, animated: Bool = true) {
        guard view.superview != nil else {
            return
        }
        modeAndShootController.dismissTooltip()
        cameraInputController.stopSession()
//        if presentedViewController != nil && presentedViewController is MultiEditorViewController == false {
//            dismiss(animated: true, completion: nil)
//        }
        let controller = createNextStepViewController(segments, selected: selected, edits: edits)
        self.present(controller, animated: animated)
        mediaPlayerController = controller
        if controller is EditorViewController {
            analyticsProvider?.logEditorOpen()
        }
    }
    
    private func createNextStepViewController(_ segments: [CameraSegment], selected: Array<CameraSegment>.Index, edits: [Data?]?) -> MediaPlayerController {
        let controller: MediaPlayerController
        if settings.features.multipleExports {
            if segments.indices.contains(selected) {
                multiEditorViewController?.addSegment(segments[selected])
            }
            controller = multiEditorViewController ?? createStoryViewController(segments, selected: selected, edits: edits)
            multiEditorViewController = controller as? MultiEditorViewController
        }
        else if settings.features.editor {
            let existing = existingEditor
            controller = existing ?? createEditorViewController(segments, selected: selected)
        }
        else {
            controller = createPreviewViewController(segments)
        }
        controller.modalTransitionStyle = .crossDissolve
        controller.modalPresentationStyle = .fullScreen
        return controller
    }
    
    private func createEditorViewController(_ segments: [CameraSegment], selected: Array<CameraSegment>.Index, views: [View]? = nil, canvas: MovableViewCanvas? = nil, drawing: IgnoreTouchesView? = nil, cache: NSCache<NSString, NSData>? = nil) -> EditorViewController {
        let controller = EditorViewController(settings: settings,
                                              segments: segments,
                                              assetsHandler: segmentsHandler,
                                              exporterClass: MediaExporter.self,
                                              gifEncoderClass: GIFEncoderImageIO.self,
                                              cameraMode: currentMode,
                                              stickerProvider: stickerProvider,
                                              analyticsProvider: analyticsProvider,
                                              quickBlogSelectorCoordinator: quickBlogSelectorCoordinator,
                                              views: views,
                                              canvas: canvas,
                                              drawingView: drawing,
                                              tagCollection: tagCollection,
                                              cache: cache ?? MultiEditorViewController.freshCache())
        controller.delegate = self
        return controller
    }

    private func createStoryViewController(_ segments: [CameraSegment], selected: Int, edits: [Data?]?) -> MultiEditorViewController {
        let controller = MultiEditorViewController(settings: settings,
                                                     segments: segments,
                                                     assetsHandler: segmentsHandler,
                                                     exporterClass: MediaExporter.self,
                                                     gifEncoderClass: GIFEncoderImageIO.self,
                                                     cameraMode: currentMode,
                                                     stickerProvider: stickerProvider,
                                                     analyticsProvider: analyticsProvider,
                                                     quickBlogSelectorCoordinator: quickBlogSelectorCoordinator,
                                                     delegate: self,
                                                     selected: selected,
                                                     edits: edits)
        return controller
    }

    private func createPreviewViewController(_ segments: [CameraSegment]) -> CameraPreviewViewController {
        let controller = CameraPreviewViewController(settings: settings, segments: segments, assetsHandler: segmentsHandler, cameraMode: currentMode)
        controller.delegate = self
        return controller
    }
    
    /// Shows the tooltip below the mode selector
    private func showWelcomeTooltip() {
        modeAndShootController.showTooltip()
    }

    /// Shows a generic alert
    private func showAlert(message: String, buttonMessage: String) {
        let alertController = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        let dismissAction = UIAlertAction(title: buttonMessage, style: .default)
        alertController.addAction(dismissAction)
        present(alertController, animated: true, completion: nil)
    }
    
    private func showDismissTooltip() {
        let alertController = UIAlertController(title: nil, message: NSLocalizedString("Are you sure? If you close this, you'll lose everything you just created.", comment: "Popup message when user discards all their clips"), preferredStyle: .alert)
        let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel alert controller"), style: .cancel)
        let discardAction = UIAlertAction(title: NSLocalizedString("I'm sure", comment: "Confirmation to discard all the clips"), style: .destructive) { [weak self] (UIAlertAction) in
            self?.handleCloseButtonPressed()
        }
        alertController.addAction(cancelAction)
        alertController.addAction(discardAction)
        present(alertController, animated: true, completion: nil)
    }
    
    // MARK: - Media Content Creation

    class func save(data: Data, to filename: String, ext fileExtension: String) throws -> URL {
        let fileURL = try URL(filename: filename, fileExtension: fileExtension, unique: false, removeExisting: true)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func durationStringForAssetAtURL(_ url: URL?) -> String {
        var text = ""
        if let url = url {
            let asset = AVURLAsset(url: url)
            let seconds = CMTimeGetSeconds(asset.duration).rounded()
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.minute, .second]
            formatter.zeroFormattingBehavior = .pad
            if let time = formatter.string(from: seconds) {
                text = time
            }
        }
        return text
    }
    
    private func getLastFrameFrom(_ url: URL) -> CGImageSource? {
        let asset = AVURLAsset(url: url, options: nil)
        let generate = AVAssetImageGenerator(asset: asset)
        generate.appliesPreferredTrackTransform = true
        let lastFrameTime = CMTimeGetSeconds(asset.duration) * 60.0
        let time = CMTimeMake(value: Int64(lastFrameTime), timescale: 2)
        do {
            let cgImage = try generate.copyCGImage(at: time, actualTime: nil)
            return CGImageSourceCreateWithDataProvider(cgImage.dataProvider!, nil)!
        }
        catch {
            return nil
        }
    }

    private func takeGif(numberOfFrames: Int, framesPerSecond: Int) {
        guard !isRecording else { return }
        updatePhotoCaptureState(event: .started)
        AudioServicesPlaySystemSoundWithCompletion(SystemSoundID(1108), nil)
        cameraInputController.takeGif(numberOfFrames: numberOfFrames, framesPerSecond: framesPerSecond, completion: { [weak self] url in
            defer {
                self?.updatePhotoCaptureState(event: .ended)
            }
            guard let strongSelf = self else { return }
            strongSelf.analyticsProvider?.logCapturedMedia(type: strongSelf.currentMode,
                                                           cameraPosition: strongSelf.cameraInputController.currentCameraPosition,
                                                           length: 0,
                                                           ghostFrameEnabled: strongSelf.imagePreviewVisible(),
                                                           filterType: strongSelf.cameraInputController.currentFilterType ?? .off)
            performUIUpdate {
                if let url = url {
                    let segment = CameraSegment.video(url, MediaInfo(source: .kanvas_camera))
                    let segments = [segment]
                    strongSelf.showPreviewWithSegments(segments, selected: segments.startIndex)
                }
            }
        })
    }
    
    private func takePhoto() {
        guard !isRecording else { return }
        updatePhotoCaptureState(event: .started)
        cameraInputController.takePhoto(on: currentMode, completion: { [weak self] image in
            defer {
                self?.updatePhotoCaptureState(event: .ended)
            }
            guard let strongSelf = self else { return }
            strongSelf.analyticsProvider?.logCapturedMedia(type: strongSelf.currentMode,
                                                           cameraPosition: strongSelf.cameraInputController.currentCameraPosition,
                                                           length: 0,
                                                           ghostFrameEnabled: strongSelf.imagePreviewVisible(),
                                                           filterType: strongSelf.cameraInputController.currentFilterType ?? .off)
            let data = image?.jpegData(compressionQuality: 1)
            let source = CGImageSourceCreateWithData(data! as CFData, nil)!
            performUIUpdate {
                let simulatorImage = Device.isRunningInSimulator ? UIImage() : nil
                if let image = image ?? simulatorImage {
                    let clip = MediaClip(representativeFrame: source, overlayText: nil, lastFrame: source)
                    if strongSelf.currentMode.quantity == .single {
                        let segments = [clip].map({ clip in
                            return CameraSegment.image(clip.representativeFrame, nil, nil, MediaInfo(source: .kanvas_camera))
                        })
                        if let lastIndex = segments.indices.last {
                            strongSelf.showPreviewWithSegments(segments, selected: lastIndex)
                        }
                    }
                    else {
                        if strongSelf.settings.features.multipleExports {
                            strongSelf.clips.append(clip)
                        }
                        else {
                            strongSelf.clipsController.addNewClip(MediaClip(representativeFrame: source,
                            overlayText: nil,
                            lastFrame: source))
                        }
                    }
                }
                else {
                    // TODO handle
                }
            }
        })
    }
    
    // MARK : - Mode handling
    private func updateMode(_ mode: CameraMode) {
        if mode != currentMode {
            currentMode = mode
            do {
                try cameraInputController.configureMode(mode)
            } catch {
                // we can ignore this error for now since configuring mode may not succeed for devices without all the modes available (flash, multiple cameras)
            }
        }
    }

    /// Is the image preview (ghost frame) visible?
    private func imagePreviewVisible() -> Bool {
        return accessUISync { [weak self] in
            return (self?.topOptionsController.imagePreviewOptionAvailable() ?? false) &&
                   (self?.imagePreviewController.imagePreviewVisible() ?? false)
        } ?? false
    }
    
    private enum RecordingEvent {
        case started
        case ended
    }
    
    /// This updates the camera view based on the current video recording state
    ///
    /// - Parameter event: The recording event (started or ended)
    private func updateRecordState(event: RecordingEvent) {
        isRecording = event == .started
        cameraView.updateUI(forRecording: isRecording)
        filterSettingsController.updateUI(forRecording: isRecording)
        toggleMediaPicker(visible: !isRecording)
        if isRecording {
            modeAndShootController.hideModeButton()
        }
        else if !isRecording && !clipsController.hasClips && !clips.isEmpty && settings.enabledModes.count > 1 {
            modeAndShootController.showModeButton()
        }
    }
    
    /// This enables the camera view user interaction based on the photo capture
    ///
    /// - Parameter event: The recording event state (started or ended)
    private func updatePhotoCaptureState(event: RecordingEvent) {
        isRecording = event == .started
        performUIUpdate {
            self.cameraView.isUserInteractionEnabled = !self.isRecording
        }
    }
    
    // MARK: - UI
    private func updateUI(forClipsPresent hasClips: Bool) {
        topOptionsController.configureOptions(areThereClips: hasClips)
        clipsController.showViews(hasClips)
        if hasClips || settings.enabledModes.count == 1 {
            modeAndShootController.hideModeButton()
        }
        else {
            modeAndShootController.showModeButton()
        }
    }
    
    /// Updates the fullscreen preview with the last image of the clip collection
    private func updateLastClipPreview() {
        imagePreviewController.setImagePreview(clipsController.getLastFrameFromLastClip())
    }
    
    // MARK: - Private utilities
    
    private func bindMediaContentAvailable() {
        disposables.append(clipsController.observe(\.hasClips) { [weak self] object, _ in
            performUIUpdate {
                self?.updateUI(forClipsPresent: object.hasClips)
            }
        })
        updateUI(forClipsPresent: clipsController.hasClips)
    }
    
    /// Prepares the device for giving haptic feedback
    private func prepareHapticFeedback() {
        feedbackGenerator.prepare()
    }
    
    /// Makes the device give haptic feedback
    private func generateHapticFeedback() {
        feedbackGenerator.notificationOccurred(.success)
    }
    
    // MARK: - CameraViewDelegate

    func closeButtonPressed() {
        modeAndShootController.dismissTooltip()
        // Let's prompt for losing clips if they have clips and it's the "x" button, rather than the ">" button.
        if clipsController.hasClips && !settings.topButtonsSwapped {
            showDismissTooltip()
        } else if clips.isEmpty == false && multiEditorViewController != nil {
            showPreviewWithSegments([], selected: multiEditorViewController?.selected ?? 0)
        }
        else {
            handleCloseButtonPressed()
        }
    }

    func handleCloseButtonPressed() {
        performUIUpdate {
            self.delegate?.dismissButtonPressed(self)
        }
    }

    // MARK: - ModeSelectorAndShootControllerDelegate

    func didPanForZoom(_ mode: CameraMode, _ currentPoint: CGPoint, _ gesture: UILongPressGestureRecognizer) {
        if mode.group == .video {
            cameraZoomHandler.setZoom(point: currentPoint, gesture: gesture)
        }
    }

    func didOpenMode(_ mode: CameraMode, andClosed oldMode: CameraMode?) {
        updateMode(mode)
        toggleMediaPicker(visible: true)
    }

    func didTapForMode(_ mode: CameraMode) {
        switch mode.group {
        case .gif:
            takeGif(numberOfFrames: KanvasCameraTimes.gifTapNumberOfFrames, framesPerSecond: KanvasCameraTimes.gifPreferredFramesPerSecond)
        case .photo, .video:
            takePhoto()
        }
    }

    func didStartPressingForMode(_ mode: CameraMode) {
        switch mode.group {
        case .gif:
            takeGif(numberOfFrames: KanvasCameraTimes.gifHoldNumberOfFrames, framesPerSecond: KanvasCameraTimes.gifPreferredFramesPerSecond)
        case .video:
            prepareHapticFeedback()
            let _ = cameraInputController.startRecording(on: mode)
            performUIUpdate { [weak self] in
                self?.updateRecordState(event: .started)
            }
        case .photo:
            break
        }
    }

    func didEndPressingForMode(_ mode: CameraMode) {
        switch mode.group {
        case .video:
            cameraInputController.endRecording(completion: { [weak self] url in
                guard let strongSelf = self else { return }
                if let videoURL = url {
                    let asset = AVURLAsset(url: videoURL)
                    strongSelf.analyticsProvider?.logCapturedMedia(type: strongSelf.currentMode,
                                                                   cameraPosition: strongSelf.cameraInputController.currentCameraPosition,
                                                                   length: CMTimeGetSeconds(asset.duration),
                                                                   ghostFrameEnabled: strongSelf.imagePreviewVisible(),
                                                                   filterType: strongSelf.cameraInputController.currentFilterType ?? .off)
                }
                performUIUpdate {
                    if let url = url {
                        if mode.quantity == .single {
                            let segments = [CameraSegment.video(url, MediaInfo(source: .kanvas_camera))]
                            strongSelf.showPreviewWithSegments(segments, selected: segments.startIndex)
                        }
                        else if let image = AVURLAsset(url: url).thumbnail() {
                            strongSelf.clipsController.addNewClip(MediaClip(representativeFrame: image,
                                                                            overlayText: strongSelf.durationStringForAssetAtURL(url),
                                                                            lastFrame: strongSelf.getLastFrameFrom(url)!))
                            
                        }
                    }
                    
                    strongSelf.updateRecordState(event: .ended)
                    strongSelf.generateHapticFeedback()
                }
            })
        default: break
        }
    }
    
    func didDropToDelete(_ mode: CameraMode) {
        switch mode.quantity {
        case .multiple:
            clipsController.removeDraggingClip()
        case .single:
            break
        }
    }
    
    func didDismissWelcomeTooltip() {
        delegate?.didDismissWelcomeTooltip()
    }

    func didTapMediaPickerButton(completion: (() -> ())? = nil) {
        let picker = KanvasMediaPickerViewController(settings: settings)
        picker.delegate = self
        present(picker, animated: true) {
            self.modeAndShootController.resetMediaPickerButton()
            completion?()
        }
        analyticsProvider?.logMediaPickerOpen()
    }

    func updateMediaPickerThumbnail(targetSize: CGSize) {
        mediaPickerThumbnailFetcher.thumbnailTargetSize = targetSize
        mediaPickerThumbnailFetcher.updateThumbnail()
    }

    // MARK: - OptionsCollectionControllerDelegate (Top Options)

    func optionSelected(_ item: CameraOption) {
        switch item {
        case .flashOn:
            cameraInputController.setFlashMode(on: true)
            analyticsProvider?.logFlashToggled()
        case .flashOff:
            cameraInputController.setFlashMode(on: false)
            analyticsProvider?.logFlashToggled()
        case .backCamera, .frontCamera:
            cameraInputController.switchCameras()
            analyticsProvider?.logFlipCamera()
            cameraZoomHandler.resetZoom()
        case .imagePreviewOn:
            imagePreviewController.showImagePreview(true)
            analyticsProvider?.logImagePreviewToggled(enabled: true)
        case .imagePreviewOff:
            imagePreviewController.showImagePreview(false)
            analyticsProvider?.logImagePreviewToggled(enabled: false)
        }
    }

    // MARK: - MediaClipsEditorDelegate
    
    func mediaClipWasSelected(at: Int) {
        // No-op, don't need to do anything
    }

    func mediaClipStartedMoving() {
        delegate?.didBeginDragInteraction()
        modeAndShootController.enableShootButtonUserInteraction(true)
        modeAndShootController.enableShootButtonGestureRecognizers(false)
        performUIUpdate { [weak self] in
            self?.cameraView.updateUI(forDraggingClip: true)
            self?.modeAndShootController.closeTrash()
            self?.toggleMediaPicker(visible: false)
            self?.clipsController.hidePreviewButton()
        }
    }

    func mediaClipFinishedMoving() {
        analyticsProvider?.logMovedClip()
        delegate?.didEndDragInteraction()
        let filterSelectorVisible = filterSettingsController.isFilterSelectorVisible()
        modeAndShootController.enableShootButtonUserInteraction(!filterSelectorVisible)
        modeAndShootController.enableShootButtonGestureRecognizers(true)
        performUIUpdate { [weak self] in
            self?.cameraView.updateUI(forDraggingClip: false)
            self?.modeAndShootController.hideTrash()
            self?.toggleMediaPicker(visible: true)
            self?.clipsController.showPreviewButton()
        }
    }

    func mediaClipWasDeleted(at index: Int) {
        cameraInputController.deleteSegment(at: index)
        delegate?.didEndDragInteraction()
        let filterSelectorVisible = filterSettingsController.isFilterSelectorVisible()
        modeAndShootController.enableShootButtonUserInteraction(!filterSelectorVisible)
        modeAndShootController.enableShootButtonGestureRecognizers(true)
        performUIUpdate { [weak self] in
            self?.cameraView.updateUI(forDraggingClip: false)
            self?.modeAndShootController.hideTrash()
            self?.toggleMediaPicker(visible: true)
            self?.clipsController.showPreviewButton()
            self?.updateLastClipPreview()
        }
        analyticsProvider?.logDeleteSegment()
    }

    func mediaClipWasAdded(at index: Int) {
        updateLastClipPreview()
    }

    func mediaClipWasMoved(from originIndex: Int, to destinationIndex: Int) {
        cameraInputController.moveSegment(from: originIndex, to: destinationIndex)
        updateLastClipPreview()
    }
    
    func nextButtonWasPressed() {
        if let lastSegment = cameraInputController.segments().last {
            let segments = [lastSegment]
            showPreviewWithSegments(segments, selected: segments.startIndex)
        }
        analyticsProvider?.logNextTapped()
    }
    
    private var existingEditor: EditorViewController?
    private var multiEditorViewController: MultiEditorViewController?

    func addButtonWasPressed(clips: [MediaClip]) {
        self.clips = clips
        existingEditor = presentedViewController as? EditorViewController
        dismiss(animated: false, completion: nil)
    }

    func editor(segment: CameraSegment, views: [View]?, canvas: MovableViewCanvas?, drawingView: IgnoreTouchesView?, cache: NSCache<NSString, NSData>?) -> EditorViewController {
        let segments = [segment]

        return createEditorViewController(segments, selected: segments.startIndex, views: views, canvas: canvas, drawing: drawingView, cache: cache)
    }
    
    public func addButtonPressed() {
        didOpenMode(.normal, andClosed: nil)
    }

    // MARK: - CameraPreviewControllerDelegate & EditorControllerDelegate & StoryComposerDelegate

    func didFinishExportingVideo(url: URL?) {
        didFinishExportingVideo(url: url, info: MediaInfo(source: .kanvas_camera), archive: Data(), action: .previewConfirm, mediaChanged: true)
    }

    func didFinishExportingImage(image: UIImage?) {
        didFinishExportingImage(image: image, info: MediaInfo(source: .kanvas_camera), archive: Data(), action: .previewConfirm, mediaChanged: true)
    }

    func didFinishExportingFrames(url: URL?) {
        var size: CGSize? = nil
        if let url = url {
            size = GIFDecoderFactory.main().size(of: url)
        }
        didFinishExportingFrames(url: url, size: size, info: MediaInfo(source: .kanvas_camera), archive: Data(), action: .previewConfirm, mediaChanged: true)
    }

    public func didFinishExportingVideo(url: URL?, info: MediaInfo?, archive: Data?, action: KanvasExportAction, mediaChanged: Bool) {
        guard settings.features.multipleExports == false else { return }
        let asset: AVURLAsset?
        if let url = url {
            asset = AVURLAsset(url: url)
        }
        else {
            asset = nil
        }

        let fileName = url?.deletingPathExtension().lastPathComponent ?? UUID().uuidString

        if let asset = asset, let info = info, let archiveURL = try! archive?.save(to: fileName, in: saveDirectory, ext: "") {
            let media = KanvasCameraMedia(asset: asset, original: url!, info: info, archive: archiveURL)
            logMediaCreation(action: action, clipsCount: cameraInputController.segments().count, length: CMTimeGetSeconds(asset.duration))
            performUIUpdate { [weak self] in
                if let self = self {
                    self.handleCloseSoon(action: action)
                    self.delegate?.didCreateMedia(self, media: [(media, nil)], exportAction: action)
                }
            }
        }
        else {
            performUIUpdate { [weak self] in
                if let self = self {
                    self.handleCloseSoon(action: action)
                    self.delegate?.didCreateMedia(self, media: [(nil, CameraControllerError.exportFailure)], exportAction: action)
                }
            }
        }
    }

    public func didFinishExportingImage(image: UIImage?, info: MediaInfo?, archive: Data?, action: KanvasExportAction, mediaChanged: Bool) {
        guard settings.features.multipleExports == false else { return }
        if let image = image, let info = info, let url = image.save(info: info), let archiveURL = try! archive?.save(to: UUID().uuidString, in: saveDirectory, ext: "") {
            let media = KanvasCameraMedia(image: image, url: url, original: url, info: info, archive: archiveURL)
            logMediaCreation(action: action, clipsCount: 1, length: 0)
            performUIUpdate { [weak self] in
                if let self = self {
                    self.handleCloseSoon(action: action)
                    self.delegate?.didCreateMedia(self, media: [(media, nil)], exportAction: action)
                }
            }
        }
        else {
            performUIUpdate { [weak self] in
                if let self = self {
                    self.handleCloseSoon(action: action)
                    self.delegate?.didCreateMedia(self, media: [(nil, CameraControllerError.exportFailure)], exportAction: action)
                }
            }
        }
    }

    public func didFinishExportingFrames(url: URL?, size: CGSize?, info: MediaInfo?, archive: Data?, action: KanvasExportAction, mediaChanged: Bool) {
        guard settings.features.multipleExports == false else { return }
        guard let url = url, let info = info, let size = size, size != .zero, let archiveURL = try! archive?.save(to: UUID().uuidString, in: saveDirectory, ext: "") else {
            performUIUpdate {
                self.handleCloseSoon(action: action)
                self.delegate?.didCreateMedia(self, media: [(nil, CameraControllerError.exportFailure)], exportAction: action)
            }
            return
        }
        performUIUpdate {
            self.handleCloseSoon(action: action)
            let media = KanvasCameraMedia(unmodified: url, output: url, info: info, size: size, archive: archiveURL, type: .frames)
            self.delegate?.didCreateMedia(self, media: [( media, nil)], exportAction: action)
        }
    }

    func didFinishExporting(media result: [Result<EditorViewController.ExportResult, Error>]) {
        let items: [(KanvasCameraMedia?, Error?)] = result.map { result in
            switch result {
            case .success(let result):
                switch (result.result, result.original) {
                case (.image(let image), .image(let original)):
                    if let url = image.save(info: result.info), let originalURL = original.save(info: result.info, in: saveDirectory) {
                        print("Original image URL: \(originalURL)")
                        let archiveURL = archive(media: result.original!, archive: result.archive, to: url.deletingPathExtension().lastPathComponent)
                        return (KanvasCameraMedia(image: image, url: url, original: originalURL, info: result.info, archive: archiveURL), nil)
                    }
                case (.video(let url), .video(let original)):
                    let archiveURL = archive(media: result.original!, archive: result.archive, to: url.deletingPathExtension().lastPathComponent)
//                    let originalURL =  saveDirectory.appendingPathComponent(url.lastPathComponent)
                    print("Original video URL: \(original)")
//                    try? FileManager.default.removeItem(at: originalURL)
//                    try! FileManager.default.moveItem(at: original, to: originalURL)
                    let asset = AVURLAsset(url: url)
                    return (KanvasCameraMedia(asset: asset, original: original, info: result.info, archive: archiveURL), nil)
                default:
                    ()
                }
            case .failure(let error):
                return (nil, error)
            }
            return (nil, nil)
        }

        handleCloseSoon(action: .previewConfirm)
        delegate?.didCreateMedia(self, media: items, exportAction: .post)
    }

    private func archive(media: EditorViewController.Media, archive data: Data, to path: String) -> URL {

        let archive: Archive

        switch media {
        case .image(let image):
            archive = Archive(image: image, data: data)
        case .video(let url):
            archive = Archive(video: url, data: data)
        }

        let data = try! NSKeyedArchiver.archivedData(withRootObject: archive, requiringSecureCoding: true)
        let archiveURL = try! data.save(to: path, in: saveDirectory, ext: "")

        return archiveURL
    }
        
    func handleCloseSoon(action: KanvasExportAction) {
        cameraInputController.willCloseSoon = action == .previewConfirm
    }

    func logMediaCreation(action: KanvasExportAction, clipsCount: Int, length: TimeInterval) {
        switch action {
        case .previewConfirm:
            analyticsProvider?.logConfirmedMedia(mode: currentMode, clipsCount: clipsCount, length: length)
        case .confirm, .post, .save, .postOptions, .confirmPostOptions:
            analyticsProvider?.logEditorCreatedMedia(clipsCount: clipsCount, length: length)
        }
    }

    public func dismissButtonPressed() {
        if settings.features.editor {
            analyticsProvider?.logEditorBack()
        }
        else {
            analyticsProvider?.logPreviewDismissed()
        }
        if settings.features.multipleExports && !clips.isEmpty {
            showPreviewWithSegments([], selected: multiEditorViewController?.selected ?? 0)
        } else {
            performUIUpdate { [weak self] in
                self?.dismiss(animated: true)
            }
        }
        delegate?.editorDismissed(self)
    }

    public func tagButtonPressed() {
        delegate?.tagButtonPressed()
    }
    
    public func editorShouldShowColorSelectorTooltip() -> Bool {
        guard let delegate = delegate else { return false }
        return delegate.editorShouldShowColorSelectorTooltip()
    }
    
    public func didDismissColorSelectorTooltip() {
        delegate?.didDismissColorSelectorTooltip()
    }
    
    public func editorShouldShowStrokeSelectorAnimation() -> Bool {
        guard let delegate = delegate else { return false }
        return delegate.editorShouldShowStrokeSelectorAnimation()
    }
    
    public func didEndStrokeSelectorAnimation() {
        delegate?.didEndStrokeSelectorAnimation()
    }
    
    // MARK: CameraZoomHandlerDelegate
    var currentDeviceForZooming: AVCaptureDevice? {
        return cameraInputController.currentDevice
    }
    
    // MARK: CameraInputControllerDelegate
    func cameraInputControllerShouldResetZoom() {
        cameraZoomHandler.resetZoom()
    }
    
    func cameraInputControllerPinched(gesture: UIPinchGestureRecognizer) {
        cameraZoomHandler.setZoom(gesture: gesture)
    }

    func cameraInputControllerHasFullAccess() -> Bool {
        return cameraPermissionsViewController.hasFullAccess()
    }
    
    // MARK: - FilterSettingsControllerDelegate
    
    func didSelectFilter(_ filterItem: FilterItem, animated: Bool) {
        cameraInputController.applyFilter(filterType: filterItem.type)
        if animated {
            analyticsProvider?.logFilterSelected(filterType: filterItem.type)
        }
    }
    
    func didTapSelectedFilter(recognizer: UITapGestureRecognizer) {
        modeAndShootController.tapShootButton(recognizer: recognizer)
    }
    
    func didLongPressSelectedFilter(recognizer: UILongPressGestureRecognizer) {
        modeAndShootController.longPressShootButton(recognizer: recognizer)
    }
    
    func didTapVisibilityButton(visible: Bool) {
        if visible {
            analyticsProvider?.logOpenFiltersSelector()
        }
        modeAndShootController.enableShootButtonUserInteraction(!visible)
        toggleMediaPicker(visible: !visible)
        modeAndShootController.dismissTooltip()
    }

    // MARK: - CameraPermissionsViewControllerDelegate

    func cameraPermissionsChanged(hasFullAccess: Bool) {
        if hasFullAccess {
            cameraInputController.setupCaptureSession()
            toggleMediaPicker(visible: true, animated: false)
        }
    }

    func openAppSettings(completion: ((Bool) -> ())?) {
        delegate?.openAppSettings(completion: completion)
    }

    /// Toggles the media picker
    /// This takes the current camera mode and filter selector visibility into account, as the media picker should
    /// only be shown in Normal mode when the filter selector is hidden.
    ///
    /// - Parameters
    ///   - visible: Whether to make the button visible or not.
    ///   - animated: Whether to animate the transition.
    private func toggleMediaPicker(visible: Bool, animated: Bool = true) {
        if visible {
            if !filterSettingsController.isFilterSelectorVisible() && cameraPermissionsViewController.hasFullAccess() {
                modeAndShootController.showMediaPickerButton(basedOn: currentMode, animated: animated)
            }
            else {
                modeAndShootController.toggleMediaPickerButton(settings.features.cameraFilters == false, animated: animated)
            }
        }
        else {
            modeAndShootController.toggleMediaPickerButton(false, animated: animated)
        }
    }

    // MARK: - KanvasMediaPickerViewControllerDelegate

    func didPick(image: UIImage, url imageURL: URL?) {
        defer {
            analyticsProvider?.logMediaPickerPickedMedia(ofType: .image)
        }
        let mediaInfo: MediaInfo = {
            guard let imageURL = imageURL else { return MediaInfo(source: .media_library) }
            return MediaInfo(fromImage: imageURL) ?? MediaInfo(source: .media_library)
        }()
        if currentMode.quantity == .single {
            performUIUpdate {
                let source = CGImageSourceCreateWithData(image.jpegData(compressionQuality: 1) as! CFData, nil)!
                let segments = [CameraSegment.image(source, nil, nil, mediaInfo)]
                self.showPreviewWithSegments(segments, selected: segments.startIndex)
            }
        }
        else {
            let source = CGImageSourceCreateWithData(image.jpegData(compressionQuality: 1) as! CFData, nil)!
            segmentsHandler.addNewImageSegment(image: source, size: image.size, mediaInfo: mediaInfo) { [weak self] success, segment in
                guard let strongSelf = self else {
                    return
                }
                guard success else {
                    return
                }
                performUIUpdate {
                    strongSelf.clipsController.addNewClip(MediaClip(representativeFrame: source,
                                                                    overlayText: nil,
                                                                    lastFrame: source))
                }
            }
        }
    }

    func didPick(video url: URL) {
        defer {
            analyticsProvider?.logMediaPickerPickedMedia(ofType: .video)
        }
        let mediaInfo = MediaInfo(fromVideoURL: url) ?? MediaInfo(source: .media_library)
        if currentMode.quantity == .single {
            let segments = [CameraSegment.video(url, mediaInfo)]
            self.showPreviewWithSegments(segments, selected: segments.startIndex)
        }
        else {
            segmentsHandler.addNewVideoSegment(url: url, mediaInfo: mediaInfo)
            performUIUpdate {
                if let image = AVURLAsset(url: url).thumbnail() {
                    self.clipsController.addNewClip(MediaClip(representativeFrame: image,
                                                              overlayText: self.durationStringForAssetAtURL(url),
                                                              lastFrame: self.getLastFrameFrom(url)!))
                }
            }
        }
    }

    func didPick(gif url: URL) {
        defer {
            analyticsProvider?.logMediaPickerPickedMedia(ofType: .frames)
        }
        let mediaInfo: MediaInfo = {
            return MediaInfo(fromImage: url) ?? MediaInfo(source: .media_library)
        }()
        GIFDecoderFactory.main().decode(image: url) { frames in
            let segments = frames.map { CameraSegment.image($0.image, nil, $0.interval, mediaInfo) }
            self.showPreviewWithSegments(segments, selected: segments.endIndex)
        }
    }

    func didPick(livePhotoStill: UIImage, pairedVideo: URL) {
        defer {
            analyticsProvider?.logMediaPickerPickedMedia(ofType: .livePhoto)
        }
        let mediaInfo = MediaInfo(source: .media_library)
        let imageData = livePhotoStill.jpegData(compressionQuality: 1)
        let imageSource = CGImageSourceCreateWithData(imageData! as CFData, nil)!
        if currentMode.quantity == .single {
            let segments = [CameraSegment.image(imageSource, pairedVideo, nil, mediaInfo)]
            self.showPreviewWithSegments(segments, selected: segments.startIndex)
        }
        else {
            assertionFailure("No media picking from stitch yet")
        }
    }

    func didCancel() {
        analyticsProvider?.logMediaPickerDismiss()
    }

    func pickingMediaNotAllowed(reason: String) {
        let buttonMessage = NSLocalizedString("Got it", comment: "Got it")
        showAlert(message: reason, buttonMessage: buttonMessage)
    }

    // MARK: - MediaPickerThumbnailFetcherDelegate

    func didUpdateThumbnail(image: UIImage) {
        self.modeAndShootController.setMediaPickerButtonThumbnail(image)
    }

    // MARK: - breakdown
    
    /// This function should be called to stop the camera session and properly breakdown the inputs
    public func cleanup() {
        resetState()
        cameraInputController.cleanup()
        mediaPickerThumbnailFetcher.cleanup()
    }

    public func resetState() {
        mediaPlayerController?.dismiss(animated: true, completion: nil)
        clipsController.removeAllClips()
        cameraInputController.deleteAllSegments()
        multiEditorViewController = nil
        imagePreviewController.setImagePreview(nil)
    }

    // MARK: - Post Options Interaction

    public func onPostOptionsDismissed() {
        mediaPlayerController?.onPostingOptionsDismissed()
    }
}
