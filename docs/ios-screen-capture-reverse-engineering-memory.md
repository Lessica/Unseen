# iOS Screenshot / Screen Recording Reverse Engineering Memory

## Scope

This file preserves the key clues and conclusions from the reverse-engineering session for:

- `UIApplicationUserDidTakeScreenshotNotification`
- `UIScreenCapturedDidChangeNotification`
- `-[UIScreen isCaptured]`
- Native iOS system screen recording / Replay clone path

The screenshot path was already accepted as complete. The important remaining distinction was that native iOS screen recording must be traced past generic QuartzCore clone/mirror and into the Replay/System Recording path.

## User constraints and corrections

- “source” means the system-side root where screenshot / recording / capture is initiated, not the UIKit app endpoint.
- Screenshot tracing is done: “截屏部分已经可以了。”
- Do not stop at generic `clone` / `mirror`:
  - Prior problem: only reached `CAWindowServerDisplay addClone:` / clone mirror, not actual iOS recording.
- DSC is not fully loaded by default:
  - Need to explicitly load relevant images, e.g. ReplayKit, when using a dyld shared cache IDB.
- System recording does not necessarily have to go through ReplayKit, so ReplayKit had to be treated as a candidate and verified against daemon/service behavior.
- Do not broadly search the user's directories for this task unless explicitly authorized.
  - User provided exact daemon path: `/Users/82flex/Desktop/dyld/replayd`.

## Important databases / binaries

### Correct dyld shared cache

Path:

```text
/Users/82flex/Desktop/dyld/dyld_shared_cache_arm64e.i64
```

Used for:

- QuartzCore
- UIKit
- BackBoardServices
- ReplayKit, after explicitly loading image

ReplayKit image loaded into DSC:

```text
/System/Library/Frameworks/ReplayKit.framework/ReplayKit
```

### Replay daemon

Path:

```text
/Users/82flex/Desktop/dyld/replayd
/Users/82flex/Desktop/dyld/replayd.i64
```

This became the key binary proving native system recording behavior.

### Backboard daemon

Path:

```text
/Users/82flex/Desktop/dyld/backboardd.i64
```

Used to verify BKS display service server side and replay-clone entitlement/path.

### Wrong database opened earlier

Path that was mistakenly opened earlier:

```text
/Users/82flex/Desktop/LayerPropResearch/com.apple.dyld/dyld_shared_cache_arm64.i64
```

Do not use this for the established chain.

## Final native iOS system recording chain

```text
Control Center / RPScreenRecorder
  -> RPDaemonProxy XPC to com.apple.replayd
  -> replayd RPConnectionManager / RPClient / RPSystemRecordSession
  -> RPCaptureManager
  -> RPScreenCaptureManagerIOS startSession
  -> RPScreenCaptureManagerIOS setCloneMirroringMode:contextIDs:
       systemRecording=true:
         BKSDisplayServicesSetReplayCloneContexts(NSSet<NSNumber>)
         BKSDisplayServicesSetCloneMirroringMode(3)
  -> backboardd replay clone MIG handler
       entitlement: com.apple.backboardd.replayClone
       decoded payload: NSSet<NSNumber>
       stored as BKTVOutController _queue_replayCloneContextIDs
  -> BKTVOutController clone/mirroring request processing
       if prevailing clone mirroring mode == 3:
         options[kCAWindowServerClone_ReplayContexts] = _queue_replayCloneContextIDs
       [mainDisplay addClone:destDisplay options:options]
  -> QuartzCore / CAWindowServer clone handling
  -> CA::WindowServer::Display::update_clones sets cloned flag
  -> CADisplay.isCloned
  -> UIScreen._setCaptured / UIScreenCapturedDidChangeNotification
```

Main conclusion:

```text
Native iOS system recording is mode 3 + replay contexts, not ordinary mirror mode.
```

## ReplayKit / client-side clues in dyld shared cache

### `RPScreenRecorder` system recording entry

Function:

```text
-[RPScreenRecorder startSystemRecordingWithMicrophoneEnabled:handler:]
0x1bf167a50
```

Block:

