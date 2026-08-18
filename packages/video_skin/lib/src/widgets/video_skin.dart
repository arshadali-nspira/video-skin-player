import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../markers/video_marker.dart';
import '../playback/playback_adapter.dart';
import 'fullscreen_rotation.dart';
import 'player_controls.dart';

/// The whole control surface, wrapped around any backend's video.
///
/// Give it the widget that renders the video and a [VideoPlaybackAdapter] that
/// drives it, and it supplies everything on top: the controls, the scrubber and
/// its frame previews, the timed marker overlays, the gestures, and fullscreen.
///
/// ```dart
/// VideoSkin(
///   adapter: myAdapter,
///   surface: MyBackendPlayer(controller: myController),
///   title: 'Lesson 3',
///   markers: const [VideoMarker(time: Duration(minutes: 2), title: 'Quiz')],
///   onBack: () => Navigator.of(context).maybePop(),
/// )
/// ```
///
/// Use [VideoSkin.deferred] instead when the adapter cannot exist until the
/// source has resolved — most packages only hand back a controller some seconds
/// after the widget is first built. Until one arrives the skin draws no controls
/// (the backend's own loading widget shows through) but still answers a swipe up
/// by going fullscreen over the loader, so an early gesture is not simply lost.
///
/// Fullscreen is a route this pushes, not a device rotation: the app can stay
/// locked to portrait and [FullscreenRotation] turns the widget tree instead.
/// Install that once as `MaterialApp.builder` — see its own documentation — or
/// pass `rotateOnFullscreen: false` if the app already rotates.
class VideoSkin extends StatefulWidget {
  /// For a backend whose adapter exists as soon as the widget does.
  VideoSkin({
    super.key,
    required VideoPlaybackAdapter adapter,
    required this.surface,
    this.title,
    this.aspectRatio = 16 / 9,
    this.accentColor = const Color(0xFFFF3B30),
    this.markers = const [],
    this.onBack,
    this.onFullscreenChanged,
    this.onFullscreenHandover,
    this.sourceFailed,
    this.rotateOnFullscreen = true,
  }) : adapterListenable = _Immediate(adapter);

  /// For a backend that resolves its source before it can produce an adapter.
  ///
  /// Pass a notifier holding null and set it once the controller is ready.
  const VideoSkin.deferred({
    super.key,
    required ValueListenable<VideoPlaybackAdapter?> adapter,
    required this.surface,
    this.title,
    this.aspectRatio = 16 / 9,
    this.accentColor = const Color(0xFFFF3B30),
    this.markers = const [],
    this.onBack,
    this.onFullscreenChanged,
    this.onFullscreenHandover,
    this.sourceFailed,
    this.rotateOnFullscreen = true,
  }) : adapterListenable = adapter;

  /// The adapter, once there is one.
  final ValueListenable<VideoPlaybackAdapter?> adapterListenable;

  /// The widget that renders video frames inline.
  ///
  /// Built by whoever owns the backend and mounted underneath the controls.
  /// It stays mounted while fullscreen is up — the fullscreen page gets its
  /// picture from [VideoPlaybackAdapter.buildFullscreenSurface] instead — so a
  /// backend that can only have one live surface must move it rather than build
  /// a second.
  final Widget surface;

  /// Shown in the control bar and on the loading fullscreen page.
  final String? title;

  /// Used for the inline box before the video's own ratio is known.
  final double aspectRatio;

  /// Drives the progress bar, the play button and the ticked settings option.
  final Color accentColor;

  /// Timed cues: each is a tick on the progress bar, and an overlay that
  /// interrupts playback for its own duration when the video plays through it.
  ///
  /// Read once, when the skin is first built — a marker list handed in later
  /// does not replace the one already being watched.
  final List<VideoMarker> markers;

  /// Invoked by the control bar's back button while not in fullscreen. Omit it
  /// and no back button is drawn inline.
  final VoidCallback? onBack;

  /// Fired as the video enters and leaves fullscreen, for a host that has to
  /// react — hiding its own app bar, say.
  final ValueChanged<bool>? onFullscreenChanged;

