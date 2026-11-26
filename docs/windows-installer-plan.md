# Windows 安装包一键打包计划

日期：2026-10-14。

## 需求与交付

- 新增项目根目录 `一键打包Windows安装包.exe`，双击直接构建 Windows x64 Release，并生成可安装、升级和卸载的 Setup EXE。
- 复用现有 `package_plus.ps1` 的共享文件锁、依赖准备、源码冻结、原生库检查和本次 ZIP 回读；新增 `WindowsInstaller` 目标，原多平台入口继续使用原默认目标。
- 当前工作区已有统一播放器改动，全部保留；打包真实当前源码并记录未提交状态。
- 固定安装身份 `KazumiPlus.Windows.Desktop`，默认每用户安装到 `%LOCALAPPDATA%\Programs\Kazumi Plus`，开始菜单入口、可选桌面快捷方式、卸载入口，安装或卸载时检查 `kazumi.plus.win.mutex` 要求用户正常退出程序。
- 安装器保持程序 `CompanyName=KazumiPlus`、`ProductName=Kazumi Plus`，升级和卸载均不处理 `%APPDATA%\KazumiPlus\Kazumi Plus` 中的规则、收藏和播放历史。
- 使用官方 Inno Setup 7.1.0 x64 编译器，以其官方 portable 模式放入项目 `.tools`，校验下载摘要和发布者签名；不设置全局关联或工具快捷方式。
- 从已核验的本次 ZIP 建立安装载荷，再加入 Visual Studio 可再分发目录的 x64 app-local CRT，记录文件来源、版本和摘要；不从 System32 抽取运行库。
- 产物包含 Windows ZIP、Setup EXE、来源和载荷清单、编译日志及 SHA256，独立批次保留历史安装包。

## 分工

1. 主代理负责官方工具准备、WindowsInstaller 调用链、载荷及安装产物回读。
2. 子代理负责安装脚本与 AppId、快捷方式、互斥和数据保留语义。
3. 子代理负责新增 EXE 入口及入口生成参数，保持原入口行为。
4. 独立交叉审查后，从新入口真实打包；在项目隔离目录安装、覆盖升级和卸载，回读文件、快捷方式与 HKCU 安装项，核对原用户数据摘要；最后更新 README。

## 验收边界

遵循用户要求，不新增或运行自动化测试套件。通过真实构建、Setup 生成、隔离安装/升级/卸载、文件摘要与注册项回读验证。验收前检查已有同 AppId 安装，避免覆盖真实安装；开始菜单使用本任务独立快捷方式分组，桌面只在没有已有同名快捷方式时验收。安装产物通过实际原生 DLL 加载及 app-local 运行库路径回读核验，不启动播放器写入用户 Hive，也不扩展到媒体源播放全套验收。

安装包当前不配置发布证书代码签名，不添加自签根证书。WebView2 Runtime 的目标机器可用性与安装器生成分开记录。

## 首次实装回读与修正

首批安装载荷 69 个文件及 HKCU 安装目录回读通过，原用户数据摘要未改变；但 `DisableProgramGroupPage=yes` 使 `/GROUP` 无法按验收意图使用独立分组，实际使用默认 Kazumi Plus 分组。确认创建的快捷方式均指向本次隔离目录后，已使用同一安装的卸载程序回收该验收安装。配置改为 `DisableProgramGroupPage=no`，保留正常的分组选择并重新生成安装程序，后续验收按实际新安装包执行。

## 最终完成记录

