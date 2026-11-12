// Local addition (enteauth slice): WebDAV sync settings (offline mode).
import 'package:ente_auth/core/configuration.dart';
import 'package:ente_auth/services/authenticator_service.dart';
import 'package:ente_auth/services/webdav_sync_service.dart';
import 'package:ente_auth/ui/settings/components/auth_settings_page_scaffold.dart';
import 'package:ente_auth/utils/toast_util.dart';
import 'package:ente_components/ente_components.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:ente_ui/components/buttons/button_widget.dart';
import 'package:ente_ui/components/buttons/models/button_type.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class WebdavSettingsPage extends StatefulWidget {
  const WebdavSettingsPage({super.key});

  @override
  State<WebdavSettingsPage> createState() => _WebdavSettingsPageState();
}

class _WebdavSettingsPageState extends State<WebdavSettingsPage> {
  final _service = WebdavSyncService.instance;
  late TextEditingController _serverController;
  late TextEditingController _usernameController;
  late TextEditingController _passwordController;
  late TextEditingController _remotePathController;
  late TextEditingController _syncPasswordController;

  bool _enabled = false;
  bool _autoSync = true;
  bool _hasWebdavPassword = false;
  bool _hasSyncPassword = false;
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _serverController = TextEditingController(text: _service.serverUrl);
    _usernameController = TextEditingController(text: _service.username);
    _passwordController = TextEditingController();
    _remotePathController = TextEditingController(text: _service.remotePath);
    _syncPasswordController = TextEditingController();
    _enabled = _service.isEnabled;
    _autoSync = _service.autoSync;
    _loadPasswordFlags();
  }

  Future<void> _loadPasswordFlags() async {
    final hasWebdavPassword = await _service.hasWebdavPassword;
    final hasSyncPassword = await _service.hasSyncPassword;
    if (!mounted) return;
    setState(() {
      _hasWebdavPassword = hasWebdavPassword;
      _hasSyncPassword = hasSyncPassword;
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _remotePathController.dispose();
    _syncPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.strings;
    final isOffline =
        AuthenticatorService.instance.getAccountMode() ==
        AccountMode.offline;
    return AuthSettingsPageScaffold(
      title: l10n.webdavSync,
      children: [
        if (!isOffline)
          Padding(
            padding: const EdgeInsets.all(Spacing.lg),
            child: Text(l10n.webdavOfflineOnly),
          )
        else if (!_loaded)
          const Padding(
            padding: EdgeInsets.all(Spacing.xxl),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          ..._settings(context),
      ],
    );
  }

  List<Widget> _settings(BuildContext context) {
    final l10n = context.strings;
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
        child: Text(l10n.webdavSyncDescription),
      ),
      const SizedBox(height: Spacing.lg),
      MenuGroupComponent(
        items: [
          SettingsItem(
            title: l10n.webdavEnableSync,
            showChevron: false,
            trailing: Switch.adaptive(
              value: _enabled,
              onChanged: (value) async {
                await _service.setEnabled(value);
                if (!mounted) return;
                setState(() => _enabled = value);
              },
            ),
          ),
        ],
      ),
      const SizedBox(height: Spacing.sm),
      MenuGroupComponent(
        items: [
          SettingsItem(
            title: l10n.webdavAutoSync,
            showChevron: false,
            trailing: Switch.adaptive(
              value: _autoSync,
              onChanged: !_enabled
                  ? null
                  : (value) async {
                      await _service.setAutoSync(value);
                      if (!mounted) return;
                      setState(() => _autoSync = value);
                    },
            ),
          ),
        ],
      ),
      const SizedBox(height: Spacing.xl),
      TextInputComponent(
        controller: _serverController,
        label: l10n.webdavServerUrl,
        hintText: 'https://dav.jianguoyun.com/dav/',
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: Spacing.lg),
      TextInputComponent(
        controller: _usernameController,
        label: l10n.webdavUsername,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: Spacing.lg),
      TextInputComponent(
        controller: _passwordController,
        label: l10n.webdavPassword,
        hintText: _hasWebdavPassword ? l10n.passwordSetHint : null,
        isPasswordInput: true,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: Spacing.lg),
      TextInputComponent(
        controller: _remotePathController,
        label: l10n.webdavRemoteFilePath,
        hintText: WebdavSyncService.defaultRemotePath,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: Spacing.lg),
      TextInputComponent(
        controller: _syncPasswordController,
        label: l10n.webdavSyncPassword,
        hintText: _hasSyncPassword ? l10n.passwordSetHint : null,
        isPasswordInput: true,
        message: l10n.webdavSyncPasswordHint,
        textInputAction: TextInputAction.done,
      ),
      const SizedBox(height: Spacing.xl),
      ButtonWidget(
        buttonType: ButtonType.primary,
        labelText: l10n.save,
        isDisabled: _busy,
        onTap: _saveConfig,
      ),
      const SizedBox(height: Spacing.sm),
      ButtonWidget(
        buttonType: ButtonType.secondary,
        labelText: l10n.webdavTestConnection,
        isDisabled: _busy,
        onTap: _testConnection,
      ),
      const SizedBox(height: Spacing.sm),
      ButtonWidget(
        buttonType: ButtonType.secondary,
        labelText: l10n.webdavSyncNow,
        isDisabled: _busy,
        onTap: _syncNow,
      ),
      const SizedBox(height: Spacing.lg),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
        child: Text(
          _lastSyncText(context),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ];
  }

  String _lastSyncText(BuildContext context) {
    final l10n = context.strings;
    final lastAt = _service.lastSyncAtMs;
    if (lastAt == null) {
      return l10n.webdavNeverSynced;
    }
    final when = DateFormat.yMd().add_Hm().format(
      DateTime.fromMillisecondsSinceEpoch(lastAt),
    );
    final message = _service.lastMessage;
    return message.isEmpty
        ? '${l10n.webdavLastSync}: $when'
        : '${l10n.webdavLastSync}: $when\n$message';
  }

  Future<void> _saveConfig() async {
    final l10n = context.strings;
    setState(() => _busy = true);
    try {
      await _persistConfig();
      if (!mounted) return;
      showToast(context, l10n.saved);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _persistConfig() async {
    await _service.saveConfig(
      serverUrl: _serverController.text,
      username: _usernameController.text,
      remotePath: _remotePathController.text,
    );
    final password = _passwordController.text;
    if (password.isNotEmpty) {
      await Configuration.instance.setWebdavPassword(password);
    }
    final syncPassword = _syncPasswordController.text;
    if (syncPassword.isNotEmpty) {
      await Configuration.instance.setWebdavSyncPassword(syncPassword);
    }
    await _loadPasswordFlags();
    if (!mounted) return;
    setState(() {
      _passwordController.clear();
      _syncPasswordController.clear();
    });
  }

  Future<void> _testConnection() async {
    setState(() => _busy = true);
    try {
      await _persistConfig();
      if (!mounted) return;
      final result = await _service.testConnection();
      if (!mounted) return;
      showToast(
        context,
        result.reachable
            ? '${context.strings.webdavConnectionOk}: ${result.message}'
            : '${context.strings.webdavConnectionFailed}: ${result.message}',
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    try {
      await _persistConfig();
      if (!mounted) return;
      final result = await _service.syncNow(isManual: true);
      if (!mounted) return;
      showToast(
        context,
        result.success
            ? '${context.strings.webdavSyncSuccess}: ${result.message}'
            : '${context.strings.webdavSyncFailed}: ${result.message}',
      );
      setState(() {});
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }
}
