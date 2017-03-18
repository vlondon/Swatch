//
//  main.swift
//  Swatch
//
//  Created by Vladimirs Matusevics on 16/03/2017.
//  Copyright © 2017 Vladimirs Matusevics. All rights reserved.
//

import Foundation
import Cocoa
import IOKit.hid

struct Project {
    
    enum ProjectType: String {
        case workspace = "xcworkspace"
        case proj = "xcodeproj"
    }
    
    var path: String
    var name: String
    var type: ProjectType
    var targetName: String
    var testsBundleName: String
    var testsSuffix: String
    var destinationProperty: String
    
    init(path: String,
         name: String,
         type: ProjectType = .workspace,
         targetName: String = "",
         testsBundleName: String = "",
         testsSuffix: String = "Tests",
         destinationProperty: String = "platform=iOS Simulator,name=iPhone 7,OS=10.2") {
        
        self.path = "/Users/\(Project.ownerUsername())\(path)"
        self.name = name
        self.type = type
        self.targetName = targetName.isEmpty ? name : targetName
        self.testsBundleName = testsBundleName.isEmpty ? "\(name)Tests" : testsBundleName
        self.testsSuffix = testsSuffix
        self.destinationProperty = destinationProperty
    }
    
    func fullPath() -> String {
        return "\(self.path)\(self.name)"
    }
    
    func fullName() -> String {
        return "\(self.name).\(self.type.rawValue)"
    }
    
    // Returns username of OSX machine
    static func ownerUsername() -> String {
        //! running on simulator so just grab the name from home dir /Users/{username}/Library...
        let usernameComponents = NSHomeDirectory().components(separatedBy: "/")
        guard usernameComponents.count > 2 else { fatalError() }
        return usernameComponents[2]
    }
}

enum App: String {
    case xcode = "Xcode"
    case appcode = "AppCode"
    case unknown
}

@discardableResult
func shell(path: String, args: [String]) -> Int32 {
    
    let task = Process()
    task.launchPath = "/usr/bin/env"
    task.currentDirectoryPath = path
    task.arguments = args
    
    let pipe = Pipe()
    task.standardOutput = pipe
    
    task.launch()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let output = NSString(data: data, encoding: String.Encoding.utf8.rawValue) {
        print(output)
        Process.launchedProcess(launchPath: "/usr/bin/osascript", arguments: ["-e", "display notification \"Finished unit tests..\""])
    }
    
    task.waitUntilExit()
    
    return task.terminationStatus
}

// MARK: KeyLogger

class KeyLogger {
    
    lazy var manager: IOHIDManager = {
        return IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }()
    