```text
___70-[RPScreenRecorder startSystemRecordingWithMicrophoneEnabled:handler:]_block_invoke
0x1bf167c5c
```

Observed behavior:

- Enumerates app windows.
- Finds `FBRootWindow`.
- Gets root window layer context ID and window size.
- Calls daemon proxy:

```objc
[RPDaemonProxy daemonProxy]
[proxy startSystemRecordingWithContextID:windowSize:microphoneEnabled:cameraEnabled:withHandler:]
```

Interpretation:

- `RPScreenRecorder` is not the root source.
- It forwards system recording to the Replay daemon with context/window metadata.

### `RPDaemonProxy`

Function:

```text
-[RPDaemonProxy init]
0x1bf173abc
```

Critical behavior:

```objc
[[NSXPCConnection alloc] initWithMachServiceName:@"com.apple.replayd" options:256]
```

Daemon call:

```text
-[RPDaemonProxy startSystemRecordingWithContextID:windowSize:microphoneEnabled:cameraEnabled:withHandler:]
0x1bf175654
```

Interpretation:

- ReplayKit client side forwards to `com.apple.replayd` over XPC.

## replayd clues

### Key imports

`replayd` imports:

```text
__imp__BKSDisplayServicesSetCloneMirroringMode
__imp__BKSDisplayServicesSetReplayCloneContexts
_OBJC_CLASS_$_FigScreenCaptureController
_OBJC_CLASS_$_CCSControlCenterService
_OBJC_CLASS_$_CCSModulePresentationOptions
```

These imports are strong evidence that `replayd` is not just a UI/client helper; it directly drives BackBoard display services and screen frame capture.

### Important strings

```text
@( # )PROGRAM:replayd  PROJECT:ReplayKit-1
com.apple.replayd
com.apple.replaykit.controlcenter.screencapture
ReplayKit RPSystemBroadcastPicker openControlCenterSystemRecordingView
com.apple.replayd.screen-capture
com.apple.ReplayKit
com.apple.backboardd.replayClone
```

Control Center module identifier:

```text
com.apple.replaykit.controlcenter.screencapture
```

### replayd call chain

Functions:

```text
-[RPRecordingManager startSystemRecordingWithContextID:windowSize:microphoneEnabled:cameraEnabled:withHandler:]
0x1000141f4

-[RPConnectionManager startSystemRecordingWithContextID:windowSize:microphoneEnabled:cameraEnabled:withHandler:]
0x10002471c

-[RPClient startSystemRecordingSessionWithContextID:windowSize:microphoneEnabaled:cameraEnabled:withHandler:]
0x100030188

-[RPSystemRecordSession startSystemRecordingWithMicrophoneEnabled:cameraEnabled:contextID:windowSize:handler:]
0x100039fdc

-[RPCaptureManager startCaptureForDelegate:forProcessID:shouldStartMicrophoneCapture:windowSize:systemRecording:contextIDs:didStartHandler:]
0x1000433ec

-[RPCaptureManager startCaptureManagersForProcessID:windowSize:systemRecording:contextIDs:dispatchGroup:]
0x100043968

-[RPScreenCaptureManagerIOS startSessionWithPID:windowSize:systemRecording:contextIDs:outputHandler:didStartHandler:]
0x100017eec
```

### Critical replayd function: `setCloneMirroringMode:contextIDs:`

Function:

```text
-[RPScreenCaptureManagerIOS setCloneMirroringMode:contextIDs:]
0x100017cb0
```

Disassembly-proven behavior:

```asm
; if systemRecording / replay mode is false:
MOV W0, #1
BL _BKSDisplayServicesSetCloneMirroringMode

; if systemRecording / replay mode is true:
; create NSMutableSet
; enumerate contextIDs
; convert each string using RPStringUtility numberFromString:
; add NSNumber to set
MOV X0, X20
BL _BKSDisplayServicesSetReplayCloneContexts
MOV W0, #3
BL _BKSDisplayServicesSetCloneMirroringMode
```

Meaning:

```text
systemRecording == false:
  BKSDisplayServicesSetCloneMirroringMode(1)
  ordinary mirror path

systemRecording == true:
  BKSDisplayServicesSetReplayCloneContexts(NSSet<NSNumber>)
  BKSDisplayServicesSetCloneMirroringMode(3)
  native system recording / replay clone path
```

