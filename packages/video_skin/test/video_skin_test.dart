import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_skin/video_skin.dart';

import 'fake_playback_adapter.dart';

void main() {
  group('fullscreen rotation', () {
    tearDown(() => FullscreenRotation.active.value = false);

    testWidgets('lays the tree out landscape and keeps edge controls tappable', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: FullscreenRotation.builder,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: GestureDetector(
                key: const Key('corner'),
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const SizedBox(width: 48, height: 48),
              ),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byType(Scaffold)), const Size(400, 800));

      FullscreenRotation.active.value = true;
      await tester.pumpAndSettle();

      // The page is laid out landscape, at full size — not clamped back to the
      // portrait width, which would make it square and the video half size.
      expect(tester.getSize(find.byType(Scaffold)), const Size(800, 400));

      // A control at the far edge of the rotated tree still receives touches.
      // This is what breaks if the rotation is applied with a paint-only
      // transform: the edges fall outside the hit-testable bounds and the back
      // button silently stops working.
      await tester.tap(find.byKey(const Key('corner')));
      expect(taps, 1);

      FullscreenRotation.active.value = false;
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(Scaffold)), const Size(400, 800));
      await tester.tap(find.byKey(const Key('corner')));
      expect(taps, 2);
    });
  });

  group('formatDuration', () {
    test('pads seconds and drops the hour when unused', () {
      expect(formatDuration(const Duration(seconds: 9)), '0:09');
      expect(formatDuration(const Duration(minutes: 3, seconds: 45)), '3:45');
    });

    test('includes hours for long videos', () {
      expect(
        formatDuration(const Duration(hours: 1, minutes: 2, seconds: 5)),
        '1:02:05',
      );
    });
  });

  group('scrubbing the player', () {
    Future<Rect> pumpControls(
      WidgetTester tester,
      FakePlaybackAdapter controller,
    ) async {
      tester.view.physicalSize = const Size(800, 450);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerControls(
              adapter: controller,
              isFullscreen: false,
              onToggleFullscreen: ({required bool keepControls}) {},
            ),
          ),
        ),
      );
      await tester.pump();

      // The controls start hidden over the video; a tap on the surface brings
      // them up, and only then is the bar there to be touched.
      await tester.tapAt(tester.getCenter(find.byType(PlayerControls)));
      await tester.pump(const Duration(milliseconds: 300));
      controller.calls.clear();
      controller.seeks.clear();
      return tester.getRect(find.byType(VideoProgressBar));
    }

    testWidgets('pauses for the drag and picks playback back up on release', (
      tester,
    ) async {
      final controller = FakePlaybackAdapter();
      final bar = await pumpControls(tester, controller);

      final gesture = await tester.startGesture(
        Offset(bar.left + 40, bar.center.dy),
      );
      await tester.pump();

      expect(controller.calls.first, 'pause');
      expect(controller.isPlaying, isFalse);
      // The picture follows the finger down rather than waiting for release.
      expect(controller.seeks, isNotEmpty);

      await gesture.up();
      await tester.pump();

      expect(controller.calls.last, 'play');
      expect(controller.isPlaying, isTrue);
    });

    testWidgets('leaves an already-paused video paused', (tester) async {
      final controller = FakePlaybackAdapter(playing: false);
      final bar = await pumpControls(tester, controller);

      final gesture = await tester.startGesture(
        Offset(bar.left + 40, bar.center.dy),
      );
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(controller.calls, isNot(contains('play')));
      expect(controller.isPlaying, isFalse);
    });

    testWidgets('clears everything but the bar and readout while scrubbing', (
      tester,
    ) async {
      final controller = FakePlaybackAdapter();
      final bar = await pumpControls(tester, controller);

      /// The opacity of the fade wrapper nearest [target].
      double fadeAround(Finder target) {
        return tester
            .widget<AnimatedOpacity>(
              find
                  .ancestor(of: target, matching: find.byType(AnimatedOpacity))
                  .first,
            )
            .opacity;
      }

      final mute = find.byIcon(Icons.volume_up_rounded);
      final fullscreen = find.byIcon(Icons.fullscreen_rounded);
      final play = find.byIcon(Icons.pause_rounded);

      expect(fadeAround(mute), 1);
      expect(fadeAround(fullscreen), 1);
      expect(fadeAround(play), 1);

      final gesture = await tester.startGesture(
        Offset(bar.left + 40, bar.center.dy),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(fadeAround(mute), 0);
      expect(fadeAround(fullscreen), 0);
      // Paused by the scrub, so the play icon is what is there to hide now.
      expect(fadeAround(find.byIcon(Icons.play_arrow_rounded)), 0);

      // The two things that stay.
      expect(find.byType(VideoProgressBar), findsOneWidget);
      expect(find.textContaining('/'), findsOneWidget);

      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(fadeAround(mute), 1);
    });

    testWidgets('holds the readout still while the finger rests', (
      tester,
    ) async {
      final controller = FakePlaybackAdapter();
      final bar = await pumpControls(tester, controller);

      final gesture = await tester.startGesture(
        Offset(bar.left + bar.width / 2, bar.center.dy),
      );
      await tester.pump();
      expect(find.text('5:00'), findsWidgets);

      // Whatever the player reports, a held finger owns the readout.
      controller.tick(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('5:00'), findsWidgets);

      await gesture.up();
      await tester.pump();
    });
  });

  group('scrub gesture', () {
    testWidgets('holds steady while held and commits once on release', (
      tester,
    ) async {
      final updates = <double>[];
      var starts = 0;
      var ends = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: VideoProgressBar(
                  value: 0,
                  buffered: 0,
                  accentColor: const Color(0xFFFF3B30),
                  isDragging: true,
                  onSeekStart: (_) => starts++,
                  onSeekUpdate: updates.add,
                  onSeekEnd: () => ends++,
                ),
              ),
            ),
          ),
        ),
      );

      final bar = tester.getRect(find.byType(VideoProgressBar));
      final gesture = await tester.startGesture(
        Offset(bar.left + 30, bar.center.dy),
      );
      // Long enough that a tap recogniser would have claimed the touch.
      await tester.pump(const Duration(milliseconds: 200));
      expect(starts, 1);
      expect(ends, 0);

      await gesture.moveTo(bar.center);
      await tester.pump();
      // The scrub is under way. Nothing may be committed yet — a seek here is
      // the video jumping out from under a drag still in progress.
      expect(ends, 0);
      expect(updates, isNotEmpty);

      // Finger down but still: the position must not move on its own.
      final seen = updates.length;
      await tester.pump(const Duration(seconds: 1));
      expect(updates, hasLength(seen));
      expect(ends, 0);

      await gesture.up();
      await tester.pump();
      expect(ends, 1);
    });
  });

  group('control auto-hide', () {
    /// Mounts the controls over a playing video and brings them up, leaving a
    /// fresh hide delay running.
    Future<void> pumpVisibleControls(
      WidgetTester tester,
      FakePlaybackAdapter controller,
    ) async {
      tester.view.physicalSize = const Size(800, 450);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerControls(
              adapter: controller,
              isFullscreen: false,
              onToggleFullscreen: ({required bool keepControls}) {},
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tapAt(tester.getCenter(find.byType(PlayerControls)));
      // Past the double-tap window, which is what holds the tap back.
      await tester.pump(const Duration(milliseconds: 300));
    }

    /// What the control layer is fading towards: 1 on screen, 0 away.
    double opacity(WidgetTester tester) {
      final layer = find
          .ancestor(
            of: find.byIcon(Icons.settings_rounded),
            matching: find.byType(AnimatedOpacity),
          )
          .last;
      return tester.widget<AnimatedOpacity>(layer).opacity;
    }

    testWidgets('goes away on its own, and a tap brings it back', (
      tester,
    ) async {
      final controller = FakePlaybackAdapter();
      await pumpVisibleControls(tester, controller);
      expect(opacity(tester), 1);

      await tester.pump(const Duration(seconds: 4));
      expect(opacity(tester), 0);

      await tester.tapAt(tester.getCenter(find.byType(PlayerControls)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(opacity(tester), 1);
    });

    testWidgets('an action on a control puts the delay back to full', (
      tester,
    ) async {
      final controller = FakePlaybackAdapter();
      await pumpVisibleControls(tester, controller);

      // Two seconds in — the controls would have gone at three.
      await tester.pump(const Duration(seconds: 2));
      expect(opacity(tester), 1);
      await tester.tap(find.byIcon(Icons.volume_up_rounded));
      await tester.pump();

      // Past the original deadline, still up: the delay runs from the mute.
      await tester.pump(const Duration(seconds: 2));
      expect(opacity(tester), 1);

      // And then away again, three seconds after the action rather than never.
      await tester.pump(const Duration(seconds: 2));
      expect(opacity(tester), 0);
    });

    testWidgets('a double-tap seek takes the controls down for it', (
      tester,
    ) async {
      final controller = FakePlaybackAdapter();
      await pumpVisibleControls(tester, controller);
      expect(opacity(tester), 1);

      // Clear of the centre buttons, so the tap falls through to the gesture
      // layer underneath the controls.
      const spot = Offset(200, 225);
      await tester.tapAt(spot);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(spot);
      await tester.pump();

      // Off the picture the seek is landing on, at once rather than after the
      // delay — the indicator is drawn there.
      expect(controller.seeks, isNotEmpty, reason: 'the double tap seeked');
      expect(opacity(tester), 0);

      // And they stay down. Nothing brings them back but a tap.
      await tester.pump(const Duration(seconds: 4));
      expect(opacity(tester), 0);

      await tester.tapAt(spot);
      await tester.pump(const Duration(milliseconds: 300));
      expect(opacity(tester), 1);
    });

    testWidgets('the sheet does not take the controls down when it opens', (
      tester,
    ) async {
      final controller = FakePlaybackAdapter();
      await pumpVisibleControls(tester, controller);

      await tester.tap(find.byIcon(Icons.settings_rounded));
      await tester.pumpAndSettle();

      // The press opened a sheet; it did not dismiss the controls.
      expect(find.text('Settings'), findsOneWidget);
      expect(opacity(tester), 1);

      // And the delay goes on running underneath it — the sheet neither hides
      // the controls nor holds their clock.
      await tester.pump(const Duration(seconds: 4));
      expect(opacity(tester), 0);
      expect(find.text('Settings'), findsOneWidget, reason: 'the sheet stays');
    });

    testWidgets('the fullscreen button asks to keep the controls, the swipe '
        'does not', (tester) async {
      final controller = FakePlaybackAdapter();
      final asked = <bool>[];

      tester.view.physicalSize = const Size(800, 450);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerControls(
              adapter: controller,
              isFullscreen: false,
              startVisible: true,
              onToggleFullscreen: ({required bool keepControls}) =>
                  asked.add(keepControls),
            ),
          ),
        ),
      );
      await tester.pump();

      // A press on the control layer is an action, so the controls the move
      // rebuilds come up with it.
      await tester.tap(find.byIcon(Icons.fullscreen_rounded));
      await tester.pump();
      expect(asked, [true]);

      // The swipe is made on the picture, so the video it lands in stays bare.
      await tester.flingFrom(
        const Offset(200, 225),
        const Offset(0, -200),
        800,
      );
      await tester.pump();
      expect(asked, [true, false]);
    });

    testWidgets('controls replacing others start up, not hidden', (
      tester,
    ) async {
      // What a move in or out of fullscreen builds: the press that caused it
      // belongs to the copy being torn down, so the new one is told to mount
      // with the controls already up and the delay running.
      final controller = FakePlaybackAdapter();
      tester.view.physicalSize = const Size(800, 450);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerControls(
              adapter: controller,
              isFullscreen: true,
              startVisible: true,
              onToggleFullscreen: ({required bool keepControls}) {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(opacity(tester), 1);
      await tester.pump(const Duration(seconds: 4));
      expect(opacity(tester), 0, reason: 'and then the usual delay applies');
    });

    testWidgets('a stall while the seek lands does not bring them back', (
      tester,
    ) async {
      // What a real player does that the fake did not: a seek stops playback
      // for a moment while it buffers. That stop used to read as the user
      // pausing, so the controls a double tap had just taken away came back a
      // beat later — the gesture looked like it had done nothing.
      final controller = FakePlaybackAdapter();
      await pumpVisibleControls(tester, controller);

      const spot = Offset(200, 225);
      await tester.tapAt(spot);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(spot);
      await tester.pump();
      expect(opacity(tester), 0);

      controller.stall();
      await tester.pump();
      expect(opacity(tester), 0, reason: 'the buffer is not a user pause');

      await tester.pump(const Duration(seconds: 4));
      expect(opacity(tester), 0);
    });

    testWidgets('a double-tap seek does not pull hidden controls up', (
      tester,
    ) async {
      final controller = FakePlaybackAdapter();
      await pumpVisibleControls(tester, controller);
      await tester.pump(const Duration(seconds: 4));
      expect(opacity(tester), 0);

      const spot = Offset(200, 225);
      await tester.tapAt(spot);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(spot);
      await tester.pump();

      // The gesture works without the controls, and leaves them alone. The
      // pump runs out the seek indicator's own timer, which is all that is
      // still pending.
      expect(controller.seeks, isNotEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(opacity(tester), 0);
    });
  });

  group('settings sheet', () {
    /// Mounts the controls as a short box at the top of a tall screen — the
    /// inline shape, where the player is a long way from the bottom of the
    /// screen — and opens the settings sheet.
    Future<Rect> openSheet(
      WidgetTester tester,
      FakePlaybackAdapter controller,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 400,
                height: 200,
                child: PlayerControls(
                  adapter: controller,
                  isFullscreen: false,
                  onToggleFullscreen: ({required bool keepControls}) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final player = tester.getRect(find.byType(PlayerControls));
      await tester.tapAt(player.center);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byIcon(Icons.settings_rounded));
      await tester.pumpAndSettle();
      return player;
    }

    /// What the control layer is fading towards: 1 on screen, 0 away.
    ///
    /// The settings button has two [AnimatedOpacity] ancestors — the one that
    /// clears the top bar out of the way of a scrub, and outside it the one
    /// that shows and hides the whole control layer. The outer one is this.
    double controlLayerOpacity(WidgetTester tester) {
      final layer = find
          .ancestor(
            of: find.byIcon(Icons.settings_rounded),
            matching: find.byType(AnimatedOpacity),
          )
          .last;
      return tester.widget<AnimatedOpacity>(layer).opacity;
    }

    testWidgets('comes up over the whole screen, not inside the player', (
      tester,
    ) async {
      final controller = FakePlaybackAdapter();
      final player = await openSheet(tester, controller);
      expect(player.bottom, 200, reason: 'the player is a box near the top');

      // The point of pushing the sheet as a route on the root navigator: it
      // sits on the bottom of the screen, clear of the player box, rather than
      // being clipped into 200dp of video.
      final sheet = tester.getRect(find.text('Playback speed'));
      expect(sheet.top, greaterThan(player.bottom));
      expect(sheet.bottom, lessThan(800));
    });

    testWidgets('steps into the speed list, which offers no way back', (
      tester,
    ) async {
      final controller = FakePlaybackAdapter();
      await openSheet(tester, controller);

      // The front page names both settings and what each is set to.
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Playback speed'), findsOneWidget);
      expect(find.text('Quality'), findsOneWidget);
      expect(find.text('2x'), findsNothing);

      await tester.tap(find.text('Playback speed'));
      await tester.pumpAndSettle();
      expect(find.text('2x'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);

      // The list is a leaf: no arrow back to the front page. Tapping outside
      // is the only way out, and it leaves the sheet entirely.
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
      await tester.tapAt(const Offset(200, 40));
      await tester.pumpAndSettle();
      expect(find.text('2x'), findsNothing);
      expect(find.text('Settings'), findsNothing);
    });

    testWidgets('the speed list stays up so more than one can be tried', (
      tester,
    ) async {
      final controller = FakePlaybackAdapter();
      await openSheet(tester, controller);

      await tester.tap(find.text('Playback speed'));
      await tester.pumpAndSettle();

      /// The label the list has ticked.
      String ticked() {
        final row = find.ancestor(
          of: find.byIcon(Icons.check_rounded),
          matching: find.byType(Row),
        );
        return tester
            .widgetList<Text>(
              find.descendant(of: row.first, matching: find.byType(Text)),
            )
            .first
            .data!;
      }

      expect(ticked(), '1x');

      await tester.tap(find.text('1.5x'));
      await tester.pumpAndSettle();

      // Applied, and the list is still there with the tick moved onto it —
      // so a second choice can be made without reopening anything.
      expect(controller.speeds, [1.5]);
      expect(find.text('Playback speed'), findsOneWidget);
      expect(ticked(), '1.5x');

      await tester.tap(find.text('2x'));
      await tester.pumpAndSettle();
      expect(controller.speeds, [1.5, 2]);
      expect(ticked(), '2x');

      // Tapping outside is how it goes away.
      await tester.tapAt(const Offset(200, 40));
      await tester.pumpAndSettle();
      expect(find.text('Playback speed'), findsNothing);

      // Ends the watch [_holdPlaying] starts, so nothing is left pending.
      controller.isFinished = true;
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('leaves quality inert when there is nothing to switch to', (
      tester,
    ) async {
      // The fake reports no quality list, which is the plain-.mp4 case.
      final controller = FakePlaybackAdapter();
      await openSheet(tester, controller);

      await tester.tap(find.text('Quality'));
      await tester.pumpAndSettle();

      // Still the front page: the row says what it is, and does nothing.
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('dismissing with no choice made restarts the hide delay', (
      tester,
    ) async {
      final controller = FakePlaybackAdapter();
      await openSheet(tester, controller);
      // Not taken away by the press that opened the sheet: the sheet's own
      // barrier is what covers them, and they are still there underneath it.
      expect(controlLayerOpacity(tester), 1);

      // Tapped on the barrier, well above the sheet.
      await tester.tapAt(const Offset(200, 40));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsNothing);

      // The sheet closing is an action like any other: the controls come back,
      // wait out the delay, and go.
      expect(controlLayerOpacity(tester), 1);
      await tester.pump(const Duration(seconds: 4));
      expect(controlLayerOpacity(tester), 0);
    });

    testWidgets('picking an option does not summon the controls back', (
      tester,
    ) async {
      final controller = FakePlaybackAdapter();
      await openSheet(tester, controller);

      // The delay runs under the open sheet, so the controls go on their own
      // while the user is still choosing.
      await tester.pump(const Duration(seconds: 4));
      expect(controlLayerOpacity(tester), 0);

      await tester.tap(find.text('Playback speed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.5x'));
      await tester.pumpAndSettle();

      // Changed, and the controls stayed gone.
      expect(controller.speeds, [1.5]);
      expect(controlLayerOpacity(tester), 0);

      // Ends the watch [_holdPlaying] starts, so nothing is left pending.
      controller.isFinished = true;
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('keeps the controls up when the video is not running', (
      tester,
    ) async {
      // The delay never runs over a video that is not playing — its controls
      // are the only way to start it again. Same rule as everywhere else, not
      // one for the sheet.
      final controller = FakePlaybackAdapter(playing: false);
      await openSheet(tester, controller);

      await tester.tapAt(const Offset(200, 40));
      await tester.pumpAndSettle();

      expect(controlLayerOpacity(tester), 1);
      await tester.pump(const Duration(seconds: 4));
      expect(controlLayerOpacity(tester), 1);
    });
  });

  group('video markers', () {
    const cue = VideoMarker(
      time: Duration(seconds: 5),
      title: 'Sample cue',
      body: 'Sample body',
      duration: Duration(seconds: 3),
    );

    /// Plays the video forward in steps small enough to read as playback rather
    /// than as a seek.
    void play(FakePlaybackAdapter controller, Duration to) {
      for (var i = 0; i < to.inSeconds; i++) {
        controller.tick(const Duration(seconds: 1));
      }
    }

    VideoMarkerController attach(
      FakePlaybackAdapter controller, [
      List<VideoMarker> markers = const [cue],
    ]) {
      final cues = VideoMarkerController(markers: markers);
      addTearDown(cues.dispose);
      cues.attach(controller);
      return cues;
    }

    testWidgets('pauses at the marker and resumes when its time is up', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      final controller = FakePlaybackAdapter();
      final cues = attach(controller);

      play(controller, const Duration(seconds: 4));
      expect(cues.active, isNull, reason: 'not reached yet');

      play(controller, const Duration(seconds: 1));
      expect(cues.active, cue);
      expect(controller.isPlaying, isFalse);

      await tester.pump(const Duration(seconds: 3));
      expect(cues.active, isNull);
      expect(controller.isPlaying, isTrue);
      expect(controller.calls, containsAllInOrder(['pause', 'play']));
    });

    testWidgets('resumes only what it paused', (tester) async {
      await tester.pumpWidget(const SizedBox());
      final controller = FakePlaybackAdapter(playing: false);
      final cues = attach(controller);

      // Position reports from a video that is not running — a player stalling
      // its way through a stretch still reports them. The cue is due, but there
      // is no playback of the user's for it to interrupt.
      for (var second = 1; second <= 5; second++) {
        controller.seekTo(Duration(seconds: second));
      }
      expect(cues.active, cue);
      expect(controller.calls, isNot(contains('pause')));

      await tester.pump(const Duration(seconds: 3));
      expect(cues.active, isNull);
      expect(controller.calls, isNot(contains('play')));
      expect(controller.isPlaying, isFalse);
    });

    test('a seek past a marker goes by without raising it', () {
      final controller = FakePlaybackAdapter();
      final cues = VideoMarkerController(markers: const [cue]);
      addTearDown(cues.dispose);
      cues.attach(controller);

      controller.seekTo(const Duration(seconds: 30));
      expect(cues.active, isNull);
    });

    test('rewinding past a marker arms it again', () {
      final controller = FakePlaybackAdapter();
      final cues = VideoMarkerController(markers: const [cue]);
      addTearDown(cues.dispose);
      cues.attach(controller);

      for (var i = 0; i < 5; i++) {
        controller.tick(const Duration(seconds: 1));
      }
      expect(cues.active, cue);
      cues.dismiss();

      controller.seekTo(Duration.zero);
      for (var i = 0; i < 5; i++) {
        controller.tick(const Duration(seconds: 1));
      }
      expect(cues.active, cue, reason: 'the cue plays again on a second pass');
    });

    test('a held scrub over a marker raises nothing', () {
      final controller = FakePlaybackAdapter();
      final cues = VideoMarkerController(markers: const [cue]);
      addTearDown(cues.dispose);
      cues.attach(controller);

      cues.hold(CueHold.scrub);
      // A slow drag reports in steps that would otherwise read as playback.
      for (var i = 0; i < 8; i++) {
        controller.seekTo(Duration(seconds: i));
      }
      expect(cues.active, isNull);

      cues.release(CueHold.scrub);
      controller.tick(const Duration(seconds: 1));
      expect(cues.active, isNull, reason: 'the marker is behind the playhead');
    });

    test('a quality swap tearing the stream down replays nothing', () {
      final controller = FakePlaybackAdapter();
      final cues = VideoMarkerController(markers: const [cue]);
      addTearDown(cues.dispose);
      cues.attach(controller);

      for (var i = 0; i < 6; i++) {
        controller.tick(const Duration(seconds: 1));
      }
      expect(cues.active, cue);
      cues.dismiss();

      // What switchQuality does to the playhead: the replacement stream reports
      // zero, then the saved position is restored under it.
      cues.hold(CueHold.transition);
      controller.seekTo(Duration.zero);
      controller.seekTo(const Duration(seconds: 6));
      cues.release(CueHold.transition);

      controller.tick(const Duration(seconds: 1));
      expect(cues.active, isNull, reason: 'the cue was already played through');
    });

    test('one hold ending does not release another', () {
      final controller = FakePlaybackAdapter();
      final cues = VideoMarkerController(markers: const [cue]);
      addTearDown(cues.dispose);
      cues.attach(controller);

      cues.hold(CueHold.transition);
      cues.hold(CueHold.scrub);
      cues.release(CueHold.transition);
      expect(cues.isHeld, isTrue);

      for (var i = 0; i < 6; i++) {
        controller.tick(const Duration(seconds: 1));
      }
      expect(cues.active, isNull);

      cues.release(CueHold.scrub);
      expect(cues.isHeld, isFalse);
    });

    testWidgets('draws a tick per marker on the seek bar', (tester) async {
      final controller = FakePlaybackAdapter();
      final cues = attach(controller, const [
        cue,
        VideoMarker(time: Duration(minutes: 5), title: 'Halfway'),
        // Past the end of a ten-minute video, so there is nowhere to draw it.
        VideoMarker(time: Duration(minutes: 30), title: 'Never'),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerControls(
              adapter: controller,
              isFullscreen: false,
              onToggleFullscreen: ({required bool keepControls}) {},
              markers: cues,
            ),
          ),
        ),
      );
      await tester.pump();

      final bar = tester.widget<VideoProgressBar>(
        find.byType(VideoProgressBar),
      );
      expect(bar.markers, [5 / 600, 0.5]);
    });

    testWidgets('a speed change does not play on under the overlay', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 450);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final controller = FakePlaybackAdapter();
      final cues = attach(controller);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerControls(
              adapter: controller,
              isFullscreen: false,
              onToggleFullscreen: ({required bool keepControls}) {},
              markers: cues,
            ),
          ),
        ),
      );
      await tester.pump();

      // Change the speed, which starts the watch that re-asserts playback for
      // several seconds afterwards.
      await tester.tapAt(tester.getCenter(find.byType(PlayerControls)));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byIcon(Icons.settings_rounded));
      // Settled, not merely pumped: the sheet slides up from below the player,
      // so a tap aimed at a row mid-animation lands off the bottom of it.
      await tester.pumpAndSettle();
      await tester.tap(find.text('Playback speed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.5x'));
      await tester.pump();
      controller.calls.clear();

      play(controller, const Duration(seconds: 5));
      await tester.pump();
      expect(cues.active, cue);

      // Several rounds of the watch, all of them under the overlay.
      await tester.pump(const Duration(seconds: 1));
      expect(controller.calls, isNot(contains('play')));
      expect(controller.isPlaying, isFalse);
      expect(cues.active, cue, reason: 'the cue runs its own length');

      await tester.pump(const Duration(seconds: 3));
      expect(cues.active, isNull);
      expect(controller.isPlaying, isTrue);

      // Ends the watch, so nothing is left pending past the test.
      controller.isFinished = true;
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('covers the controls until the cue is skipped', (tester) async {
      final controller = FakePlaybackAdapter();
      final cues = attach(controller);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerControls(
              adapter: controller,
              isFullscreen: false,
              onToggleFullscreen: ({required bool keepControls}) {},
              markers: cues,
            ),
          ),
        ),
      );
      await tester.pump();

      play(controller, const Duration(seconds: 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Sample cue'), findsOneWidget);
      expect(find.text('Sample body'), findsOneWidget);
      // The controls stay down behind the scrim rather than coming up for the
      // pause the cue made.
      final controlLayer = tester.widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.byType(VideoProgressBar),
              matching: find.byType(AnimatedOpacity),
            )
            .last,
      );
      expect(controlLayer.opacity, 0);

      await tester.tap(find.text('Skip'));
      await tester.pump();

      expect(find.text('Sample cue'), findsNothing);
      expect(controller.isPlaying, isTrue);
    });
  });

  group('scrub preview', () {
    final frameBytes = Uint8List.fromList([1, 2, 3]);

    /// Records what it was asked for and answers on demand, so a test can hold
    /// an extraction open the way a slow decode does.
    ({ScrubPreview preview, List<Duration> asked, void Function() finish})
    build({
      Duration duration = const Duration(minutes: 10),
      bool fail = false,
    }) {
      final asked = <Duration>[];
      final waiting = <Completer<Uint8List?>>[];
      final preview = ScrubPreview(
        videoUrl: 'video.mp4',
        duration: duration,
        extractor: (video, at, headers) {
          asked.add(at);
          final completer = Completer<Uint8List?>();
          waiting.add(completer);
          return completer.future;
        },
      );
      return (
        preview: preview,
        asked: asked,
        finish: () {
          for (final completer in waiting) {
            if (!completer.isCompleted) {
              completer.complete(fail ? null : frameBytes);
            }
          }
          waiting.clear();
        },
      );
    }

    test('drops everything the finger passed over mid-decode', () async {
      final f = build();
      addTearDown(f.preview.dispose);

      // One decode is in flight from the first request; the next three land
      // while it runs and only the last of them should survive.
      f.preview.request(const Duration(seconds: 10));
      f.preview.request(const Duration(minutes: 2));
      f.preview.request(const Duration(minutes: 4));
      f.preview.request(const Duration(minutes: 6));
      expect(f.asked, hasLength(1));

      f.finish();
      await pumpEventQueue();
      f.finish();
      await pumpEventQueue();

      expect(f.asked, hasLength(2));
      expect(f.asked.last, const Duration(minutes: 6));
      expect(f.preview.frame.value, frameBytes);
    });

    test('snaps nearby positions onto one frame and reuses it', () async {
      final f = build();
      addTearDown(f.preview.dispose);

      f.preview.request(const Duration(seconds: 30));
      f.finish();
      await pumpEventQueue();
      expect(f.asked, hasLength(1));

      // Close enough to land in the same slot: served from what is already
      // held, with no second decode.
      f.preview.request(const Duration(seconds: 31));
      await pumpEventQueue();
      expect(f.asked, hasLength(1));
      expect(f.preview.frame.value, frameBytes);

      // Far enough away to be its own frame.
      f.preview.request(const Duration(minutes: 5));
      expect(f.asked, hasLength(2));
    });

    test('gives up on a source that keeps refusing', () async {
      final f = build(fail: true);
      addTearDown(f.preview.dispose);

      for (var i = 1; i <= 4; i++) {
        f.preview.request(Duration(minutes: i));
        f.finish();
        await pumpEventQueue();
      }

      expect(f.preview.unavailable, isTrue);
      expect(f.preview.frame.value, isNull);

      final soFar = f.asked.length;
      f.preview.request(const Duration(minutes: 9));
      expect(f.asked, hasLength(soFar));
    });
  });

  group('scrub bubble', () {
    const barWidth = 300.0;

    Future<Rect> pumpBar(
      WidgetTester tester, {
      required double value,
      required bool dragging,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: barWidth,
                child: VideoProgressBar(
                  value: value,
                  buffered: 1,
                  accentColor: const Color(0xFFFF3B30),
                  isDragging: dragging,
                  scrubLabel: '1:23',
                  onSeekStart: (_) {},
                  onSeekUpdate: (_) {},
                  onSeekEnd: () {},
                ),
              ),
            ),
          ),
        ),
      );
      return tester.getRect(find.byType(VideoProgressBar));
    }

    testWidgets('shows only while scrubbing', (tester) async {
      await pumpBar(tester, value: 0.5, dragging: false);
      expect(find.text('1:23'), findsNothing);

      await pumpBar(tester, value: 0.5, dragging: true);
      expect(find.text('1:23'), findsOneWidget);
    });

    testWidgets('sits above the track, centred on the thumb', (tester) async {
      final bar = await pumpBar(tester, value: 0.5, dragging: true);
      final bubble = tester.getRect(find.text('1:23'));

      expect(bubble.bottom, lessThan(bar.top));
      expect(bubble.center.dx, closeTo(bar.center.dx, 1));
    });

    testWidgets('stays inside the bar at both ends', (tester) async {
      final bar = await pumpBar(tester, value: 0, dragging: true);
      expect(
        tester.getRect(find.byType(VideoProgressBar)).left,
        lessThanOrEqualTo(tester.getRect(find.text('1:23')).left),
      );

      await pumpBar(tester, value: 1, dragging: true);
      expect(
        tester.getRect(find.text('1:23')).right,
        lessThanOrEqualTo(bar.right),
      );
    });
  });

  group('loading fullscreen page', () {
    Future<void> pump(WidgetTester tester, {bool failed = false}) async {
      tester.view.physicalSize = const Size(800, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: LoadingFullscreenPage(
            accentColor: const Color(0xFFFF3B30),
            title: 'A video',
            sourceFailed: ValueNotifier<bool>(failed),
          ),
        ),
      );
    }

    testWidgets('keeps the top bar at the top, not down the middle', (
      tester,
    ) async {
      await pump(tester);

      // The bar's own Row will happily fill a tight full-screen height and
      // centre its contents in it, which put the back button and title across
      // the middle of the screen.
      final back = tester.getRect(find.byType(IconButton));
      expect(back.bottom, lessThan(tester.view.physicalSize.height / 4));
      expect(
        tester.getRect(find.text('A video')).center.dy,
        lessThan(tester.view.physicalSize.height / 4),
      );
    });

    testWidgets('shows a loader while resolving and the failure after', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await pump(tester, failed: true);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining("couldn't be loaded"), findsOneWidget);
    });
  });

  group('fullscreen swipe', () {
    DragEndDetails swipe(double velocity) => DragEndDetails(
      primaryVelocity: velocity,
      velocity: Velocity(pixelsPerSecond: Offset(0, velocity)),
    );

    test('reads a fast swipe up as entering and down as leaving', () {
      expect(fullscreenIntentFromSwipe(swipe(-900)), isTrue);
      expect(fullscreenIntentFromSwipe(swipe(900)), isFalse);
    });

    test('ignores a drag too slow to have been meant as a swipe', () {
      expect(fullscreenIntentFromSwipe(swipe(-120)), isNull);
      expect(fullscreenIntentFromSwipe(swipe(0)), isNull);
    });
  });
}
