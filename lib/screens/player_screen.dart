import 'package:flutter/material.dart';
import 'package:video_skin/video_skin.dart';

import '../player/custom_video_player.dart';

/// Hosts the player above regular page content, the way a video app would.
class PlayerScreen extends StatelessWidget {
  const PlayerScreen({
    super.key,
    required this.url,
    this.title,
    this.markers = demoMarkers,
  });

  /// Stand-in cues, so every video opened from the home screen demonstrates the
  /// markers. Real ones would come from whatever describes the video.
  ///
  /// Deliberately early and close together: the shortest sample is 19 seconds,
  /// and a marker past the end of a video is never reached.
  static const demoMarkers = <VideoMarker>[
    VideoMarker(
      time: Duration(seconds: 5),
      title: 'Chapter 1 — Getting started',
      body: 'This panel is a marker overlay. Playback resumes on its own.',
      duration: Duration(seconds: 4),
    ),
    VideoMarker(
      time: Duration(seconds: 12),
      title: 'Did you know?',
      body:
          'Markers are the ticks on the seek bar. Drag past one and nothing '
          'interrupts you — only playing through it raises the overlay.',
      duration: Duration(seconds: 5),
    ),
    VideoMarker(
      time: Duration(seconds: 40),
      title: 'Chapter 2 — Halfway',
      body: 'Rewind past a marker and it plays again the next time through.',
      duration: Duration(seconds: 4),
    ),
  ];

  final String url;
  final String? title;

  /// The timed overlays for this video.
  final List<VideoMarker> markers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E11),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // A 16:9 box is taller than a landscape screen, so cap the inline
            // player's height. Without this it overflows for the frame or two
            // between the device rotating and fullscreen taking over.
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.6,
              ),
              child: CustomVideoPlayer(
                url: url,
                title: title,
                markers: markers,
                onBack: () => Navigator.of(context).maybePop(),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
                children: [
                  Text(
                    title ?? 'Now playing',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    url,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white38,
                    ),
                  ),
                  const SizedBox(height: 28),
                  const _GestureGuide(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GestureGuide extends StatelessWidget {
  const _GestureGuide();

  static const _items = <(IconData, String, String)>[
    (Icons.touch_app_rounded, 'Tap', 'Show or hide the controls'),
    (Icons.replay_10_rounded, 'Double tap', 'Seek 10 seconds either way'),
    (Icons.swipe_up_rounded, 'Swipe up / down', 'Enter or leave fullscreen'),
    (Icons.speed_rounded, 'Speed', 'Tap 1x for 0.25x to 2x playback'),
    (
      Icons.bookmark_rounded,
      'Markers',
      'Ticks on the bar pause for a note, then resume',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          for (final (icon, title, subtitle) in _items)
            ListTile(
              dense: true,
              leading: Icon(icon, color: Colors.white54, size: 20),
              title: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                subtitle,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
