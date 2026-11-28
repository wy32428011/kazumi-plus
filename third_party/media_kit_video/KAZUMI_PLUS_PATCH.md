# Kazumi Plus 的 media_kit_video 本地补丁

本目录保留 `media_kit_video 1.2.5` 的源码、原生平台实现与包声明。来源为 [Predidit/media-kit](https://github.com/Predidit/media-kit.git) 锁定提交 `803c4a27912091db6f839d48d1b984a0d9f588c7` 中的 `./media_kit_video` 子目录。

## 来源与完整性

- 上游仓库：`https://github.com/Predidit/media-kit.git`
- 上游提交：`803c4a27912091db6f839d48d1b984a0d9f588c7`
- 包版本：`1.2.5`
- 原始 `LICENSE` 完整保留于本目录。

## 修复与增强内容

原版 `media_kit_video` 在全平台超分场景存在两个限制：

1. **Android / Android TV 无法按目标分辨率放大输出 Surface**
   - 原版 `AndroidVideoController.setSize()` 直接抛出 `UnsupportedError`，且 `videoParams` 回调始终以源视频 `dw × dh` 调用 `SetSurfaceSize`。
   - 补丁修改 `lib/src/video_controller/android_video_controller/real.dart`：
     - 新增 `width` / `height` 目标覆盖尺寸与 `videoParamsWidth` / `videoParamsHeight` 源视频尺寸记录；
     - 在 `videoParamsSubscription` 中优先使用 `this.width ?? dw` 与 `this.height ?? dh`，并在非 `mediacodec_embed` 模式下同步更新 `android-surface-size`；
     - 实现受 `lock.synchronized` 保护的 `setSize({int? width, int? height})`，在 `mediacodec_embed` 下安全空操作，其余渲染器同步调用 `VideoOutputManager.SetSurfaceSize`、更新 `rect.value` 并刷新 `android-surface-size`。
2. **桌面与 iOS 端 `videoParams` 回调覆盖显式 `setSize()` 的竞态**
   - 原版 `NativeVideoController` 在收到新 `videoParams` 时会直接以 `width` / `height`（源尺寸）调用 `VideoOutputManager.SetSize`，可能覆盖上层通过 `setSize()` 设置的 4K 输出纹理尺寸。
   - 补丁修改 `lib/src/video_controller/native_video_controller/real.dart`：`videoParamsSubscription` 调用 `VideoOutputManager.SetSize` 时优先使用 `this.width ?? width` 与 `this.height ?? height`。
3. **独立路径依赖解析**
   - 修改 `pubspec.yaml` 中 `media_kit` 依赖声明，从 `path: ../media_kit` 改为指向与根项目一致的 `Predidit/media-kit` 锁定提交 `803c4a27912091db6f839d48d1b984a0d9f588c7`。

## 应用接入与后续升级

根项目通过 `dependency_overrides` 中的 `media_kit_video: {path: third_party/media_kit_video}` 引用本目录，不修改全局 Pub 缓存。后续升级上游 `Predidit/media-kit` 时，需核对 `AndroidVideoController` 与 `NativeVideoController` 的尺寸管理逻辑后再决定是否保留或迁移本补丁。