This is the key distinction between generic mirror and native iOS system recording.

### Critical replayd function: `startSession...`

Function:

```text
-[RPScreenCaptureManagerIOS startSessionWithPID:windowSize:systemRecording:contextIDs:outputHandler:didStartHandler:]
0x100017eec
```

Important behavior:

```objc
self->super._didStartScreenCaptureHandler = objc_retainBlock(didStartHandler);
self->super._screenCaptureDidStart = 0;

-[RPScreenCaptureManagerIOS setCloneMirroringMode:contextIDs:](
    self,
    "setCloneMirroringMode:contextIDs:",
    systemRecording,
    contextIDs
);

if (!self->_screenCaptureController) {
    CMTimeMake(&interval, 1, 60);
    self->_screenCaptureController =
        [FigScreenCaptureController screenCaptureControllerWithSize:windowSize
                                           minIntervalBetweenFrames:&interval];
}

[self->_screenCaptureController setDelegate:self];
self->super._screenCaptureOutputHandler = objc_retainBlock(outputHandler);
[self->_screenCaptureController startCapture];
```

Meaning:

- BKS replay clone setup occurs before `FigScreenCaptureController startCapture`.
- `FigScreenCaptureController` handles actual frame/sample capture.
- BKS/BackBoard handles replay display plumbing and the path that affects `UIScreen.isCaptured`.

### replayd stop path

Function:

```text
-[RPScreenCaptureManagerIOS stop]
0x100018128
```

Important behavior:

```objc
if (self->_screenCaptureController) {
    [self->_screenCaptureController stopCapture];
    [self->_screenCaptureController setDelegate:nil];
    self->_screenCaptureController = nil;
}

BKSDisplayServicesSetCloneMirroringMode(0);

self->super._screenCaptureOutputHandler = nil;
self->super._didStartScreenCaptureHandler = nil;
self->super._screenCaptureDidStart = 0;
```

Meaning:

- Stop clears clone mode with mode 0.

### Control Center recording UI path in replayd

Functions:

```text
-[RPRecordingManager openControlCenterSystemRecordingView]
0x100016f00

-[RPConnectionManager openControlCenterSystemRecordingView]
0x100027ff8
```

Block behavior:

```objc
[CCSControlCenterService sharedInstance]
[CCSModulePresentationOptions defaultOptions]
[service presentModuleWithIdentifier:@"com.apple.replaykit.controlcenter.screencapture"
                             options:options
                   completionHandler:...]
```

Meaning:

- `replayd` can present/open the Control Center system recording module.
- This links `replayd` to the native system recording UI path, not only app ReplayKit API usage.

## backboardd replay-clone service-side clues

### Important strings

```text
_queue_replayCloneContextIDs
com.apple.backboardd.replayClone
setReplayCloneContextIDs:%{public}@
com.apple.backboardd.virtualDisplay
```

Important distinction:

```text
com.apple.backboardd.replayClone
  replay context / system recording path

com.apple.backboardd.virtualDisplay
  generic virtual display / mirror path
```

### Key functions

```text
sub_10008F7D4
0x10008f7d4
MIG dispatcher for replay clone context IDs

sub_100022674
0x100022674
Entitlement wrapper for replay clone context setting

sub_1000226E8
0x1000226e8
Decodes incoming context ID bytes, validates NSSet<NSNumber>, dispatches update

sub_10004A6B4
0x10004a6b4
Stores replay context IDs into BKTVOutController queue state

sub_100048284
Builds CAWindowServerDisplay addClone:options: dictionary and conditionally includes kCAWindowServerClone_ReplayContexts
```

### backboardd MIG receive side

Function:

```text
sub_10008F7D4
0x10008f7d4
```

Important behavior:

```c
if ((*(_DWORD *)a1 & 0x80000000) == 0 ||
    *(_DWORD *)(a1 + 24) != 1 ||
    *(_DWORD *)(a1 + 4) != 56) {
    error = -304;
} else if (*(_BYTE *)(a1 + 39) != 1 ||
           (length = *(_DWORD *)(a1 + 40), length != *(_DWORD *)(a1 + 52))) {
    error = -300;
} else if (!*(_DWORD *)(a1 + 56)) {
    if (*(_DWORD *)(a1 + 60) > 0x1F) {
        bytes = *(_QWORD *)(a1 + 28);
        audit = *(a1 + 76 .. 107);
        *(_DWORD *)(a2 + 32) = sub_100022674(bytes, length, audit);
        mig_deallocate(*(_QWORD *)(a1 + 28), *(unsigned int *)(a1 + 40));
    } else {
        error = -309;
    }
}
```

Meaning:

- This is the replay clone context OOL data receive side.
- It passes bytes/length/audit token to `sub_100022674`.

### replay-clone entitlement wrapper

Function:

```text
sub_100022674
0x100022674
```

Important behavior:

```c
__int64 sub_100022674(__int64 bytes, int length, __int64 audit)
{
    block = { ..., sub_1000226E8, ..., bytes, length };

    if (!(unsigned int)sub_100013970(CFSTR("com.apple.backboardd.replayClone"), audit))
        return 5;

    sub_1000226E8((__int64)&block);
    return 0;
}
```

Meaning:

- Setting replay clone contexts requires entitlement:

```text
com.apple.backboardd.replayClone
```

- This is not the generic virtual display entitlement.

### replay context payload decode

Function:

```text
sub_1000226E8
0x1000226e8
```

Important behavior:

```objc
NSData *data = [[NSData alloc] initWithBytesNoCopy:bytes
                                            length:length
                                      freeWhenDone:NO];

NSSet *allowed = [NSSet setWithObject:[NSNumber class]];
NSSet *set = [NSSet bs_secureDecodedFromData:data
                       withAdditionalClasses:allowed];

if (set) {
    valid = true;
    [set bs_each:block_that_checks_each_object_is_NSNumber];

    if (valid) {
        controller = [BKTVOutController singleton];
        dispatch_async(controller->_queue, ^{
            sub_10004A6B4(controller, set);
        });
    } else {
        log "Decoded contextIDs contains malformatted elements";
    }
} else {
    log "Error unarchiving contextIDs";
}
```

Meaning:

- `BKSDisplayServicesSetReplayCloneContexts` payload is secure-decoded as `NSSet<NSNumber>`.
- Each element must be an `NSNumber`.

### Store replay context IDs

Function:

```text
sub_10004A6B4
0x10004a6b4
```

Important behavior:

```c
if (*(controller + 16) != newSet) {
    log "setReplayCloneContextIDs:%{public}@";
    copy = [newSet copy];
    old = *(controller + 16);
    *(controller + 16) = copy;
    objc_release(old);
}
```

Meaning:

- `BKTVOutController + 0x10` is `_queue_replayCloneContextIDs`.
- It stores the set supplied by replayd.

### Backboardd clone options path

Function:

```text
sub_100048284
```

Important behavior:

```objc
if (mode == 3) {
    replayContextIDs = *(controller + 16); // _queue_replayCloneContextIDs
    if (replayContextIDs) {
        [options setObject:replayContextIDs
                    forKey:kCAWindowServerClone_ReplayContexts];
    }
}

[mainDisplay addClone:destDisplay options:options];
```

Meaning:

- Only clone mirroring mode 3 injects replay context IDs into CAWindowServer clone options.
- This is the service-side distinction between ordinary clone/mirror and native system recording replay clone.

## QuartzCore / CoreAnimation capture-state chain

Already established before replayd/backboardd completion:

```text
CAWindowServerDisplay addClone:options:
  -> CA::WindowServer::Server::add_clone(...)
  -> if replayContexts present, CA::WindowServer::Server::set_replay_context_ids(...)
  -> CA::WindowServer::Display::update_clones
  -> server Display + 0x1C0 bit2 cloned flag
  -> RenderServer GetDisplayInfo MIG 0x9D28
  -> CA::Display::Display::update
  -> CADisplay local impl cloned bit
  -> CADisplay.isCloned
  -> UIKit UIScreen._captured
  -> UIScreenCapturedDidChangeNotification
```