    lazy var openHIDManager: IOReturn = {
        return IOHIDManagerOpen(self.manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }()
    
    // Used in multiple matching dictionary
    lazy var deviceList: CFArray = {
        var array = [CFMutableDictionary]()
        array.append(self.createDeviceMatchingDictionary(inUsagePage: kHIDPage_GenericDesktop, inUsage: kHIDUsage_GD_Keyboard))
        array.append(self.createDeviceMatchingDictionary(inUsagePage: kHIDPage_GenericDesktop, inUsage: kHIDUsage_GD_Keypad))
        return array as CFArray
    }()
    
    private let appsToWatch: Set<App> = [.xcode, .appcode]
    
    var activeAppName = App.xcode
    var shiftPressed = false
    var altPressed = false
    var actionPressed = false
    
    let daemon: Daemon!
    let project: Project!
    
    init(with project: Project, daemon: Daemon) {
        self.project = project
        self.daemon = daemon
    }
    
    func start() {
        if (CFGetTypeID(self.manager) != IOHIDManagerGetTypeID()) {
            print("Can't create manager")
            exit(1)
        }
        
        IOHIDManagerSetDeviceMatchingMultiple(self.manager, self.deviceList)
        
        let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        // App switching notification
        NSWorkspace.shared()
            .notificationCenter
            .addObserver(self,
                         selector: #selector(self.activatedApp),
                         name: NSNotification.Name.NSWorkspaceDidActivateApplication,
                         object: nil)
        
        // Input value Call Backs
        IOHIDManagerRegisterInputValueCallback(self.manager, self.handleIOHIDInputValueCallback, observer)
        
        // Open HID Manager
        if self.openHIDManager != kIOReturnSuccess {
            print("Can't open HID!")
        }
        
        // Scheduling the loop
        self.scheduleHIDLoop()
        
        // Running in Loop
        RunLoop.current.run()
    }
    
    dynamic func activatedApp(notification: NSNotification) {
        if let info = notification.userInfo,
            let app = info[NSWorkspaceApplicationKey] as? NSRunningApplication,
            let name = app.localizedName {
            self.activeAppName = App.init(rawValue: name) ?? .unknown
        }
    }
    
    // For Keyboard and Keypad
    func createDeviceMatchingDictionary(inUsagePage: Int, inUsage: Int ) -> CFMutableDictionary {
        // note: the usage is only valid if the usage page is also defined
        return [kIOHIDDeviceUsagePageKey: inUsagePage, kIOHIDDeviceUsageKey: inUsage] as! CFMutableDictionary
    }
    
    func scheduleHIDLoop() {
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }
    
    let handleIOHIDInputValueCallback: IOHIDValueCallback = { context, result, sender, device in
        let `self` = Unmanaged<KeyLogger>.fromOpaque(context!).takeUnretainedValue()
        let elem = IOHIDValueGetElement(device)
        
        // check keys only for specific Apps
        if case .unknown = self.activeAppName { return }
        
        // fn
        if (IOHIDElementGetUsagePage(elem) != 0x07) { return }
        
        let scancode = IOHIDElementGetUsage(elem)
        if (scancode < 4 || scancode > 231) { return }
        
        let pressed = IOHIDValueGetIntegerValue(device) == 1
        
        if scancode == 225 { // left shift
            self.shiftPressed = pressed
        }
        
        if scancode == 227 { // left cmd
            self.altPressed = pressed
        }
        
        if scancode == 8 { // "e"
            self.actionPressed = pressed
        }
        
        if self.shiftPressed && self.altPressed && self.actionPressed {
            var args: [String] = ["xcodebuild", "test", "-workspace", self.project.fullName(), "-scheme", self.project.targetName, "-destination", self.project.destinationProperty]
            
            if !self.daemon.filesChanged.isEmpty {
                self.daemon.filesChanged.forEach() { filePath in
                    var fileName = NSURL(fileURLWithPath: filePath).lastPathComponent!
                    fileName = fileName.replacingOccurrences(of: ".swift", with: "")
                    args.append("-only-testing:\(self.project.testsBundleName)/\(fileName)\(self.project.testsSuffix)")
                }
                self.daemon.resetFilesChanged()
                
                Process.launchedProcess(launchPath: "/usr/bin/osascript", arguments: ["-e", "display notification \"Running unit tests..\""])
                print("\n\nRunning unit tests..\nargs: \(args)\n\n")
                shell(path: self.project.fullPath(), args: args)
            } else {
                print("No reason of running tests, no files changed")
            }
        }
    }
}

// MARK: FileWatcher

public enum FileWatcher {
    
    // Errors that can be thrown from `FileWatcherProtocol`
    public enum Error: Swift.Error {
        // Trying to perform operation on watcher that requires started state
        case notStarted
        // Trying to start watcher that's already running
        case alreadyStarted
        // Trying to stop watcher that's already stopped
        case alreadyStopped
        // Failed to start the watcher, `reason` will contain more information why
        case failedToStart(reason: String)
    }
    
    // Status of refresh result
    public enum RefreshResult {
        // Watched file didn't change since last update.
        case noChanges
        case updated(data: Data)
    }
    
    // Closure used for File watcher updates
    public typealias UpdateClosure = (RefreshResult) -> Void
}

public protocol FileWatcherProtocol {
    func start(closure: @escaping FileWatcher.UpdateClosure) throws
    func stop() throws
}

public final class FileWatcherLocal: FileWatcherProtocol {
    private typealias CancelBlock = () -> Void
    
    private enum State {
        case Started(source: DispatchSourceFileSystemObject, fileHandle: CInt, callback: FileWatcher.UpdateClosure, cancel: CancelBlock)
        case Stopped
    }
    
    private let path: String
    private let refreshInterval: TimeInterval
    private let queue: DispatchQueue
    
    private var state: State = .Stopped
    private var isProcessing: Bool = false
    private var cancelReload: CancelBlock?
    private var previousContent: Data?
    
