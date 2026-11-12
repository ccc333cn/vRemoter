# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

vRemoter 社区版 (Community Edition): a macOS menu-bar app (Swift Package, no Xcode project, macOS 12+, Apple Silicon releases). A Bluetooth voice remote's voice key drives the voice input of Doubao (豆包输入法) or WeType (微信输入法). The remote's microphone is mixed with the MacBook mic into a virtual CoreAudio device, `vRemoteDr 2ch`. The remote's other buttons can be remapped.

- **Origin:** forked from VincentKingHsu/vRemoter (MIT) at v1.2.3. Since v1.3.0 it is maintained independently at github.com/ccc333cn/vRemoter.
- **Do not sync or PR upstream.** Keep the original author's copyright line in LICENSE.
- **UI and docs are Chinese-first.** User-visible strings go through `L10n.text("中文", "English")`.

## Commands

```bash
swift build                                         # debug build (.build/debug/vRemote)
.build/debug/vRemote --voice-session-self-test      # voice-session state machine tests (DEBUG builds only)
Scripts/run-self-tests.sh                           # ATVV/ADPCM protocol tests (compiles ATVV/*.swift + SelfTests/main.swift with swiftc)
Scripts/package-app.sh                              # release build -> dist/build/vRemote.app (ad-hoc signed)
VREMOTER_DRIVER=/path/to/vRemoteDriver.driver Scripts/build-pkg.sh   # -> dist/vRemoter-<version>.pkg
```

**Tests**
- There is no XCTest target.
- Add voice-session cases as `test…` functions in `Sources/vRemote/VoiceSessionSelfTest.swift` and list them in `run()`.
- Add protocol cases to `SelfTests/main.swift`.

**Pkg build**
- `build-pkg.sh` normally rebuilds the driver from an installed `BlackHole2ch.driver`, which this Mac does not have.
- Set `VREMOTER_DRIVER` to a `vRemoteDriver.driver` extracted from an earlier pkg instead: `pkgutil --expand-full <pkg> <dir>`, then take `Payload/Library/Audio/Plug-Ins/HAL/vRemoteDriver.driver`.

**Local install for testing**
- When the driver is unchanged, quit the running app, then replace `/Applications/vRemote.app` with `dist/build/vRemote.app` via `ditto`. No sudo is needed.
- TCC permissions survive rebuilds because `package-app.sh` signs with a fixed designated requirement (`identifier "io.github.ccc333cn.vremoter"`). Changing the bundle ID forces users to re-grant Accessibility, Input Monitoring, Bluetooth and Microphone.

**Logs:** `~/Library/Logs/vRemote/vRemote.log`. Useful tags:
- `[VOICE-SESSION]`, `[TRIGGER]`, `[KEY]`, `[OPTION-RAW]` (physical trigger edges seen by the event tap)
- `[CAST-BLE]` / `[X6-BLE]` (ATVV), `[CAST-HID]` / `[X6]` (HID), `[INPUT-TRIGGER]`

## Architecture

`main.swift` (`AppController`) wires everything. Each supported remote has two independent connections:

- **HID bridge** (`ChromecastRemoteHIDBridge`, `X6HIDBridge`):
  - Uses IOHIDManager, matched by exact VID/PID.
  - Reads raw input reports for button mapping, seizing the device when remapping is on and falling back to shared mode if seize is refused.
  - Chromecast reports are report ID 1; the first payload byte is the key index.
- **BLE bridge** (`BLEBridge`, one instance per remote):
  - Uses CoreBluetooth with the ATVV (Google Voice over BLE) service: `ATVV/ATVVProtocol.swift`, IMA ADPCM in `ATVV/ADPCMDecoder.swift`.
  - The voice key arrives as ATVV `AUDIO_START` / `AUDIO_STOP`, not as HID: reason `0x03` is a physical press, `0x02` is a release.
  - Decoded 16 kHz PCM goes to `AudioPipe`.

