import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme/app_theme.dart';
import 'services/workout_store.dart';
import 'screens/connect_device_screen.dart';
import 'screens/home_screen.dart';
import 'screens/splash_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await WorkoutStore.instance.load();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0D0D0D),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const GympathApp());
}

class GympathApp extends StatelessWidget {
  const GympathApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gympath',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final scale = min(
          media.size.width / 360.0,
          media.size.height / 800.0,
        ).clamp(0.85, 1.2);
        return MediaQuery(
          data: media.copyWith(textScaler: TextScaler.linear(scale)),
          child: child ?? const SizedBox.shrink(),
        );
      },
      initialRoute: '/splash',
      routes: {
        '/splash': (context) => const SplashScreen(),
        '/connect': (context) => const ConnectDeviceScreen(),
        '/home': (context) => const HomeScreen(),
      },
    );
  }
}