    /**
     Initializes watcher to specified path.
     
     - parameter path:     Path of file to observe.
     - parameter refreshInterval: Refresh interval to use for updates.
     - parameter queue:    Queue to use for firing `onChange` callback.
     
     - note: By default it throttles to 60 FPS, some editors can generate stupid multiple saves that mess with file system e.g. Sublime with AutoSave plugin is a mess and generates different file sizes, this will limit wasted time trying to load faster than 60 FPS, and no one should even notice it's throttled.
     */
    public init(path: String, refreshInterval: TimeInterval = 1/60, queue: DispatchQueue = DispatchQueue.main) {
        self.path = path
        self.refreshInterval = refreshInterval
        self.queue = queue
    }
    
    public func start(closure: @escaping FileWatcher.UpdateClosure) throws {
        guard case .Stopped = state else { throw FileWatcher.Error.alreadyStarted }
        try startObserving(closure)
    }
    
    public func stop() throws {
        guard case let .Started(_, _, _, cancel) = state else { throw FileWatcher.Error.alreadyStopped }
        cancelReload?()
        cancelReload = nil
        cancel()
        
        isProcessing = false
        state = .Stopped
    }
    
    deinit {
        if case .Started = state { _ = try? stop() }
    }
    
    private func startObserving(_ closure: @escaping FileWatcher.UpdateClosure) throws {
        let handle = open(path, O_EVTONLY)
        
        if handle == -1 { throw FileWatcher.Error.failedToStart(reason: "Failed to open file") }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle,
            eventMask: [.delete, .write, .extend, .attrib, .link, .rename, .revoke],
            queue: queue
        )
        
        let cancelBlock = {
            source.cancel()
        }
        
        source.setEventHandler {
            let flags = source.data
            
            if flags.contains(.delete) || flags.contains(.rename) {
                _ = try? self.stop()
                _ = try? self.startObserving(closure)
                return
            }
            
            self.needsToReload()
        }
        
        source.setCancelHandler {
            close(handle)
        }
        
        source.resume()
        
        state = .Started(source: source, fileHandle: handle, callback: closure, cancel: cancelBlock)
        refresh()
    }
    
    private func needsToReload() {
        guard case .Started = state else { return }
        
        cancelReload?()
        cancelReload = throttle(after: refreshInterval) { self.refresh() }
    }
    
    // Force refresh, can only be used if the watcher was started and it's not processing.
    public func refresh() {
        guard case let .Started(_, _, closure, _) = state, isProcessing == false else { return }
        isProcessing = true
        
        let url = URL(fileURLWithPath: path)
        guard let content = try? Data(contentsOf: url, options: .uncached) else {
            isProcessing = false
            return
        }
        
        if content != previousContent {
            if previousContent != nil {
                queue.async {
                    closure(.updated(data: content))
                }
            }
            previousContent = content
        } else {
            queue.async {
                closure(.noChanges)
            }
        }
        
        isProcessing = false
        cancelReload = nil
    }
    
    private func throttle(after: Double, action: @escaping () -> Void) -> CancelBlock {
        var isCancelled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            if !isCancelled {
                action()
            }
        }
        
        return {
            isCancelled = true
        }
    }
    
}

class Daemon {
    
    var filesChanged: Set<String> = []
    
    var project: Project
    
    init(with project: Project) {
        self.project = project
        
        self.setup()
    }
    
    func resetFilesChanged() {
        self.filesChanged = []
    }
    
    func addWatcher(forFileAtPath path: String) {
        let fileWatcher = FileWatcherLocal(path: path)
        try! fileWatcher.start() { result in
            switch result {
            case .noChanges:
                break
            case .updated(_):
                self.filesChanged.insert(path)
                print("\nself.filesChanged: \(self.filesChanged)")
            }
        }
    }
    
    func setup() {
        let path = "\(self.project.fullPath())/\(self.project.targetName)/"
        print(path)
        
        let enumerator = FileManager.default.enumerator(atPath: path)
        
        while let filePath = enumerator?.nextObject() as? String {
            if filePath.hasSuffix("swift") {
                print("Watching \"\(filePath)\"")
                self.addWatcher(forFileAtPath: "\(path)\(filePath)")
            }
        }
        
        return
    }
    
}

/**
 Initialize your project here
 
 - note: Example:
 If you have project located at "/Users/{username}/dev/ios/ProjectName
 init it like this: Project(path: "/dev/ios/", name: "ProjectName")
 */

let project = Project(path: "/dev/ios/", name: "Workouts")

let daemon = Daemon(with: project)
let keylogger = KeyLogger(with: project, daemon: daemon)

keylogger.start()
