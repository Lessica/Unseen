# Unseen Test App

`UnseenTest` 是仅随 DEBUG 包构建和安装的 Theos application target，用于在真机上端到端验证三条功能链路；release 包不会包含它，也不会因卸载普通插件包而刷新它的图标：

1. QuartzCore `disableUpdateMask` 渲染屏蔽（同时测试直接设置 `0x12` 和 secure `UITextField` canvas）。
2. `UIApplicationUserDidTakeScreenshotNotification` 截图事件过滤。
3. `UIScreen.isCaptured` 与 `UIScreenCapturedDidChangeNotification` 录屏/投放状态屏蔽。

## 构建

在仓库根目录执行：

```sh
gmake package DEBUG=1
```

App 会作为 `/Applications/UnseenTest.app` 包含在 deb 中。插件的进程过滤器要求 uid 501，并同时支持 `/var/containers/Bundle/Application/` 中的沙盒 App，以及 rootful、rootless、RootHide 等布局下形如 `Applications/Foo.app/Foo` 的越狱 App。

DEBUG deb 的 `postinst` 会调用 `uicache -p` 注册桌面图标；卸载时，`prerm` 仅在测试 App 确实存在时调用 `uicache -u`。路径覆盖 `/Applications`、`/var/jb/Applications` 与 RootHide `.jbroot-*` 布局。

## 测试流程

先在 Unseen 设置中关闭总开关，点击“重启渲染服务”，打开 Unseen Test：

- 截图：普通绿色卡片存在，紫色和橙色受保护卡片缺失；“系统事件”增加。
- 录屏或镜像：状态显示“正在捕获”，状态通知或轮询变化增加；受保护卡片在成片中缺失。

然后打开总开关及全部三个功能开关，再次重启渲染服务并重复操作：

- 截图/录屏：三张卡片都存在。
- 截图：“系统事件”保持 0；“本地模拟”仍可增加。
- 录屏或镜像：`isCaptured` 保持 `NO`，状态通知和轮询变化保持 0。

每轮测试前使用界面中的清零按钮。设置由 `backboardd` 和 `SpringBoard` 启动时读取，因此只杀掉测试 App 不会使插件设置生效。
