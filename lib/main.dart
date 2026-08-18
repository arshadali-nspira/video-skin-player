import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_skin/video_skin.dart';

import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The app is portrait only. Fullscreen video does not change this — the
  // player turns the widget tree instead of the device. See
  // [FullscreenRotation].
  SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
  runApp(const VideoApp());
}

class VideoApp extends StatelessWidget {
  const VideoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Custom YouTube Player',
      debugShowCheckedModeBanner: false,
      // Must sit above the Navigator: the player draws its fullscreen layer
      // into the app's Overlay, which a rotation further down would not reach.
      builder: FullscreenRotation.builder,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF3B30),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0E0E11),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
