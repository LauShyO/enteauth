import 'package:ente_auth/ui/settings/components/auth_settings_page_scaffold.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:ente_ui/components/settings/about_settings_section.dart';
import 'package:flutter/material.dart';

// Local change (enteauth slice): the in-app update check hits Ente's
// release endpoint, so it is removed. The app only networks to WebDAV.
class AboutSettingsPage extends StatelessWidget {
  const AboutSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.strings;
    return AuthSettingsPageScaffold(
      title: l10n.about,
      children: const [AboutSettingsSection(onCheckForUpdates: null)],
    );
  }
}