**`X6SessionCoordinator`** is the single voice-session state machine for all remotes, despite its name.
- Phases: `closed → opening → open → closing`, with an owner (`remote` / `keyboard`).
- It turns remote gestures into input-method triggers: short tap toggles, long press (≥0.55 s) is hold-to-talk.
- Transport START/STOP is never itself a keyboard toggle.
- It never trusts its own assumptions about the input method's state. It verifies through `DoubaoAudioStateMonitor`, which reads the IME process's real CoreAudio capture state (`kAudioProcessPropertyIsRunningInput`). For example, if the IME is not recording 1 s after opening, it closes with "opening timeout".
- **Compatibility mode:** `IsRunningInput` only exists on macOS 14.2+. The monitor probes the HAL at launch and sets `canObserveRecording`. When it is false (or forced with `defaults write io.github.ccc333cn.vremoter voiceCompatibilityMode -bool YES`), snapshots are always `.unavailable` and `pid` only says whether the IME runs. The coordinator then opens as soon as the IME is running, closes on the key press (hold mode: on the keyboard release) without waiting for an inactive edge, and appends "兼容模式" to statuses. Use the override to test this path on a new Mac; `defaults delete io.github.ccc333cn.vremoter voiceCompatibilityMode` restores detection.
- Collaborators are injected (`sendTrigger`, `releaseTrigger`, `triggerMode`, `doubaoState`, `now`) so the self-test can drive it.

**Trigger keys** (`InputTrigger.swift`):
- `InputTriggerKey` is side-specific (left/right Option/Command/Control/Shift, plus Fn).
- `InputTriggerMode` must match the IME's shortcut type:
  - `toggle` sends a ~60 ms click at start and at stop.
  - `hold` keeps the key down for the whole recognition. `Key.releaseHeldTrigger()` must run on every session end and on quit.
  - Picking `toggle` for an IME push-to-talk shortcut makes the mic flash on and immediately off.
- Synthetic events carry `Key.syntheticMarker` in `eventSourceUserData`, so the CGEvent tap in `X6SearchSuppressor` can tell them apart from physical keys. That tap also:
  - observes the physical Mac-keyboard trigger (only the selected side's keycode);
  - suppresses X6's native Search action.

**`AudioPipe`** mixes the Mac mic (AVCaptureSession) with remote PCM into the `vRemoteDr 2ch` HAL driver.

**`Driver/`** builds `vRemoteDriver.driver`:
- It is a binary-patched BlackHole 2ch, so it is **GPL-3**: keep `THIRD_PARTY_NOTICES.md` and the build script.
- Its device transport is reported as USB because Doubao hides `virtual` CoreAudio devices.

**`VoiceInputMethod`** handles the two IMEs differently:
- Doubao: the user selects `vRemoteDr 2ch` in Doubao's own settings.
- WeType: it follows the system default input, so vRemoter routes the system input itself (`SystemInputRoute`, restored on quit).

**`RemoteMappingSupport`**:
- Stores button mappings per remote model, not per physical device.
- Mapping targets include keys, media keys, custom shortcuts, Lock Screen, Sleep, and an App Switcher session (virtual ⌘ hold + Tab, auto-commits after 1 s).

**`AppStorage`**:
- Wraps UserDefaults.
- `importLegacySettings()` runs once before `AppController` is created. It copies the original app's `local.simaqingfeng.vRemote` defaults.

**`UpdateSupport`**:
- Reads `VRReleasesURL` from `Packaging/Info.plist`, which points at the GitHub Releases API of ccc333cn/vRemoter.
- It decodes GitHub release JSON directly.
- Prereleases are ignored unless the running version contains `-`.
- It prefers a `.dmg` asset if one exists, so upload only the `.pkg`.

## Releasing

1. Bump `CFBundleShortVersionString` / `CFBundleVersion` in `Packaging/Info.plist`, plus `VERSION`, the `CHANGELOG.md` entry, and "当前版本" in `README.md`.
2. Build the pkg (see above). Commit with the `ccc333cn` noreply identity, then push to `main`.
3. Create a GitHub release with tag `vX.Y.Z`:
   - Not marked prerelease.
   - Attach an ASCII-named asset such as `vRemoter-Community-X.Y.Z-AppleSilicon.pkg`.
   - Chinese notes, including the pkg's SHA-256.
   - The pkg is unsigned. Install notes must mention 系统设置 → 隐私与安全性 → 仍要打开.

## Hardware notes

- **Supported remotes:**
  - Chromecast voice remote: VID `0x18D1`, PID `0x9450`.
  - X6 Remote: VID `0x1D5A`, PID `0xC081`.
- **Google's genuine Chromecast remote:** only sends the voice key to a Mac. Its other keys never arrive, and no host-side fix exists. Cheap third-party remotes with the same IDs send every key.
