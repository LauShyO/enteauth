import 'package:ente_auth/ente_theme_data.dart';
import 'package:ente_auth/locale.dart';
import 'package:ente_auth/services/auth_theme_preferences.dart';
import 'package:ente_auth/services/window_listener_service.dart';
import 'package:ente_auth/ui/home_page.dart';
import 'package:ente_logging/logging.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

class App extends StatefulWidget {
  final Locale? locale;
  final ThemeMode savedThemeMode;
  const App({
    super.key,
    this.locale = const Locale("en"),
    this.savedThemeMode = ThemeMode.system,
  });

  static void setLocale(BuildContext context, Locale newLocale) {
    _AppState state = context.findAncestorStateOfType<_AppState>()!;
    state.setLocale(newLocale);
  }

  static ThemeMode themeModeOf(BuildContext context) {
    return context.findAncestorStateOfType<_AppState>()!._themeMode;
  }

  static Future<void> setThemeMode(BuildContext context, ThemeMode themeMode) {
    return context.findAncestorStateOfType<_AppState>()!.setThemeMode(
      themeMode,
    );
  }

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  static final Logger _renderErrorLogger = Logger('RenderError');
  late ThemeMode _themeMode;
  Locale? locale;
  void setLocale(Locale newLocale) {
    setState(() {
      locale = newLocale;
    });
  }

  Future<void> setThemeMode(ThemeMode themeMode) async {
    await AuthThemePreferences.setThemeMode(themeMode);
    if (mounted) {
      setState(() {
        _themeMode = themeMode;
      });
    }
  }

  @override
  void initState() {
    _themeMode = widget.savedThemeMode;
    locale = widget.locale;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "ente",
      themeMode: _themeMode,
      theme: lightThemeData,
      darkTheme: darkThemeData,
      debugShowCheckedModeBanner: false,
      locale: locale,
      supportedLocales: appSupportedLocales,
      localeListResolutionCallback: localResolutionCallBack,
      localizationsDelegates: const [
        StringsLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      routes: _getRoutes,
      builder: _materialAppBuilder,
    );
  }

  Map<String, WidgetBuilder> get _getRoutes {
    // Local change (enteauth slice): no Ente account, no onboarding. The
    // app always opens directly on the home page in offline mode.
    return {
      "/": (context) {
        return const HomePage();
      },
    };
  }

  Widget _materialAppBuilder(BuildContext context, Widget? widget) {
    if (!kDebugMode) {
      Widget errorWidget = Center(
        child: Text(context.strings.somethingWentWrongMessage),
      );
      if (widget is Scaffold || widget is Navigator) {
        errorWidget = Scaffold(body: Center(child: errorWidget));
      }

      ErrorWidget.builder = (FlutterErrorDetails details) {
        _renderErrorLogger.severe(
          'Unhandled rendering error',
          details.exception,
          details.stack,
        );
        return errorWidget;
      };
    }

    if (widget != null) {
      return _wrapForMenubarMode(context, widget);
    }
    throw StateError('widget is null');
  }

  Widget _wrapForMenubarMode(BuildContext context, Widget child) {
    if (!WindowListenerService.instance.isMenubarMode() ||
        WindowListenerService.instance.isOneOffWindowed) {
      return child;
    }
    // Render at a larger logical size scaled down to the popover, so screens
    // designed for the full window fit without per-page changes.
    const scale = 0.85;
    final size = MediaQuery.of(context).size;
    final scaledSize = Size(size.width / scale, size.height / scale);
    return FittedBox(
      fit: BoxFit.fill,
      child: SizedBox(
        width: scaledSize.width,
        height: scaledSize.height,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(size: scaledSize),
          child: child,
        ),
      ),
    );
  }
}
