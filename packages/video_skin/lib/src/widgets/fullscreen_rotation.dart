import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Turns the app a quarter turn while a video is in fullscreen, so fullscreen
/// works on an app that is locked to portrait.
///
/// Nothing here touches `SystemChrome.setPreferredOrientations`. The device
/// never rotates; the widget tree is rotated instead and told it is
/// landscape-shaped, so the player fills the screen sideways.
///
/// The rotation has to be applied above the [Navigator], because the player
/// renders its fullscreen layer into the app's [Overlay] — rotating anything
/// further down would turn the page but leave the video upright. Install it
/// once as [MaterialApp.builder]:
///
/// ```dart
/// MaterialApp(
///   builder: FullscreenRotation.builder,
///   home: const HomeScreen(),
/// )
/// ```
class FullscreenRotation {
  const FullscreenRotation._();

  /// Whether a player currently wants the app rotated.
  ///
  /// Set by the player when it enters and leaves fullscreen; the turn is
  /// animated from there.
  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  /// How long the quarter turn takes.
  ///
  /// Matched to the player package's own fullscreen resize so the video
  /// growing into place and the screen turning run as one movement.
  static const Duration duration = Duration(milliseconds: 300);

  /// Use as [MaterialApp.builder].
  static Widget builder(BuildContext context, Widget? child) {
    return _RotationHost(child: child ?? const SizedBox.shrink());
  }
}

class _RotationHost extends StatefulWidget {
  const _RotationHost({required this.child});

  final Widget child;

  @override
  State<_RotationHost> createState() => _RotationHostState();
}

class _RotationHostState extends State<_RotationHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: FullscreenRotation.duration,
    value: FullscreenRotation.active.value ? 1 : 0,
  );

  late final Animation<double> _turn = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOutCubic,
  );

  @override
  void initState() {
    super.initState();
    FullscreenRotation.active.addListener(_onActiveChanged);
  }

  @override
  void dispose() {
    FullscreenRotation.active.removeListener(_onActiveChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onActiveChanged() {
    if (FullscreenRotation.active.value) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final landscape = Size(screen.height, screen.width);

    return AnimatedBuilder(
      animation: _turn,
      child: widget.child,
      builder: (context, child) {
        final t = _turn.value;
        final turning = t > 0;
        final angle = t * math.pi / 2;

        // The tree is laid out at its destination size for the whole turn and
        // only the paint transform animates. Interpolating the size instead
        // would relayout every frame, resizing the player's WebView ~18 times
        // per transition; this way it resizes twice.
        //
        // The structure below is identical at every value of t. Adding or
        // removing a wrapper mid-transition would remount the Navigator
        // underneath, tearing down the WebView and restarting playback.
        return Stack(
          fit: StackFit.expand,
          children: [
            _RotatedLayout(
              angle: angle,
              childSize: turning ? landscape : screen,
              child: MediaQuery(
                data: turning ? _rotate(media) : media,
                child: child!,
              ),
            ),
            // Both ends of the turn fill the screen exactly, but the angles in
            // between do not — the corners swing outside it, and the layout
            // snaps to its destination on the first frame. A wash of black
            // that peaks mid-turn and clears at both ends covers all of it,
            // leaving a clean rotation.
            if (turning && t < 1)
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: math.sin(t * math.pi) * 0.9,
                    child: const ColoredBox(color: Colors.black),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Restates the screen metrics as the rotated tree sees them.
  static MediaQueryData _rotate(MediaQueryData media) {
    return media.copyWith(
      size: Size(media.size.height, media.size.width),
      padding: _rotateInsets(media.padding),
      viewPadding: _rotateInsets(media.viewPadding),
      // No text field is reachable in fullscreen, so the keyboard inset would
      // only ever be stale here.
      viewInsets: EdgeInsets.zero,
    );
  }

  /// Maps device edges onto the rotated tree's edges.
  ///
  /// Under one clockwise turn the device's top edge — the one with the notch —
  /// becomes the tree's left edge, the right becomes the top, and so on round.
  static EdgeInsets _rotateInsets(EdgeInsets insets) {
    return EdgeInsets.fromLTRB(
      insets.top,
      insets.right,
      insets.bottom,
      insets.left,
    );
  }
}

/// Lays its child out at [childSize] and paints it rotated by [angle] about the
/// centre of the space this box is given.
///
/// Neither stock widget can do both halves of this job. [RotatedBox] swaps the
/// child's constraints properly, but only in whole quarter turns, so it cannot
/// animate. [Transform.rotate] takes any angle but is paint-only, so the child
/// has to be forced to size with something like an [OverflowBox] — and then the
/// overflowing parts of the child stop responding to touch, because a render
/// box rejects hit tests that land outside its own bounds. In fullscreen that
/// silently kills every control near the edges, the back button included.
class _RotatedLayout extends SingleChildRenderObjectWidget {
  const _RotatedLayout({
    required this.angle,
    required this.childSize,
    required Widget super.child,
  });

  /// Rotation in radians, clockwise.
  final double angle;

  /// The size the child is laid out at, before rotation.
  final Size childSize;

  @override
  _RenderRotatedLayout createRenderObject(BuildContext context) {
    return _RenderRotatedLayout(angle, childSize);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderRotatedLayout renderObject,
  ) {
    renderObject
      ..angle = angle
      ..childSize = childSize;
  }
}

class _RenderRotatedLayout extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  _RenderRotatedLayout(this._angle, this._childSize);

  double get angle => _angle;
  double _angle;
  set angle(double value) {
    if (_angle == value) return;
    _angle = value;
    // The angle only affects the paint transform, so the child does not need
    // laying out again — which is what keeps the turn cheap.
    markNeedsPaint();
  }

  Size get childSize => _childSize;
  Size _childSize;
  set childSize(Size value) {
    if (_childSize == value) return;
    _childSize = value;
    markNeedsLayout();
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    size = constraints.biggest;
    child?.layout(BoxConstraints.tight(_childSize));
  }

  Matrix4 get _transform {
    final centre = size.center(Offset.zero);
    return Matrix4.identity()
      ..translateByDouble(centre.dx, centre.dy, 0, 1)
      ..rotateZ(_angle)
      ..translateByDouble(-_childSize.width / 2, -_childSize.height / 2, 0, 1);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) {
      layer = null;
      return;
    }
    layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      (PaintingContext context, Offset offset) {
        context.paintChild(child, offset);
      },
      oldLayer: layer as TransformLayer?,
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // Deliberately skips the usual bounds check. The child is larger than this
    // box and the rotation brings it back inside the screen, so a legitimate
    // hit can arrive from anywhere.
    return hitTestChildren(result, position: position);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintTransform(
      transform: _transform,
      position: position,
      hitTest: (BoxHitTestResult result, Offset transformed) {
        return child.hitTest(result, position: transformed);
      },
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.multiply(_transform);
  }
}
