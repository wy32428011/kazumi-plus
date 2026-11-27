import 'package:flutter/material.dart';

import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/update/auto_updater.dart';

class UpdateSettingsPage extends StatefulWidget {
  const UpdateSettingsPage({super.key});

  @override
  State<UpdateSettingsPage> createState() => _UpdateSettingsPageState();
}

class _UpdateSettingsPageState extends State<UpdateSettingsPage> {
  bool _pluginUpdate = GStorage.getSetting(
    SettingsKeys.checkPluginUpdateOnStartup,
  );
  bool _checkingUpdate = false;

  Future<void> _checkAppUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      await AutoUpdater().manualCheckForUpdates();
    } finally {
      if (mounted) {
        setState(() => _checkingUpdate = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final updateConfigured = ApiEndpoints.isUpdateConfigured;
    return SettingsDetailScaffold(
      title: const Text('更新设置'),
      body: SettingsList(
        sections: [
          SettingsSection(
            title: const Text('启动时检查更新'),
            tiles: [
              if (updateConfigured) ...[
                SettingsTile.switchTile(
                  leading: Icons.update_rounded,
                  title: const Text('应用更新'),
                  description: Text('当前版本 ${ApiEndpoints.version}'),
                  initialValue: GStorage.getSetting(SettingsKeys.autoUpdate),
                  onToggle: (value) {
                    GStorage.putSetting(SettingsKeys.autoUpdate, value ?? false);
                    setState(() {});
                  },
                ),
                SettingsTile(
                  leading: Icons.system_update_alt_rounded,
                  title: Text(_checkingUpdate ? '正在检查更新…' : '立即检查应用更新'),
                  enabled: !_checkingUpdate,
                  onPressed: (_) => _checkAppUpdate(),
                ),
              ],
              if (!updateConfigured)
                SettingsTile(
                  leading: Icons.info_outline,
                  title: const Text('Kazumi Plus 应用更新'),
                  description: const Text('尚未配置独立版更新渠道，请使用发布包更新。'),
                ),
              SettingsTile.switchTile(
                leading: Icons.extension_rounded,
                title: const Text('规则更新'),
                initialValue: _pluginUpdate,
                onToggle: (value) {
                  setState(() => _pluginUpdate = value ?? !_pluginUpdate);
                  GStorage.putSetting(
                    SettingsKeys.checkPluginUpdateOnStartup,
                    _pluginUpdate,
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
