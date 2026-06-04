# Unseen

[简体中文](README.zh.md)

Unseen is an iOS tweak that reduces ordinary apps' ability to detect or interfere with screenshots, screen recordings, and hidden layer flags.

Tested on iOS 15.0/16.x/18.3, supports arm64/arm64e devices.

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
- **Hide Screenshot Events**: Tries to prevent apps from learning when you take a screenshot through the system screenshot notification.
- **Hide Recording State**: Tries to prevent apps from learning that the screen is being recorded or mirrored through the system capture-state notification.
- **Restart Rendering Services**: Restarts `backboardd` and `SpringBoard` so rendering-related settings are reloaded.

## License

Unseen is licensed under the MIT License. See [LICENSE](LICENSE) for details.
