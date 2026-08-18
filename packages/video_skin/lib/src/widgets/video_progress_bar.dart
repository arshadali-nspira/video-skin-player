import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A scrubbable progress bar with a buffered-range indicator.
///
/// Reports positions as fractions in the `0..1` range. The parent owns the
/// drag state so the value can be held steady while the user scrubs.
class VideoProgressBar extends StatelessWidget {
  const VideoProgressBar({
    super.key,
    required this.value,
    required this.buffered,
    required this.accentColor,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekEnd,
    this.isDragging = false,
    this.enabled = true,
    this.scrubLabel,
    this.scrubFrame,
    this.markers = const [],
    this.markerColor = const Color(0xFFFFD54F),
  });

  /// Playback position as a fraction of the total duration.
  final double value;

  /// Buffered fraction of the total duration.
  final double buffered;

  final Color accentColor;

  /// Called when a scrub begins, with the fraction the user touched.
  final ValueChanged<double> onSeekStart;

  /// Called continuously while scrubbing.
  final ValueChanged<double> onSeekUpdate;

  /// Called when the scrub is committed or cancelled.
  final VoidCallback onSeekEnd;

  /// Whether a scrub is in progress. Enlarges the thumb.
  final bool isDragging;

  /// Disabled until the duration is known, so a scrub cannot seek nowhere.
  final bool enabled;

  /// The time the thumb is currently over, shown in a bubble above it while
  /// scrubbing. Already formatted — this widget knows about fractions, not
  /// durations.
  final String? scrubLabel;

  /// The frame at the scrubbed position, shown above the timestamp. Null for a
  /// source no preview can be pulled from, which leaves the timestamp alone in
  /// the bubble.
  final ValueListenable<Uint8List?>? scrubFrame;

  /// Points of interest, as fractions of the total duration. Drawn as ticks on
  /// the track so the user can see a cue coming before it arrives.
  final List<double> markers;

  final Color markerColor;

  static const double _trackHeight = 4;
  static const double _touchHeight = 26;

  /// Ticks stand a little proud of the track, so one sitting on the played
  /// portion is still picked out against it.
  static const double _markerWidth = 3;
  static const double _markerHeight = 9;

  /// Gap between the middle of the track and the bottom of the bubble.
  static const double _labelLift = 18;

