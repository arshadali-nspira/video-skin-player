import 'package:flutter/material.dart';

import '../markers/video_marker.dart';

/// The panel a [VideoMarker] puts over the paused video.
///
/// Covers the whole player: half-black, so the frame underneath stays readable
/// as the thing the cue belongs to, with the content over it. Swallows every
/// pointer that lands on it — the controls below are inert for as long as this
/// is up, so a tap meant for the skip button can never reach the play button
/// behind it.
///
/// Dismissal is the marker controller's, not this widget's: the timer that
/// takes the overlay down and resumes playback runs there, so it survives this
/// widget being rebuilt on the way into fullscreen.
class MarkerOverlay extends StatefulWidget {
  const MarkerOverlay({
    super.key,
    required this.marker,
    required this.onSkip,
    this.remaining,
    this.accentColor = const Color(0xFFFF3B30),
  });

  final VideoMarker marker;

  /// How much of the cue is left when this is built. Null starts from the
  /// marker's full duration; a fullscreen copy taking over from an inline one
  /// passes what is actually left, so the countdown does not start again.
  final Duration? remaining;

  /// Takes the overlay down early and picks playback back up.
  final VoidCallback onSkip;

  final Color accentColor;

  @override
  State<MarkerOverlay> createState() => _MarkerOverlayState();
}

class _MarkerOverlayState extends State<MarkerOverlay>
    with SingleTickerProviderStateMixin {
  /// Runs 0 → 1 across the marker's duration, draining the countdown bar.
  ///
  /// Cosmetic only. The dismissal itself is the controller's timer, so a
  /// rebuild of this widget cannot cut a cue short or leave one up for good.
  late final AnimationController _countdown = AnimationController(
    vsync: this,
    duration: widget.marker.duration,
  )..forward(from: _elapsedFraction);

  /// How far through the cue already is, as a fraction of its duration.
  double get _elapsedFraction {
    final total = widget.marker.duration.inMilliseconds;
    final remaining = widget.remaining?.inMilliseconds;
    if (total <= 0 || remaining == null) return 0;
    return (1 - remaining / total).clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _countdown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final marker = widget.marker;

    return Positioned.fill(
      // Opaque, and with no handler: every tap, drag and double tap over the
      // overlay stops here rather than falling through to the gesture layer.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          builder: (context, t, child) => Opacity(opacity: t, child: child),
          child: ColoredBox(
            // The 50% black the cue sits on.
            color: Colors.black.withValues(alpha: 0.5),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // The inline player is a short box part-way down a page, so the
                // same card has to work at a fraction of the fullscreen height.
                final compact = constraints.maxHeight < 260;
                return Center(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: compact ? 8 : 20,
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          marker.builder?.call(context) ??
                              _content(compact: compact),
                          SizedBox(height: compact ? 10 : 18),
                          _countdownBar(),
                          SizedBox(height: compact ? 4 : 8),
                          _footer(),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _content({required bool compact}) {
    final marker = widget.marker;
    final body = marker.body;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          marker.title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: compact ? 16 : 20,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        if (body != null) ...[
          SizedBox(height: compact ? 4 : 8),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white70,
              fontSize: compact ? 12 : 14,
              height: 1.35,
            ),
          ),
        ],
      ],
    );
  }

  /// The bar that drains as the cue runs down, so the wait has a visible end.
  Widget _countdownBar() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 3,
        child: ColoredBox(
          color: Colors.white.withValues(alpha: 0.22),
          child: AnimatedBuilder(
            animation: _countdown,
            builder: (context, _) => FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: (1 - _countdown.value).clamp(0.0, 1.0),
              child: ColoredBox(color: widget.accentColor),
            ),
          ),
        ),
      ),
    );
  }

  Widget _footer() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        AnimatedBuilder(
          animation: _countdown,
          builder: (context, _) {
            final left = widget.marker.duration * (1 - _countdown.value);
            // Rounded up, so the last second reads "1s" rather than "0s".
            final seconds = (left.inMilliseconds / 1000).ceil();
            return Text(
              'Resumes in ${seconds}s',
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            );
          },
        ),
        TextButton.icon(
          onPressed: widget.onSkip,
          icon: const Icon(Icons.play_arrow_rounded, size: 18),
          label: const Text('Skip'),
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            visualDensity: VisualDensity.compact,
            textStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}
