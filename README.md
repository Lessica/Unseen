# Unseen

Unseen 是一个 iOS tweak，用于降低普通 App 对截图、录屏和隐藏图层标记的感知与干扰。

在 iOS 16.7/18.6 上测试通过，支持 arm64/arm64e 设备。

Unseen is an iOS tweak that reduces ordinary apps' ability to detect or interfere with screenshots, screen recordings, and hidden layer flags.

Tested on iOS 16.7/18.6, supports arm64/arm64e devices.

## Demo

https://github.com/user-attachments/assets/4bb391eb-1f1e-4aaf-a133-06730d060858

## 功能选项

- **启用 Unseen**：总开关。关闭后，Unseen 不会处理隐藏画面、截图通知或录屏状态。
- **显示被隐藏的画面**：尽量让截图和录屏显示 App 通过私有接口标记为隐藏的普通画面。此功能不会绕过 DRM 或系统版权保护。
- **隐藏截图行为**：尽量阻止 App 通过系统截图通知得知用户何时截图。
- **隐藏录屏状态**：尽量阻止 App 通过系统录屏状态通知得知屏幕正在被录制或投放。
- **重启渲染服务**：重启 `backboardd` 和 `SpringBoard`，让渲染相关设置重新载入。

## Options

- **Enable Unseen**: Master switch. When disabled, Unseen will not handle hidden content, screenshot notices, or screen recording state.
- **Reveal Hidden Content**: Makes screenshots and recordings try to show ordinary app content hidden through private layer flags. This does not bypass DRM or system copyright protections.
- **Hide Screenshot Events**: Tries to prevent apps from learning when you take a screenshot through the system screenshot notification.
- **Hide Recording State**: Tries to prevent apps from learning that the screen is being recorded or mirrored through the system capture-state notification.
- **Restart Rendering Services**: Restarts `backboardd` and `SpringBoard` so rendering-related settings are reloaded.

## License

Unseen 使用 MIT License 授权。详见 [LICENSE](LICENSE)。

Unseen is licensed under the MIT License. See [LICENSE](LICENSE) for details.
