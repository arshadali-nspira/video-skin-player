import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_11/main.dart';
import 'package:flutter_application_11/player/video_source.dart';
import 'package:flutter_application_11/player/youtube_link.dart';

void main() {
  testWidgets('home screen shows the link field and samples', (tester) async {
    await tester.pumpWidget(const VideoApp());

    expect(find.text('Play a video'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Me at the zoo'), findsOneWidget);
    expect(find.text('Big Buck Bunny (MP4)'), findsOneWidget);
  });

  testWidgets('an invalid link is rejected instead of opening the player', (
    tester,
  ) async {
    await tester.pumpWidget(const VideoApp());

    await tester.enterText(find.byType(TextField), 'not-a-link');
    await tester.tap(find.text('Play'));
    await tester.pump();

    expect(
      find.text('Enter a YouTube link, video ID, or media URL.'),
      findsOneWidget,
    );
  });


  group('link parsing', () {
    const id = 'jNQXAC9IVRw';

    test('accepts the common YouTube link shapes', () {
      for (final url in [
        'https://www.youtube.com/watch?v=$id',
        'https://youtu.be/$id',
        'https://www.youtube.com/embed/$id',
        'https://youtube.com/shorts/$id',
        'https://m.youtube.com/watch?v=$id&t=30s',
        'youtube.com/watch?v=$id',
        id,
      ]) {
        expect(youtubeVideoId(url), id, reason: url);
      }
    });

    test('rejects a non-YouTube link', () {
      expect(youtubeVideoId('https://example.com/video'), isNull);
      expect(youtubeVideoId('not-a-link'), isNull);
      expect(youtubeVideoId(''), isNull);
    });

    test('expands a bare ID into a watch link and leaves links alone', () {
      expect(youtubeWatchUrl(id), 'https://www.youtube.com/watch?v=$id');
      expect(youtubeWatchUrl('https://youtu.be/$id'), 'https://youtu.be/$id');
    });
  });

  group('source classification', () {
    test('routes YouTube links and bare IDs to the YouTube source', () {
      for (final input in [
        'https://www.youtube.com/watch?v=jNQXAC9IVRw',
        'https://youtu.be/jNQXAC9IVRw',
        'jNQXAC9IVRw',
      ]) {
        expect(
          classifyVideoInput(input),
          VideoSourceKind.youtube,
          reason: input,
        );
      }
    });

    test('routes direct media URLs to the network source', () {
      for (final input in [
        'http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
        'https://example.com/stream/master.m3u8',
        'https://example.com/clip.webm',
      ]) {
        expect(
          classifyVideoInput(input),
          VideoSourceKind.network,
          reason: input,
        );
      }
    });

    // A YouTube watch page is also a perfectly good http URL. Handing it to the
    // network player would try to decode the HTML, so YouTube has to win.
    test('prefers YouTube over network for a youtube.com URL', () {
      expect(
        classifyVideoInput('http://youtube.com/watch?v=jNQXAC9IVRw'),
        VideoSourceKind.youtube,
      );
    });

    test('rejects what is not a URL at all', () {
      for (final input in [
        '',
        '   ',
        'not-a-link',
        'ftp://example.com/a.mp4',
      ]) {
        expect(classifyVideoInput(input), isNull, reason: '"$input"');
      }
    });
  });
}