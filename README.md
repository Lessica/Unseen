# Unseen

[简体中文](README.zh.md)

Unseen is an iOS tweak that reduces ordinary apps' ability to detect or interfere with screenshots, screen recordings, and hidden layer flags. Its targets include sandboxed apps and jailbreak apps installed below the rootful, rootless, or RootHide `Applications` directory.

Tested on iOS 15.0/16.x/17.0/18.3, supports arm64/arm64e devices. The QuartzCore matchers are also regression-tested against local iOS 14.8, 15.0, 16.x, 17.0, 17.3.1, 17.4, 18.0, and 18.3 dyld shared caches.

## Background

Do users have the right to record their own phone screens? Of course they do. Taking screenshots or screen recordings of what is happening on your own device, keeping evidence, taking notes, troubleshooting, or saving personal records are all normal, reasonable, painfully obvious uses of a device. That right does not mean users may expose other people's privacy, redistribute copyrighted content, or commit digital infringement. It simply means an app should not treat basic actions on a user's own device as behavior to be tamed, monitored, and punished.

Unfortunately, some iOS apps have other ambitions. They enjoy dressing ordinary interface views up as sacred objects that must never be gazed upon: listening for screenshot notifications, probing the screen-recording state, marking layers as hidden so screenshots and recordings come out blank. The more imaginative ones tuck their views inside a `UITextField` password control, borrowing the system's protection for secure text entry to give plain old UI a little "no photography, please" costume. After a screenshot, they may also shower the user with share prompts, warning text, risk-control popups, or a parade of nagging messages. A touching kind of care, really: you pressed a system button, so now the app gets to teach you a lesson.

Apple, meanwhile, has mostly left the gate wide open for this behavior. The system presents screenshots and screen recording as user-facing features, then leaves apps plenty of room to detect, obstruct, hide, and lecture. When the platform declines to distinguish meaningful content protection from overreaching control, some apps naturally stretch "protecting content" into "managing the user." This is not surprising. It is just that familiar iOS politeness: the button is yours, the consequences belong to the app.

This imbalance is no longer an abstract concern. Projects like [ScreenShieldKit](https://github.com/Kyle-Ye/ScreenShieldKit) package the ability to hide `UIView`, `NSView`, `CALayer`, and SwiftUI views from screenshots as an ordinary Swift dependency. It even offers a `hiddenFromCapture(_:)` API, sparing developers from the old secure `UITextField` wrapper trick with almost touching convenience. To be clear, hiding passwords, one-time codes, keys, or genuinely sensitive data can be legitimate. The problem starts when private interfaces and gray-area mechanisms become app-side tooling at scale. At that point, "protecting content" can quietly become "deciding what the user is allowed to record." Big companies, platforms, and apps should not be the only parties with the power to control a user's device. Users deserve countervailing tools that let them resist overreach and reclaim control over their own screens.

Unseen does some of the work Apple did not do, but someone should do for users. It tries to reduce ordinary apps' awareness of screenshots and screen recordings, lower unnecessary obstruction and harassment, and let users record what is on their own devices with less noise. It makes "my screen is under my control" concrete again. Unseen does not exist to encourage digital infringement. Quite the opposite: it pushes back against the expansion of reasonable content protection into surveillance, intimidation, and experience hijacking.

## Demo

https://github.com/user-attachments/assets/4bb391eb-1f1e-4aaf-a133-06730d060858

## Options

- **Enable Unseen**: Master switch. When disabled, Unseen will not handle hidden content, screenshot notices, or screen recording state.
- **Reveal Hidden Content**: Makes screenshots and recordings try to show ordinary app content hidden through private layer flags. This does not bypass DRM or system copyright protections.
- **Protect System UI**: Avoids showing system interface elements that should remain hidden in screenshots and recordings. Available on iOS 17 and later.
- **Hide Screenshot Events**: Tries to prevent apps from learning when you take a screenshot through the system screenshot notification.
- **Hide Recording State**: Tries to prevent apps from learning that the screen is being recorded or mirrored through the system capture-state notification.
- **Restart Rendering Services**: Restarts `backboardd` and `SpringBoard` so rendering-related settings are reloaded.

## Test App

DEBUG packages include a `testapp` Theos application target; release packages omit it. After installing a DEBUG deb, `postinst` runs `uicache` and **Unseen Test** can verify hidden layers, a secure text canvas, system screenshot notifications, and `UIScreen.isCaptured`/capture-state notifications. Establish a baseline with the master switch off, then enable every option, restart the rendering services, and repeat the same actions. See [`testapp/README.md`](testapp/README.md) for the full procedure.

## DSC Pattern Regression

Run `scripts/verify-dsc-patterns.py --root /path/to/dyld` to test every main arm64/arm64e cache below a directory. The script resolves the real QuartzCore symbols with `ipsw`, disassembles the functions, and validates the legacy update-mask path, the scoped iOS 17+ `allowed_in_update` callsite and cached Render::Context PID offset, the inlined iOS 18 PID getter, and both the packed and expanded DisplayInfo layouts.

`scripts/fetch-dsc-matrix.sh run` downloads the sparse iPhone15,2 matrix (iOS 16.0, 16.4, 17.4, 17.7, 18.0, and 18.2) into `/Users/82flex/Desktop/dyld`. Downloads are resumable and sequential; each completed IPSW is extracted into `iOS_<version>__<build>__<device>`, verified, and then removed. Pass explicit versions to sample additional supported points, and use the `status` or `stop` action to inspect or interrupt the worker.

On iOS 17 and later, the process-aware render path hooks only the `prepare_layer0` caller of `allowed_in_update` and compares cached integer PIDs. It reuses backboardd's existing `BKSystemShellSentinel` lifecycle to maintain SpringBoard's PID; no process enumeration, process-name lookup, Objective-C messaging, allocation, or locking occurs inside the ownership decision. iOS 16 keeps the original legacy `TST/B.NE` patch and does not expose System UI protection.

## License

Unseen is licensed under the MIT License. See [LICENSE](LICENSE) for details.
