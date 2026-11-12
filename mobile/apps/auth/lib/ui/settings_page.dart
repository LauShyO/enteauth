import 'dart:io';

import 'package:ente_auth/services/review_service.dart';
import 'package:ente_auth/ui/settings/about_settings_page.dart';
import 'package:ente_auth/ui/settings/components/auth_settings_navigation.dart';
import 'package:ente_auth/ui/settings/components/auth_settings_page_scaffold.dart';
import 'package:ente_auth/ui/settings/data/data_settings_page.dart';
import 'package:ente_auth/ui/settings/developer_settings_widget.dart';
import 'package:ente_auth/ui/settings/general_settings_page.dart';
import 'package:ente_auth/ui/settings/notification_banner_widget.dart';
import 'package:ente_auth/ui/settings/search/settings_search_registry.dart';
import 'package:ente_auth/ui/settings/security_settings_page.dart';
import 'package:ente_auth/ui/settings/support_settings_page.dart';
import 'package:ente_auth/ui/settings/theme_settings_page.dart';
import 'package:ente_components/ente_components.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:ente_ui/components/settings/app_engagement_section.dart';
import 'package:ente_ui/components/settings/more_from_ente_footer.dart';
import 'package:ente_ui/pages/settings_search_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';

// Local change (enteauth slice): the Ente account entries (account page,
// sign-in banner, logout) are removed. The app runs in offline mode only
// and syncs through WebDAV.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.scaffoldKey});

  final GlobalKey<ScaffoldState> scaffoldKey;

  @override
  Widget build(BuildContext context) {
    return _buildSettings(context);
  }

  Widget _buildSettings(BuildContext context) {
    final l10n = context.strings;
    final contents = <Widget>[];

    contents.addAll([
      SettingsItem(
        title: l10n.data,
        icon: HugeIcons.strokeRoundedDatabase01,
        semanticsIdentifier: 'auth_settings_data',
        onTap: () => _openDataSettings(context),
      ),
      const SizedBox(height: Spacing.sm),
      SettingsItem(
        title: l10n.security,
        icon: HugeIcons.strokeRoundedSecurityCheck,
        semanticsIdentifier: 'auth_settings_security',
        onTap: () =>
            pushAuthSettingsPage(context, const SecuritySettingsPage()),
      ),
    ]);

    if (Platform.isAndroid ||
        Platform.isWindows ||
        Platform.isLinux ||
        kDebugMode) {
      contents.addAll([
        const SizedBox(height: Spacing.sm),
        SettingsItem(
          title: l10n.theme,
          icon: Theme.of(context).brightness == Brightness.light
              ? HugeIcons.strokeRoundedSun03
              : HugeIcons.strokeRoundedMoon02,
          semanticsIdentifier: 'auth_settings_theme',
          onTap: () => pushAuthSettingsPage(context, const ThemeSettingsPage()),
        ),
      ]);
    }

    contents.addAll([
      const SizedBox(height: Spacing.sm),
      SettingsItem(
        title: l10n.general,
        icon: HugeIcons.strokeRoundedSettings01,
        semanticsIdentifier: 'auth_settings_general',
        onTap: () => pushAuthSettingsPage(context, const GeneralSettingsPage()),
      ),
      const SizedBox(height: Spacing.sm),
      AppEngagementSection(reviewUrl: ReviewService.url),
      const SizedBox(height: Spacing.sm),
      SettingsItem(
        title: l10n.support,
        icon: HugeIcons.strokeRoundedHelpCircle,
        semanticsIdentifier: 'auth_settings_support',
        onTap: () => pushAuthSettingsPage(context, const SupportSettingsPage()),
      ),
      const SizedBox(height: Spacing.sm),
      SettingsItem(
        title: l10n.about,
        icon: HugeIcons.strokeRoundedInformationCircle,
        semanticsIdentifier: 'auth_settings_about',
        onTap: () => pushAuthSettingsPage(context, const AboutSettingsPage()),
      ),
    ]);

    contents.addAll([
      const MoreFromEnteFooter(currentApp: ComponentApp.auth),
      const DeveloperSettingsWidget(),
      const NotificationBannerWidget(),
      const SizedBox(height: 60),
    ]);

    return AuthSettingsPageScaffold(
      title: l10n.settings,
      backButton: _closeButton(context),
      actions: [
        IconButtonComponent(
          tooltip: l10n.searchSettings,
          variant: IconButtonComponentVariant.primary,
          shouldSurfaceExecutionStates: false,
          icon: const HugeIcon(
            icon: HugeIcons.strokeRoundedSearch01,
            size: IconSizes.small,
          ),
          onTap: () => _openSearch(context),
        ),
      ],
      children: contents,
    );
  }

  Future<void> _openSearch(BuildContext context) async {
    final completed = await pushAuthSettingsPage<bool>(
      context,
      Builder(
        builder: (context) {
          final items = SettingsSearchRegistry.getSearchableItems(context);
          return ColoredBox(
            color: context.componentColors.backgroundBase,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width:
                    AuthSettingsPageScaffold.maxContentWidth + 2 * Spacing.lg,
                child: SettingsSearchPage(
                  key: ValueKey(Localizations.localeOf(context)),
                  items: items,
                  suggestions: SettingsSearchRegistry.getSuggestions(
                    context,
                    items,
                  ),
                  onNavigate: (context, routeBuilder) async {
                    final completed = await pushAuthSettingsPage<bool>(
                      context,
                      routeBuilder(context),
                    );
                    if (completed == true && context.mounted) {
                      Navigator.of(context).pop(true);
                    }
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
    if (completed == true) {
      scaffoldKey.currentState?.closeDrawer();
    }
  }

  Widget _closeButton(BuildContext context) {
    return Semantics(
      identifier: 'auth_settings_close',
      child: IconButtonComponent(
        tooltip: context.strings.close,
        variant: IconButtonComponentVariant.unfilled,
        shouldSurfaceExecutionStates: false,
        icon: const HugeIcon(icon: HugeIcons.strokeRoundedCancel01),
        onTap: () => scaffoldKey.currentState?.closeDrawer(),
      ),
    );
  }

  Future<void> _openDataSettings(BuildContext context) async {
    final completed = await pushAuthSettingsPage<bool>(
      context,
      const DataSettingsPage(),
    );
    if (completed == true) {
      scaffoldKey.currentState?.closeDrawer();
    }
  }
}
