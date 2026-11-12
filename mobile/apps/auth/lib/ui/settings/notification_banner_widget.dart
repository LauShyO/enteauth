import 'package:ente_auth/services/preference_service.dart';
import 'package:ente_auth/ui/components/banner_widget.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:flutter/material.dart';

// Local change (enteauth slice): the logged-in branch showed account-bound
// storage/subscription banners from the Ente server. With no account, only
// the local rate/star banners remain.
class NotificationBannerWidget extends StatelessWidget {
  const NotificationBannerWidget({super.key});

  @override
  Widget build(BuildContext context) {
    List<Widget> contents = [];
    const sectionSpacing = SizedBox(height: 14);
    final currentTime = DateTime.now();
    final appInstallTime = PreferenceService.instance.getAppInstalledTime();
    final differenceInDays = currentTime
        .difference(DateTime.fromMillisecondsSinceEpoch(appInstallTime))
        .inDays;
    final l10n = context.strings;
    final rateSubText = l10n.rateUs;

    if (differenceInDays >= 4 && differenceInDays <= 7) {
      contents.clear();
      contents.addAll([
        BannerWidget(
          text: l10n.tellUsWhatYouThink,
          subText: rateSubText,
          type: BannerType.rateUs,
        ),
        sectionSpacing,
        BannerWidget(
          text: l10n.supportEnte,
          subText: l10n.giveUsAStarOnGithub,
          type: BannerType.starUs,
        ),
      ]);
    }
    return buildWidget(context, contents);
  }

  Widget buildWidget(BuildContext context, List<Widget> contents) {
    return Column(children: contents);
  }
}
