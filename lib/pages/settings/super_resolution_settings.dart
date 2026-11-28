import 'package:flutter/material.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/bean/settings/settings_list.dart';

class SuperResolutionSettings extends StatefulWidget {
  const SuperResolutionSettings({super.key});

  @override
  State<SuperResolutionSettings> createState() =>
      _SuperResolutionSettingsState();
}

class _SuperResolutionSettingsState extends State<SuperResolutionSettings> {
  late bool disableWarning;
  late bool debandEnabled;
  late bool upscaleOutputEnabled;
  late bool autoDowngradeEnabled;
  late SuperResolutionMode superResolutionMode;
  late SuperResolutionContentProfile contentProfile;

  @override
  void initState() {
    super.initState();
    disableWarning = GStorage.getSetting<bool>(
      SettingsKeys.disableSuperResolutionWarning,
    );
    debandEnabled = GStorage.getSetting<bool>(
      SettingsKeys.superResolutionDebandEnabled,
    );
    upscaleOutputEnabled = GStorage.getSetting<bool>(
      SettingsKeys.superResolutionUpscaleOutput,
    );
    autoDowngradeEnabled = GStorage.getSetting<bool>(
      SettingsKeys.superResolutionAutoDowngrade,
    );
    superResolutionMode = SuperResolutionMode.fromStorageValue(
      GStorage.getSetting<int>(SettingsKeys.defaultSuperResolutionMode),
    );
    contentProfile = SuperResolutionContentProfile.fromStorageValue(
      GStorage.getSetting<int>(SettingsKeys.superResolutionContentProfile),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: const Text('超分辨率与画质增强'),
      body: SettingsList(
        sections: [
          SettingsRadioSection<SuperResolutionMode>(
            title: Text(
              '超分辨率需要启用硬件解码；Android 如开启后不生效，请在播放设置中将视频渲染器切换为 gpu 或 gpu-next',
            ),
            groupValue: superResolutionMode,
            onChanged: (SuperResolutionMode? value) {
              if (value == null) return;
              GStorage.putSetting<int>(
                SettingsKeys.defaultSuperResolutionMode,
                value.storageValue,
              );
              setState(() {
                superResolutionMode = value;
              });
            },
            tiles: [
              for (final mode in SuperResolutionMode.values)
                SettingsTile<SuperResolutionMode>.radioTile(
                  title: Text(mode.label),
                  description: Text(mode.description),
                  radioValue: mode,
                ),
            ],
          ),
          SettingsRadioSection<SuperResolutionContentProfile>(
            title: Text('内容增强策略'),
            groupValue: contentProfile,
            onChanged: (SuperResolutionContentProfile? value) {
              if (value == null) return;
              GStorage.putSetting<int>(
                SettingsKeys.superResolutionContentProfile,
                value.storageValue,
              );
              setState(() {
                contentProfile = value;
              });
            },
            tiles: [
              for (final profile in SuperResolutionContentProfile.values)
                SettingsTile<SuperResolutionContentProfile>.radioTile(
                  title: Text(profile.label),
                  description: Text(profile.description),
                  radioValue: profile,
                ),
            ],
          ),
          SettingsSection(
            title: Text('画质与性能保护'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.gradient_rounded,
                title: Text('自动去色带（Deband）'),
                description: Text('启用超分时同步减轻低码率片源暗场色块与断层'),
                initialValue: debandEnabled,
                onToggle: (value) async {
                  debandEnabled = value ?? !debandEnabled;
                  await GStorage.putSetting<bool>(
                    SettingsKeys.superResolutionDebandEnabled,
                    debandEnabled,
                  );
                  if (mounted) setState(() {});
                },
              ),
              SettingsTile.switchTile(
                leading: Icons.hd_rounded,
                title: Text('4K 高清纹理输出'),
                description: Text('高分屏下按片源比例将输出画面提升至最高 4K（片源已达 4K 时自动跳过）'),
                initialValue: upscaleOutputEnabled,
                onToggle: (value) async {
                  upscaleOutputEnabled = value ?? !upscaleOutputEnabled;
                  await GStorage.putSetting<bool>(
                    SettingsKeys.superResolutionUpscaleOutput,
                    upscaleOutputEnabled,
                  );
                  if (mounted) setState(() {});
                },
              ),
              SettingsTile.switchTile(
                leading: Icons.speed_rounded,
                title: Text('持续丢帧自动降档'),
                description: Text('性能不足导致持续丢帧时自动从质量档降至效率档或关闭'),
                initialValue: autoDowngradeEnabled,
                onToggle: (value) async {
                  autoDowngradeEnabled = value ?? !autoDowngradeEnabled;
                  await GStorage.putSetting<bool>(
                    SettingsKeys.superResolutionAutoDowngrade,
                    autoDowngradeEnabled,
                  );
                  if (mounted) setState(() {});
                },
              ),
              SettingsTile.switchTile(
                leading: Icons.notifications_off_rounded,
                title: Text('关闭性能提示'),
                description: Text('关闭每次启用质量档超分辨率时的提示'),
                initialValue: disableWarning,
                onToggle: (value) async {
                  disableWarning = value ?? !disableWarning;
                  await GStorage.putSetting<bool>(
                    SettingsKeys.disableSuperResolutionWarning,
                    disableWarning,
                  );
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