  /// Fired when a video that resolved *behind* a fullscreen loading page has
  /// been moved onto the real fullscreen page.
  ///
  /// Rarely needed. It exists for backends whose autoplay runs off the inline
  /// view becoming visible: a fullscreen page of ours covers that view, so the
  /// frame never comes and the video would sit on its first frame waiting to be
  /// tapped. Such a backend starts playback itself from here.
  final VoidCallback? onFullscreenHandover;

  /// Whether the source has failed for good.
  ///
  /// Only consulted while there is no adapter — after that
  /// [VideoPlaybackAdapter.hasError] carries the same news. It lets a swipe made
  /// over a dead link end in a failure message rather than a spinner that never
  /// stops.
  final ValueListenable<bool>? sourceFailed;

  /// Whether to turn the widget tree a quarter circle in fullscreen.
  ///
  /// Leave it on for an app locked to portrait. Turn it off for one that rotates
  /// with the device, where the tree is already landscape.
  final bool rotateOnFullscreen;

  @override
  State<VideoSkin> createState() => _VideoSkinState();
}

class _VideoSkinState extends State<VideoSkin> {
  /// Mirrors [VideoSkin.adapterListenable] into one notifier the controls and
  /// the fullscreen page can both watch, whichever constructor was used.
  final _adapter = ValueNotifier<VideoPlaybackAdapter?>(null);
  final _fullscreen = ValueNotifier<bool>(false);

  /// The stand-in fullscreen route, while one is up.
  ///
  /// There is no way to ask a backend for fullscreen before it has an adapter,
  /// so this page is ours: put up immediately, so a swipe over the loader goes
  /// fullscreen at once, and swapped for the real one as soon as there is an
  /// adapter to drive it.
  Route<void>? _standInRoute;

  /// Raises the timed overlays. Null for a video with no markers, which is also
  /// what keeps the controls from listening for cues that can never come.
  ///
  /// Owned here rather than by [PlayerControls] because the controls are torn
  /// down and rebuilt on the way into fullscreen, and which markers have already
  /// been shown has to survive that.
  late final VideoMarkerController? _markers = widget.markers.isEmpty
      ? null
      : VideoMarkerController(markers: widget.markers);

  /// What the controls should mount with after the next move in or out of
  /// fullscreen.
  ///
  /// Every such move tears the controls down and builds them again, so the copy
  /// that mounts afterwards cannot tell what caused it. Set by whoever asked for
  /// the move: true from a press on the control layer, which is an action and so
  /// leaves the controls up for the usual delay; false from the swipe, which is
  /// made on the picture and hands back a picture just as bare.
  bool _controlsUpAfterMove = false;