  /// Centres a tick on its fraction, and keeps the ones at either end of the
  /// video inside the track rather than hanging off it.
  static double _markerLeft(double fraction, double width) {
    final furthest = width > _markerWidth ? width - _markerWidth : 0.0;
    return (fraction * width - _markerWidth / 2).clamp(0.0, furthest);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        double fractionAt(Offset localPosition) {
          if (width <= 0) return 0;
          return (localPosition.dx / width).clamp(0.0, 1.0);
        }

        final progress = value.clamp(0.0, 1.0);
        final thumbRadius = isDragging ? 9.0 : 6.0;

        // Raw pointer events, not a GestureDetector.
        //
        // A detector carrying both a tap and a horizontal drag puts two
        // recognisers in the arena for one finger, and the drag winning
        // *cancels* the tap — firing onTapCancel, and with it a seek, in the
        // middle of a scrub that has only just begun. The scrub then ran with
        // the video already jumped somewhere else under it.
        //
        // A Listener has no arena and no such handover: one finger down is one
        // scrub, held for exactly as long as it is held, committed once when
        // it lifts.
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: enabled
              ? (e) => onSeekStart(fractionAt(e.localPosition))
              : null,
          onPointerMove: enabled
              ? (e) => onSeekUpdate(fractionAt(e.localPosition))
              : null,
          onPointerUp: enabled ? (_) => onSeekEnd() : null,
          onPointerCancel: enabled ? (_) => onSeekEnd() : null,
          child: SizedBox(
            height: _touchHeight,
            width: double.infinity,
            // Clip.none throughout: the bubble is drawn above this box, over
            // the video.
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (scrubLabel != null && isDragging)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: _touchHeight / 2 + _labelLift,
                    // Aligned rather than positioned at the thumb, because an
                    // Align never lets its child leave the box: the bubble
                    // tracks the thumb through the middle of the bar and comes
                    // to rest flush with either end instead of hanging off it.
                    // Which is also why it is not given the thumb's own
                    // Positioned treatment — that would run off both edges.
                    child: Align(
                      alignment: Alignment(progress * 2 - 1, 0),
                      child: _ScrubBubble(
                        label: scrubLabel!,
                        frame: scrubFrame,
                      ),
                    ),
                  ),
                Positioned.fill(
                  child: Center(
                    child: Stack(
                      alignment: Alignment.centerLeft,
                      clipBehavior: Clip.none,
                      children: [
                        // Unplayed track.
                        Container(
                          height: _trackHeight,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.24),
                            borderRadius: BorderRadius.circular(_trackHeight),
                          ),
                        ),
                        // Buffered track.
                        FractionallySizedBox(
                          widthFactor: buffered.clamp(0.0, 1.0),
                          child: Container(
                            height: _trackHeight,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.42),
                              borderRadius: BorderRadius.circular(_trackHeight),
                            ),
                          ),
                        ),
                        // Played track.
                        FractionallySizedBox(
                          widthFactor: progress,
                          child: Container(
                            height: _trackHeight,
                            decoration: BoxDecoration(
                              color: accentColor,
                              borderRadius: BorderRadius.circular(_trackHeight),
                            ),
                          ),
                        ),
                        // Marker ticks, over both tracks and under the thumb —
                        // the thumb is where the finger is, and nothing should
                        // sit on top of it.
                        for (final marker in markers)
                          if (marker >= 0 && marker <= 1)
                            Positioned(
                              left: _markerLeft(marker, width),
                              child: Container(
                                width: _markerWidth,
                                height: _markerHeight,
                                decoration: BoxDecoration(
                                  color: markerColor,
                                  borderRadius: BorderRadius.circular(
                                    _markerWidth / 2,
                                  ),
                                ),
                              ),
                            ),
                        // Thumb. Kept inside the track bounds at both extremes.
                        Positioned(
                          left: (progress * width) - thumbRadius,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            width: thumbRadius * 2,
                            height: thumbRadius * 2,
                            // Flat, like the rest of the controls: blur over
                            // the player's platform view halos on Android.
                            decoration: BoxDecoration(
                              color: accentColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The preview that rides above the thumb while scrubbing: the frame at that
/// point in the video, with its timestamp under it.
///
/// Falls back to the timestamp on its own until the first frame arrives, and
/// for good on a source frames cannot be pulled from.
class _ScrubBubble extends StatelessWidget {
  const _ScrubBubble({required this.label, this.frame});

  final String label;
  final ValueListenable<Uint8List?>? frame;

  /// Drawn at 16:9. A frame of another shape is cropped to it rather than
  /// letterboxed, so the bubble is one steady size all the way along the bar.
  static const double _frameWidth = 112;
  static const double _frameHeight = 63;

  @override
  Widget build(BuildContext context) {
    final frame = this.frame;

    return DecoratedBox(
      decoration: BoxDecoration(
        // Flat fill rather than a blur, for the same reason the buttons use
        // one: blur over the player's platform view halos on Android.
        color: Colors.black.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: frame == null
            ? _timestamp()
            : ValueListenableBuilder<Uint8List?>(
                valueListenable: frame,
                builder: (context, bytes, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (bytes != null) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: Image.memory(
                          bytes,
                          width: _frameWidth,
                          height: _frameHeight,
                          fit: BoxFit.cover,
                          // Holds the old frame on screen until the new one is
                          // decoded. Without it every frame blinks the bubble
                          // empty on its way in.
                          gaplessPlayback: true,
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    _timestamp(),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _timestamp() {
    return Text(
      label,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        // Tabular, so the bubble does not jitter as the digits change.
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}