- 根目录 `一键打包Windows安装包.exe` 已生成，大小 18,432 字节，使用项目图标；默认 `WindowsInstaller`。原 `一键打包.exe` 默认仍为 `All`，两者共享 C# 源码及退出码/暂停/路径规则。
- 编译器固定 Inno Setup 7.1.0 x64，官方安装包摘要 `0362a383ed217d4c4239b5933866dd96d3eb2102737da92f80f6057a4b40df2f`、大小 14,304,168 字节、有效 Pyrsys B.V. 签名。首次镜像返回 404 后从官方同一 GitHub release 获取；portable 准备退出 0，无管理员模式、卸载项、文件关联或快捷方式。
- 官方 ISCC 的 PE 产品版本字段是 `0.0.0.0`，因此固定版本使用官方下载包版本及 `ISCC --version` 的 `7.1.0` 双重核对；132 个工具缓存文件摘要复用检查通过，ISCC 摘要 `d06ebd38f38e3cee60a3c50cc45bd449d77e0bc6a5cabc607ea9886808e4de1a`。
- 最终从实际入口以独立桌面控制台执行，07:19:29 开始，07:21:11 退出，监督进程实际读到退出码 0。批次 `dist/packages/20261014-071930-163-7a81c1ef-b9bb2d9d/`，来源提交 `7a81c1ef619859e460f725b6225749d0660630db`、`source_dirty=true`、源码摘要 `8c086be1ef048e430125b2627a99379418f9ebf4aab8e2b320b418ba52d0404d`，包含已有统一播放器工作区改动。

| 最终文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| `Kazumi-Plus-0.1.0-windows-x64-setup.exe` | 33,196,741 | `04922e0a29381f7debdf26efdea7f2b5915939a65643ee06d9beb9db7ab912b3` |
| `Kazumi-Plus-0.1.0-windows-x64.zip` | 40,581,219 | `35914b0374316b501b909d36c524c0e6308d6c6a640e1c8c1f3b171a35f39d81` |

ZIP 的 66 个文件经过原生 DLL、三个资产绑定及逐条摘要检查；安装载荷再加入三个有效 Microsoft 签名的 x64 app-local CRT，共 69 个文件。实际安装载荷和源 ZIP、CRT 的摘要链一致，没有从系统目录或旧安装包补文件。

隔离实装目录为 `.tools/windows-installer-acceptance/acceptance-20261014-072203-312/Kazumi Plus`。使用当前交付的同一 Setup EXE 完成以下回读：

- 安装退出 0，69 个载荷文件长度和摘要全部一致，HKCU 的固定 AppId 指向隔离目录。
- 独立开始菜单分组、卸载快捷方式和本次桌面快捷方式的目标及工作目录正确。开始菜单分组参数按修正后的配置生效。
- 修改本任务安装目录中的许可证副本后，不指定新目录执行覆盖安装；退出 0，沿用原目录，69 个文件全部恢复为载荷摘要。
- 在独立进程实际加载 `vcruntime140.dll`、`vcruntime140_1.dll`、`msvcp140.dll`、`flutter_windows.dll`、`libmpv-2.dll`、`media_kit_event_loop.dll`、`ech_http.dll`，模块路径均为本次安装目录，随后进程退出释放映射。
- 持有与应用相同的互斥对象时，安装器返回非零并未覆盖安装文件；释放后正常卸载。
- 卸载退出 0，69 个载荷文件、卸载项及本次快捷方式均清理，延迟自清理完成后安装目录也已移除。
- `%APPDATA%\KazumiPlus\Kazumi Plus` 原 37 个文件在安装、覆盖安装、原生库加载与卸载各阶段的摘要均相同，未启动播放器写入 Hive。

验收摘要保存在批次 `evidence/WindowsInstaller/installation-acceptance.json`；构建清单追加引用并保存追加前副本，最终 SHA256 清单的 Setup、ZIP 和两份来源清单共 4 项已独立回读一致。验收临时安装、快捷方式、HKCU 安装项与进程均已回收，诊断日志保留在项目忽略目录。

本轮未新增或运行自动化测试套件。生成的应用安装 EXE 目前为 `NotSigned`，未加入自签根证书；WebView2 Evergreen Runtime 未随包安装。安装/原生库回读与播放器 GUI、设备播放验收保持独立。本文及 README 的完成补记不改变已生成产物来源。
