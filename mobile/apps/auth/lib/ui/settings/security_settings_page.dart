import 'package:ente_auth/core/configuration.dart';
import 'package:ente_auth/ui/settings/components/auth_settings_page_scaffold.dart';
import 'package:ente_auth/utils/dialog_util.dart';
import 'package:ente_components/ente_components.dart';
import 'package:ente_lock_screen/local_authentication_service.dart';
import 'package:ente_lock_screen/lock_screen_settings.dart';
import 'package:ente_lock_screen/ui/lock_screen_options.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:ente_ui/components/buttons/button_widget.dart';
import 'package:ente_ui/components/buttons/models/button_result.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';

// Local change (enteauth slice): the account-bound entries (email
// verification, passkey, active sessions) are removed with the Ente
// account. Only the local app lock remains.
class SecuritySettingsPage extends StatelessWidget {
  const SecuritySettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AuthSettingsPageScaffold(
      title: context.strings.security,
      children: [
        SettingsItem(
          title: context.strings.appLock,
          icon: HugeIcons.strokeRoundedSquareLock02,
          showOnlyLoadingState: true,
          onTap: () => _openAppLock(context),
        ),
      ],
    );
  }

  Future<void> _openAppLock(BuildContext context) async {
    final config = Configuration.instance;
    ButtonResult? result;
    if (config.hasOptedForOfflineMode() &&
        LockScreenSettings.instance.getOfflineModeWarningStatus()) {
      result = await showChoiceActionSheet(
        context,
        title: context.strings.warning,
        body: context.strings.appLockOfflineModeWarning,
        secondButtonLabel: context.strings.cancel,
        firstButtonLabel: context.strings.ok,
      );
      if (result?.action != ButtonAction.first) return;
      await LockScreenSettings.instance.setOfflineModeWarningStatus(false);
    }
    if (!context.mounted) return;
    final hasAuthenticated = await LocalAuthenticationService.instance
        .requestLocalAuthentication(
          context,
          context.strings.authToChangeLockscreenSetting,
        );
    if (!hasAuthenticated || !context.mounted) return;
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => const LockScreenOptions()));
  }
}
