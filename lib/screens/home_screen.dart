import 'package:flutter/material.dart';

import '../player/video_source.dart';
import 'player_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _urlController = TextEditingController(
    text: 'https://www.youtube.com/watch?v=jNQXAC9IVRw',
  );
  String? _error;

  static const _samples = <({String title, String url})>[
    (title: 'Me at the zoo', url: 'https://youtu.be/jNQXAC9IVRw'),
    (
      title: 'Never Gonna Give You Up',
      url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    ),
    (title: 'Gangnam Style', url: 'https://youtube.com/shorts/9bZkp7q19f0'),
    // Not the commondatastorage.googleapis.com/gtv-videos-bucket copy that
    // every tutorial links to — that bucket now answers 403.
    (
      title: 'Big Buck Bunny (MP4)',
      url:
          'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_30MB.mp4',
    ),
    (
      title: 'Apple BipBop (HLS)',
      url:
          'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8',
    ),
  ];

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _play(String url, {String? title}) {
    if (classifyVideoInput(url) == null) {
      setState(() => _error = 'Enter a YouTube link, video ID, or media URL.');
      return;
    }

    setState(() => _error = null);
    FocusScope.of(context).unfocus();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(url: url, title: title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E11),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 32, 20, 32),
          children: [
            Text(
              'Play a video',
              style: theme.textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'YouTube link, or a direct .mp4 / .m3u8 URL.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white54,
              ),
            ),
            const SizedBox(height: 28),
            TextField(
              controller: _urlController,
              style: const TextStyle(color: Colors.white),
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              onSubmitted: _play,
              decoration: InputDecoration(
                hintText: 'https://… .mp4, .m3u8, or a YouTube link',
                hintStyle: const TextStyle(color: Colors.white24),
                errorText: _error,
                prefixIcon: const Icon(
                  Icons.link_rounded,
                  color: Colors.white38,
                ),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _play(_urlController.text),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Play'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFF3B30),
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            const SizedBox(height: 36),
            Text(
              'TRY ONE',
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.white38,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            for (final sample in _samples)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.play_circle_outline_rounded,
                    color: Colors.white54,
                  ),
                ),
                title: Text(
                  sample.title,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
                subtitle: Text(
                  sample.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white30, fontSize: 12),
                ),
                onTap: () => _play(sample.url, title: sample.title),
              ),
          ],
        ),
      ),
    );
  }
}