Important point:

- `UIScreen.isCaptured` does not discover recording directly.
- It reads UIKit state derived from `CADisplay.isCloned` / CoreAnimation display info.
- The system recording path is what causes CAWindowServer display clone state to become true through mode 3 replay clone.

## Screenshot path: `UIApplicationUserDidTakeScreenshotNotification`

Screenshot tracing was accepted as complete by the user: “截屏部分已经可以了。” The key point is that the app process is not the origin. UIKit posts the notification only after receiving a FrontBoard/UIKit action for an already-performed system screenshot.

Final chain:

```text
Hardware button event
  -> SpringBoard SBCombinationHardwareButton / SBPressGestureRecognizer
  -> -[SBCombinationHardwareButton screenshotGesture:]
  -> -[SBCombinationHardwareButtonActions performTakeScreenshotAction]
  -> -[SpringBoard takeScreenshot]
  -> -[SpringBoard _takeScreenshotAndEdit:]
  -> -[SpringBoard _takeScreenshotWithOptionsCollection:presentationOptions:]
  -> ScreenshotServices / SSScreenCapturer performs actual capture
  -> FrontBoard/FBS dispatches UIDidTakeScreenshotAction to target app scene
  -> app process UIKit receives action
  -> -[UIApplication _handleScreenshot]
  -> NSNotificationCenter posts UIApplicationUserDidTakeScreenshotNotification
```

Important distinction:

```text
UIApplicationUserDidTakeScreenshotNotification
  is an app-side notification endpoint.

The system-side root observed in DSC/SpringBoard is:
  -[SBCombinationHardwareButton screenshotGesture:]
```

Physical/HID layer note:

- Below SpringBoard, the event comes from backboardd/HID hardware button events.
- The concrete, visible root in the analyzed DSC/SpringBoard layer is the SpringBoard hardware-combination gesture path.

### SpringBoard hardware-combination entry

Key functions:

```text
-[SBCombinationHardwareButton _configureGestureRecognizers]
-[SBCombinationHardwareButton screenshotGesture:]
-[SBCombinationHardwareButtonActions performTakeScreenshotAction]
-[SpringBoard takeScreenshot]
-[SpringBoard _takeScreenshotAndEdit:]
-[SpringBoard _takeScreenshotWithOptionsCollection:presentationOptions:]
```

`-[SBCombinationHardwareButton _configureGestureRecognizers]` behavior:

```text
_screenshotGestureRecognizer target = SBCombinationHardwareButton
_screenshotGestureRecognizer action = screenshotGesture:
registered with SBSystemGestureManager
observed gesture type / priority parameter: 81
```

`-[SBCombinationHardwareButton screenshotGesture:]` behavior:

```objc
if ([gesture state] == 3) {
    [self->_buttonActions performTakeScreenshotAction];
}
```

Meaning:

- The screenshot action is bound to the hardware-button combination gesture recognizer.
- Gesture state 3 is the trigger point that calls into SpringBoard screenshot actions.

`-[SBCombinationHardwareButtonActions performTakeScreenshotAction]` behavior:

```text
checks lock-screen / disabled conditions
if allowed:
  [_SBApp takeScreenshot]
```

Meaning:

- This is the policy gate before invoking SpringBoard’s screenshot operation.

`-[SpringBoard takeScreenshot]` behavior:

```text
jumps to _takeScreenshotAndEdit: with edit = NO
```

Prior note from transcript:

```text
selector address 0x1CA1178A0 resolved as _takeScreenshotAndEdit:
```

`-[SpringBoard _takeScreenshotAndEdit:]` behavior:

```text
creates SSScreenCapturerPresentationOptions
calls _takeScreenshotWithOptionsCollection:presentationOptions:
```

`-[SpringBoard _takeScreenshotWithOptionsCollection:presentationOptions:]` behavior:

```objc
if ([SSScreenCapturer shouldUseScreenCapturerForScreenshots]) {
    [self->_screenCapturer takeScreenshotWithOptionsCollection:optionsCollection
                                           presentationOptions:presentationOptions];
} else {
    // fallback to old screenshot manager path
    self->_screenshotManager ...
}
```

