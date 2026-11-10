# vRemoter 社区版

把蓝牙语音遥控器变成 Mac 上的语音输入和按键控制器：按遥控器语音键，豆包输入法或微信输入法开始语音识别；对着遥控器说话，文字出现在当前窗口。遥控器其他按键可以映射成方向键、快捷键、锁屏、切换应用等操作。

本项目基于 [VincentKingHsu/vRemoter](https://github.com/VincentKingHsu/vRemoter)（MIT 协议）v1.2.3，由社区独立维护，**不再同步原项目的更新**，与原作者无关。

当前版本：`1.3.1`

## 和原版的区别

- **支持微信输入法**：除豆包外，可以选微信输入法作为语音输入法，vRemoter 会自动切换系统输入。
- **触发键分左右**：Option、Command、Control、Shift 都可以单独选左侧或右侧，和输入法里的设置一一对应；Fn 不分左右。
- **两种触发方式**：「点按切换」对应输入法里按一下开始、再按一下结束的快捷键；「按住说话」对应输入法里按住才录音的快捷键，识别期间 vRemoter 会一直按住这个键。
- **修复**：
  - Chromecast 遥控器快速轻点语音键时，遥控器麦克风有时没打开，现在会自动重开。
  - 启用按键映射时系统拒绝独占设备，现在会退回共享模式，按键照样能用。
  - 遥控器语音连接断开后会自动重连，不再一直停在“正在连接语音服务”。
- **更新来源**：App 内的“检查更新”读取本仓库的 [Releases](https://github.com/ccc333cn/vRemoter/releases)。
- **没有统计和打赏**：去掉了使用统计上报、打赏和购买入口。
- 原版 1.2.3 的功能全部保留：锁屏、睡眠、切换应用三种映射动作，双路麦克风开关等。

## 支持的遥控器

- Google Chromecast 语音遥控器（VID `0x18D1` / PID `0x9450`）
  - 语音键短按开始、再按结束；长按说话、松开结束。
  - 方向、确认、返回、Home、YouTube、Netflix、信源、音量等按键都可以映射。
  - 注意：Google 原装遥控器在 Mac 上只会发送语音键，其他按键收不到；同型号的第三方遥控器全部按键可用。
- X6 Remote（VID `0x1D5A` / PID `0xC081`）：语音键短按切换。

## 安装

1. 到 [Releases](https://github.com/ccc333cn/vRemoter/releases) 下载最新的 `.pkg`。
   - 只支持 **Apple 芯片（M 系列）** 的 Mac，macOS 12 或更高版本。
2. 安装包**没有签名**，双击会被 macOS 拦下：到“系统设置 → 隐私与安全性”，点“仍要打开”。
3. 安装时会重启系统音频服务，正在播放的声音会断一下。
4. 首次打开需要授权：辅助功能、输入监控、蓝牙、麦克风。App 里有分步引导。

**从原版或旧社区版升级**：

- 安装后会替换 `/Applications/vRemote.app`，原版的设置（触发键、按键映射等）会自动导入。
- 因为 App 标识变了，macOS 会把它当成新 App，**需要重新授权一次**上面的权限。系统设置里原来的“vRemoter”条目可以删掉。
- 旧版本（包括 1.1.1 社区修复版）的更新检查指向原作者的服务器，会提示更新到原版。请手动安装本版本一次，之后的更新都从本仓库获取。

## 设置输入法

- **豆包输入法**：在豆包设置里把麦克风选为 `vRemoteDr 2ch`。
- **微信输入法**：vRemoter 会自动把系统输入切到 `vRemoteDr 2ch`。

然后让 vRemoter 的**触发键**和**触发方式**都与输入法里的语音快捷键一致：

- 快捷键设在输入法“按一下开始、再按一下结束”的那一栏（例如微信输入法的“启动语音输入”），选「点按切换」。
- 快捷键设在输入法“按住说话”的那一栏，选「按住说话」。选错了的典型现象是：按一下遥控器，麦克风亮一下马上就灭。
- 「按住说话」时，识别期间这个键一直处于按下状态，这时用电脑键盘打字会带上这个修饰键。

触发键选 Fn 时，实际效果取决于 Mac 和输入法的设置，建议先试一下。

## 从源码构建

需要 Xcode 命令行工具（Swift 5.9+）。

```bash
Scripts/run-self-tests.sh
Scripts/package-app.sh
VREMOTER_DRIVER=/path/to/vRemoteDriver.driver Scripts/build-pkg.sh
```

- `package-app.sh` 生成 `dist/build/vRemote.app`。
- `build-pkg.sh` 生成包含 App 和音频驱动的安装包。驱动可以用 `VREMOTER_DRIVER` 指定一个现成的 `vRemoteDriver.driver`（例如从上一版安装包里取出）；不指定时，会用本机已安装的 BlackHole 2ch 重新生成，见 [Driver/README.md](Driver/README.md)。

## 许可

- vRemoter 代码使用 MIT 协议，保留原作者的版权声明，见 [LICENSE](LICENSE)。
- 音频驱动 `vRemoteDriver.driver` 是 [BlackHole](https://github.com/ExistentialAudio/BlackHole) 0.4.1 的修改版，使用 GNU GPL v3 协议。修改方式见 [Driver/build-driver.sh](Driver/build-driver.sh)，BlackHole 源码见其仓库。
- 其他第三方代码见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

完整历史见 [CHANGELOG.md](CHANGELOG.md)。