  static bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    widget.adapterListenable.addListener(_onAdapterChanged);
    _onAdapterChanged();
  }

  @override
  void didUpdateWidget(VideoSkin oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.adapterListenable != widget.adapterListenable) {
      oldWidget.adapterListenable.removeListener(_onAdapterChanged);
      widget.adapterListenable.addListener(_onAdapterChanged);
      _onAdapterChanged();
    }
  }

  @override
  void dispose() {
    _restoreSystemUi();
    widget.adapterListenable.removeListener(_onAdapterChanged);
    _markers?.dispose();
    _adapter.dispose();
    _fullscreen.dispose();
    super.dispose();
  }

  /// An adapter has arrived, or been replaced.
  void _onAdapterChanged() {
    final adapter = widget.adapterListenable.value;
    if (adapter == null || identical(adapter, _adapter.value)) return;
    _adapter.value = adapter;
    _markers?.attach(adapter);

    if (_standInRoute == null) return;
    // Deferred a frame: a backend usually publishes its adapter from the middle
    // of its own async setup, and the surface the fullscreen page reads has not
    // been built for it yet. Pushing the route from here would build that page
    // against a tree that does not exist.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final standIn = _standInRoute;
      // Gone or on its way out if they swiped back down while the video was
      // still loading. Their exit stands; the video stays inline.
      if (standIn == null || !standIn.isActive) return;
      _standInRoute = null;
      _toggleFullscreen(replacing: standIn);
      widget.onFullscreenHandover?.call();
    });
  }

  /// Handles the swipe on the stand-in layer, which is only ever mounted while
  /// the adapter is still missing.
  void _onSwipeWhileLoading(DragEndDetails details) {
    if (fullscreenIntentFromSwipe(details) == true) _enterFullscreenLoading();
  }

  /// Goes fullscreen before there is a video, on a page of our own.
  ///
  /// The video carries on resolving inline underneath, out of sight; this shows
  /// the backend's loader at full size.
  Future<void> _enterFullscreenLoading() async {
    if (_standInRoute != null || _adapter.value != null) return;

    final route = PageRouteBuilder<void>(
      // No transition, and opaque. The page underneath is turning a quarter
      // circle at this moment ([FullscreenRotation]), and anything that
      // composites the two — a fade, or a route that lets the one below keep
      // painting — shows that page's app bar swinging through the middle of the
      // screen. Going up instantly and covering completely means the turn
      // happens behind black.
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => LoadingFullscreenPage(
        accentColor: widget.accentColor,
        title: widget.title,
        sourceFailed: widget.sourceFailed ?? _never,
      ),
    );
    _standInRoute = route;
    _onFullscreenToggled(true);

    await Navigator.of(context).push(route);

    // Gone. Either the user left, which is a return to inline, or the hand-over
    // dropped it — and that clears the field first, so this does not undo the
    // fullscreen it just handed on to.
    if (!mounted || _standInRoute != route) return;
    _standInRoute = null;
    _onFullscreenToggled(false);
  }

  /// Enters or leaves fullscreen, through the adapter.
  ///
  /// [replacing] is the stand-in route this is taking over from, if any. It is
  /// dropped from *under* the real page once that page has finished animating
  /// in — popping it first would show the app's own page through the gap.
  ///
  /// [keepControls] is passed straight through to the controls the move
  /// rebuilds. See [_controlsUpAfterMove]. It defaults to false because the two
  /// callers that do not pass it — the swipe made over the loading spinner, and
  /// the hand-over from the stand-in route it puts up — are both that swipe.
  Future<void> _toggleFullscreen({
    Route<void>? replacing,
    bool keepControls = false,
  }) async {
    _controlsUpAfterMove = keepControls;

    final adapter = _adapter.value;
    if (adapter == null) return;

    await adapter.toggleFullscreen(
      context,
      onChanged: _onFullscreenToggled,
      pageBuilder: (context) => _FullscreenPage(
        adapter: adapter,
        adapterNotifier: _adapter,
        fullscreenNotifier: _fullscreen,
        accentColor: widget.accentColor,
        markers: _markers,
        titleOf: () => widget.title,
        onToggleFullscreen: _toggleFullscreen,
        startVisibleOf: () => _controlsUpAfterMove,
        onEntered: replacing == null ? null : () => _dropStandIn(replacing),
      ),
    );
  }

  void _dropStandIn(Route<void> route) {
    if (!mounted || !route.isActive) return;
    Navigator.of(context).removeRoute(route);
  }

  void _onFullscreenToggled(bool isFullscreen) {
    _fullscreen.value = isFullscreen;
    widget.onFullscreenChanged?.call(isFullscreen);

    // The device need never rotate; the widget tree is turned instead, and the
    // system bars go away while the video owns the screen.
    if (widget.rotateOnFullscreen) {
      FullscreenRotation.active.value = isFullscreen;
    }
    if (!_isMobile) return;
    SystemChrome.setEnabledSystemUIMode(
      isFullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  /// Hands the screen back to the rest of the app.
  void _restoreSystemUi() {
    if (widget.rotateOnFullscreen) FullscreenRotation.active.value = false;
    if (!_isMobile) return;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: ColoredBox(
        color: Colors.black,
        child: ValueListenableBuilder<VideoPlaybackAdapter?>(
          valueListenable: _adapter,
          child: widget.surface,
          builder: (context, adapter, surface) {
            return Stack(
              fit: StackFit.expand,
              children: [
                surface!,
                // Until there is an adapter there is nothing to control, so the
                // controls do not mount and the backend's own loading widget
                // shows through. That leaves no gesture surface at all, which
                // is why a swipe over a spinner would otherwise do nothing.
                // This stands in for exactly that stretch.
                if (adapter == null)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragEnd: _onSwipeWhileLoading,
                    child: const SizedBox.expand(),
                  )
                else
                  _ControlsHost(
                    adapterNotifier: _adapter,
                    fullscreenNotifier: _fullscreen,
                    isFullscreen: false,
                    accentColor: widget.accentColor,
                    markers: _markers,
                    titleOf: () => widget.title,
                    onBack: widget.onBack,
                    onToggleFullscreen: _toggleFullscreen,
                    startVisibleOf: () => _controlsUpAfterMove,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A [ValueListenable] holding one value that never changes.
class _Immediate<T> implements ValueListenable<T> {
  const _Immediate(this.value);

  @override
  final T value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

/// Stands in for a host that never reports a source failure.
const _never = _Immediate<bool>(false);

/// The body of the source-failure message.
///
/// Public so a backend's own error placeholder can use it and match the failure
/// the skin shows on its loading fullscreen page.
class SourceErrorBody extends StatelessWidget {
  const SourceErrorBody({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Colors.black87,
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, color: Colors.white70, size: 32),
              SizedBox(height: 8),
              Text(
                "This video couldn't be loaded.\n"
                'The link may be wrong, private, or offline.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fullscreen while the video is still resolving.
///
/// Deliberately not a copy of [PlayerControls]: there is nothing to play, seek
/// or scale yet, so it offers only what applies — a way out, by the back button
/// or by swiping back down.
class LoadingFullscreenPage extends StatelessWidget {
  const LoadingFullscreenPage({
    super.key,
    required this.accentColor,
    required this.title,
    required this.sourceFailed,
  });

  final Color accentColor;
  final String? title;

  /// Whether the source has failed while this page was up.
  final ValueListenable<bool> sourceFailed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: ValueListenableBuilder<bool>(
        valueListenable: sourceFailed,
        builder: (context, failed, _) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragEnd: (details) {
              if (fullscreenIntentFromSwipe(details) == false) {
                Navigator.of(context).maybePop();
              }
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (failed)
                  const SourceErrorBody()
                else
                  Center(
                    child: CircularProgressIndicator(
                      color: accentColor,
                      strokeWidth: 3,
                    ),
                  ),
                // Positioned, not a plain child. A bare child of a
                // [StackFit.expand] stack is given a tight full-screen height,
                // which a Row happily fills — and then centres its contents in,
                // putting the back button and title across the middle of the
                // screen. Pinning three edges leaves the height loose, so the
                // row is only as tall as the button. [PlayerControls] builds its
                // own top bar the same way.
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back_rounded),
                            color: Colors.white,
                            tooltip: 'Exit fullscreen',
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                          Expanded(
                            child: Text(
                              title ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Runs [onEntered] once the route it sits in has finished animating in.
///
/// The stand-in route underneath is only safe to drop once the page above fully
/// covers it.
class _WhenRouteSettled extends StatefulWidget {
  const _WhenRouteSettled({required this.onEntered, required this.child});

  final VoidCallback onEntered;
  final Widget child;

  @override
  State<_WhenRouteSettled> createState() => _WhenRouteSettledState();
}

class _WhenRouteSettledState extends State<_WhenRouteSettled> {
  Animation<double>? _animation;
  bool _reported = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (animation == _animation) return;
    _animation?.removeStatusListener(_onStatus);
    _animation = animation;
    if (animation == null || animation.isCompleted) {
      _report();
    } else {
      animation.addStatusListener(_onStatus);
    }
  }

  @override
  void dispose() {
    _animation?.removeStatusListener(_onStatus);
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _report();
  }

  /// Deferred: this can land mid-build, and the callback touches the navigator.
  void _report() {
    if (_reported) return;
    _reported = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onEntered();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Draws [PlayerControls] for whichever adapter is current.
class _ControlsHost extends StatelessWidget {
  const _ControlsHost({
    required this.adapterNotifier,
    required this.fullscreenNotifier,
    required this.isFullscreen,
    required this.accentColor,
    required this.titleOf,
    required this.onToggleFullscreen,
    required this.startVisibleOf,
    this.markers,
    this.onBack,
  });

  final ValueListenable<VideoPlaybackAdapter?> adapterNotifier;
  final ValueListenable<bool> fullscreenNotifier;

  /// Whether this copy of the controls belongs to the fullscreen page.
  final bool isFullscreen;

  final Color accentColor;
  final VideoMarkerController? markers;

  /// Read at build time rather than passed, because the fullscreen page is
  /// built once by the adapter and never handed new values.
  final String? Function() titleOf;
  final void Function({required bool keepControls}) onToggleFullscreen;
  final VoidCallback? onBack;

  /// Whether the controls this builds should mount already on screen.
  final bool Function() startVisibleOf;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlaybackAdapter?>(
      valueListenable: adapterNotifier,
      builder: (context, adapter, _) {
        if (adapter == null) return const SizedBox.shrink();
        return ValueListenableBuilder<bool>(
          valueListenable: fullscreenNotifier,
          builder: (context, playerIsFullscreen, _) {
            // The inline copy stays mounted underneath the fullscreen route.
            // Hiding it there keeps one set of controls live at a time.
            if (!isFullscreen && playerIsFullscreen) {
              return const SizedBox.shrink();
            }
            return PlayerControls(
              adapter: adapter,
              isFullscreen: isFullscreen,
              accentColor: accentColor,
              markers: markers,
              title: titleOf(),
              onBack: onBack,
              onToggleFullscreen: onToggleFullscreen,
              startVisible: startVisibleOf(),
            );
          },
        );
      },
    );
  }
}

/// The fullscreen page: the backend's picture, letterboxed, with a second copy
/// of the controls over it.
class _FullscreenPage extends StatelessWidget {
  const _FullscreenPage({
    required this.adapter,
    required this.adapterNotifier,
    required this.fullscreenNotifier,
    required this.accentColor,
    required this.titleOf,
    required this.onToggleFullscreen,
    required this.startVisibleOf,
    this.markers,
    this.onEntered,
  });

  final VideoPlaybackAdapter adapter;
  final ValueListenable<VideoPlaybackAdapter?> adapterNotifier;
  final ValueListenable<bool> fullscreenNotifier;
  final Color accentColor;
  final VideoMarkerController? markers;
  final String? Function() titleOf;
  final void Function({required bool keepControls}) onToggleFullscreen;
  final bool Function() startVisibleOf;

  /// Called once this page has finished animating in. Set only when it is
  /// taking over from a stand-in route that has to be dropped underneath it.
  final VoidCallback? onEntered;

  @override
  Widget build(BuildContext context) {
    // No PopScope here. The system back button pops this route, which is exactly
    // what leaving fullscreen means — the adapter resolves its awaited push,
    // clears its own flag and calls back through onChanged. A PopScope that
    // blocked the pop would also block a programmatic one and re-enter the
    // toggle.
    final onEntered = this.onEntered;
    final page = Material(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AnimatedBuilder(
              animation: adapter,
              builder: (context, _) => AspectRatio(
                aspectRatio: adapter.aspectRatio > 0
                    ? adapter.aspectRatio
                    : 16 / 9,
                child: adapter.buildFullscreenSurface(context),
              ),
            ),
          ),
          _ControlsHost(
            adapterNotifier: adapterNotifier,
            fullscreenNotifier: fullscreenNotifier,
            isFullscreen: true,
            accentColor: accentColor,
            markers: markers,
            titleOf: titleOf,
            onToggleFullscreen: onToggleFullscreen,
            startVisibleOf: startVisibleOf,
          ),
        ],
      ),
    );

    if (onEntered == null) return page;
    return _WhenRouteSettled(onEntered: onEntered, child: page);
  }
}