Meaning:

- Modern path uses ScreenshotServices `SSScreenCapturer`.
- There is an older fallback path through SpringBoard screenshot manager.

### ScreenshotServices actual capture path

Important functions/classes:

```text
SSScreenCapturer
SSSnapshotter
SSScreenSnapshotter
SSMainScreenSnapshotter
SSOtherScreenSnapshotter
```

Actual capture chain:

```text
-[SSScreenCapturer _takeScreenshotWithOptionsCollection:presentationOptions:appleInternalOptions:]
  -> self->_snapshotter captureAvailableSnapshotsWithOptionsCollection:

-[SSSnapshotter captureAvailableSnapshotsWithOptionsCollection:]
  -> enumerate available screens
  -> _captureScreen:withScreenshotOptions:

-[SSSnapshotter _captureScreen:withScreenshotOptions:]
  -> create SSScreenSnapshotter
  -> [snapshotter takeScreenshot]
```

Main screen capture:

```text
-[SSMainScreenSnapshotter takeScreenshot]
  -> __UIRenderDisplay(...)
```

Other/external screen capture:

```text
-[SSOtherScreenSnapshotter takeScreenshot]
  -> +[UIWindow _displayIOSurface:]
  -> __UICreateCGImageFromIOSurfaceWithOptions(...)
```

Meaning:

- ScreenshotServices is where the system screenshot image is actually produced.
- Main-display screenshots use UIKit render-display capture via `__UIRenderDisplay`.
- Other-display screenshots use the display IOSurface path and convert it into a CGImage.

### App-side action and notification endpoint

UIKit action object:

```text
UIDidTakeScreenshotAction
```

Important behavior:

```objc
-[UIDidTakeScreenshotAction UIActionType] returns 18
```

App-side dispatch chain:

```text
FrontBoard / FBS sends scene action
  -> UIDidTakeScreenshotAction, UIActionType 18
  -> UIKit scene/application action handling
  -> -[UIApplication _handleScreenshot]
```

Notification post point:

```objc
-[UIApplication _handleScreenshot]
{
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"UIApplicationUserDidTakeScreenshotNotification"
                      object:UIApp
                    userInfo:nil];
}
```

Meaning:

- `_handleScreenshot` does not initiate screenshot capture.
- It only translates the received `UIDidTakeScreenshotAction` into the public app notification.

### Screenshot path conclusion

The screenshot notification root for this analysis is:

```text
SpringBoard hardware-combination screenshot gesture
  -> ScreenshotServices capture
  -> FrontBoard action to app
  -> UIApplicationUserDidTakeScreenshotNotification
```

Do not describe `UIApplicationUserDidTakeScreenshotNotification` as being sourced from UIKit alone. UIKit is the terminal notification poster; the system-side origin is SpringBoard’s hardware-button screenshot action path, with ScreenshotServices doing the actual image capture.

## High-level conclusion

Native iOS screen recording affects `UIScreen.isCaptured` through this specialized path:

```text
replayd
  -> BKSDisplayServicesSetReplayCloneContexts(NSSet<NSNumber>)
  -> BKSDisplayServicesSetCloneMirroringMode(3)
  -> backboardd entitlement com.apple.backboardd.replayClone
  -> BKTVOutController _queue_replayCloneContextIDs
  -> kCAWindowServerClone_ReplayContexts in addClone options
  -> QuartzCore cloned display flag
  -> CADisplay.isCloned
  -> UIScreen.isCaptured / UIScreenCapturedDidChangeNotification
```

Do not collapse this into generic clone/mirror. The distinguishing markers are:

```text
BKSDisplayServicesSetReplayCloneContexts
BKSDisplayServicesSetCloneMirroringMode(3)
com.apple.backboardd.replayClone
_queue_replayCloneContextIDs
kCAWindowServerClone_ReplayContexts
```

Ordinary mirror path is:

```text
BKSDisplayServicesSetCloneMirroringMode(1)
```

Stop/clear path is:

```text
BKSDisplayServicesSetCloneMirroringMode(0)
```
