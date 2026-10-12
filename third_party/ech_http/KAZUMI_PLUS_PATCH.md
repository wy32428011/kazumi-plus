# Kazumi Plus 的 ech_http Windows 构建补丁

本目录保留 `ech_http 0.2.1` 的运行时源码、构建 hook、包声明、许可证及第三方声明。来源为 [pub.dev 官方归档](https://pub.dev/api/archives/ech_http-0.2.1.tar.gz)，对应上游仓库为 [ech-research/ech_http](https://github.com/ech-research/ech_http)。未复制上游示例、测试夹具、开发工具或构建缓存。

## 来源与完整性

- 上游版本：`0.2.1`。
- 原始归档 SHA256：`0fb7ae7fcc44e4a015e2b19a98c04d72cf65079467d61c1142c22fdc21fc4d2d`，与 Kazumi 原版 `pubspec.lock` 一致。
- 原始 `src/cacert.pem`：`188900` 字节。
- 原始 CA 文件 SHA256：`f66dff1bdf8f96060b8177976f8b7d9254bc89bc4db933d769f7384d28480bc9`。
- `LICENSE`、`THIRD_PARTY_NOTICES.md`、原始 CA 文件及上游预构建依赖 manifest 均保留。

## 修复内容

原版 `4960f9c04246eb52e1f36728f0f5c60ae6fa54dc` 在 Flutter `3.47.7`、Visual Studio `17.14.2` 上构建 Windows 时，`src/CMakeLists.txt` 将完整 CA 文件置入 `ca_bundle.h.in` 中的单个 C++ raw string，触发 MSVC `C2026`。微软文档说明单个字符串字面量有 [16380 个单字节字符的长度限制](https://learn.microsoft.com/en-us/cpp/error-messages/compiler-errors-1/compiler-error-c2026?view=msvc-170)。

补丁仅修改两个上游文件：

1. `src/CMakeLists.txt` 以 HEX 模式读取完整 CA 字节，生成每行 16 字节的数组初始化内容；MSVC 目标显式使用 UTF-8 源码编码。
2. `src/ca_bundle.h.in` 使用 `unsigned char` 数组保存完整内容，再按显式长度构造原有的 `const std::string &` 返回值。

该补丁不改变 CA 列表，不禁用证书验证，不调整 TLS/ECH 逻辑，也不修改上游下载地址或预构建依赖校验。

## 已完成验证

- 官方归档 SHA256 与锁文件一致。
- 从 CMake 实际生成的数组还原出 `188900` 字节，其 SHA256 与原 CA 文件完全一致。
- 使用上游 hook 同样的 MSVC 静态运行库配置 `CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`，独立编译并链接生成 `ech_http.dll` 成功。
- 根项目通过本目录的路径覆盖，已经完成 Windows debug/release、Android debug（x86_64 Flutter 内核）和 Android arm64 release 完整构建，退出码均为 0；两端的实际 Flutter build hook 均成功编译链接本补丁。
- 原版构建失败日志、补丁原生构建日志及 CA 字节回读结果保存在本任务 `.tools/logs/` 下。原版失败与补丁后验证分开记录；构建成功不等同于实际播放、界面和持久化运行验收。

## 应用接入与后续升级

根项目通过 `dependency_overrides` 中的 `ech_http: {path: third_party/ech_http}` 引用本目录，不修改全局 Pub 缓存。后续升级上游包时，应核实上游是否已经修复大 CA 字符串问题，并重新验证 CA 原始字节和 Windows/Android 构建后再移除补丁。
