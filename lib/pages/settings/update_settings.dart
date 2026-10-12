import 'package:flutter/material.dart';

import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/request/config/api_endpoints.dart';

class UpdateSettingsPage extends StatefulWidget {
  const UpdateSettingsPage({super.key});

  @override
  State<UpdateSettingsPage> createState() => _UpdateSettingsPageState();
}

class _UpdateSettingsPageState extends State<UpdateSettingsPage> {
  bool _pluginUpdate = GStorage.getSetting(
    SettingsKeys.checkPluginUpdateOnStartup,
  );

  @override
  Widget build(BuildContext context) => SettingsDetailScaffold(
    title: const Text('更新设置'),
    body: SettingsList(
      sections: [
        SettingsSection(
          title: const Text('启动时检查更新'),
          tiles: [
            if (ApiEndpoints.latestApp.isNotEmpty)
              SettingsTile.switchTile(
                leading: Icons.update_rounded,
                title: const Text('应用更新'),
                initialValue: GStorage.getSetting(SettingsKeys.autoUpdate),
                onToggle: (value) {
                  GStorage.putSetting(SettingsKeys.autoUpdate, value ?? false);
                  setState(() {});
                },
              ),
            if (ApiEndpoints.latestApp.isEmpty)
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
