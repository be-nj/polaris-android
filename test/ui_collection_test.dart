import 'harness.dart';
import 'mock/http_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:polaris/core/pin.dart' as pin;
import 'package:polaris/core/playlist.dart';
import 'package:polaris/ui/strings.dart';
import 'package:polaris/main.dart';
import 'package:polaris/ui/collection/browser.dart';

final rootDirectory = find.text(rootDirectoryName);
final heronDirectory = find.text(heronDirectoryName);
final aegeusDirectory = find.text(aegeusDirectoryName);
final labyrinthSong = find.text('$labyrinthSongName.mp3');
final fallInwardsSong = find.text('$fallInwardsSongName.mp3');
final rootBreadcrumb = find.widgetWithText(Breadcrumb, rootDirectoryName);
final heronBreadcrumb = find.widgetWithText(Breadcrumb, heronDirectoryName);
final aegeusBreadcrumb = find.widgetWithText(Breadcrumb, aegeusDirectoryName);

void main() {
  songInteractionTests();

  testWidgets('Shows browse tab on start', (WidgetTester tester) async {
    await Harness.reconnect();
    await tester.pumpWidget(const PolarisApp());
    await tester.pumpAndSettle();
    expect(rootDirectory, findsOneWidget);
  });

  testWidgets('Can open browser directories', (WidgetTester tester) async {
    await Harness.reconnect();
    await tester.pumpWidget(const PolarisApp());

    await tester.pumpAndSettle();
    expect(rootDirectory, findsOneWidget);
    expect(heronDirectory, findsNothing);
    expect(aegeusDirectory, findsNothing);

    await tester.tap(rootDirectory);
    await tester.pumpAndSettle();
    expect(heronDirectory, findsOneWidget);
    expect(aegeusDirectory, findsNothing);

    await tester.tap(heronDirectory);
    await tester.pumpAndSettle();
    expect(aegeusDirectory, findsOneWidget);
  });

  testWidgets('Browser shows breadcrumbs', (WidgetTester tester) async {
    await Harness.reconnect();
    await tester.pumpWidget(const PolarisApp());
    await tester.pumpAndSettle();

    await tester.tap(rootDirectory);
    await tester.pumpAndSettle();

    expect(heronBreadcrumb, findsNothing);
    await tester.tap(heronDirectory);
    await tester.pumpAndSettle();
    expect(heronBreadcrumb, findsNothing);

    await tester.tap(aegeusDirectory);
    await tester.pumpAndSettle();
    expect(heronBreadcrumb, findsOneWidget);
  });

  testWidgets('Can navigate backwards using browser breadcrumbs', (WidgetTester tester) async {
    await Harness.reconnect();
    await tester.pumpWidget(const PolarisApp());
    await tester.pumpAndSettle();

    await tester.tap(rootDirectory);
    await tester.pumpAndSettle();

    await tester.tap(heronDirectory);
    await tester.pumpAndSettle();

    expect(aegeusDirectory, findsOneWidget);
    await tester.tap(rootDirectory);
    await tester.pumpAndSettle();
    expect(aegeusDirectory, findsNothing);
  });
}

/// Records what the user interface asks to play.
class RecordingPlaylist extends Mock implements Playlist {
  final List<(List<String>, int)> playedNow = [];
  final List<List<String>> queuedNext = [];
  final List<List<String>> queuedLast = [];

  @override
  Future playNow(List<String> songs, {int startIndex = 0}) async {
    playedNow.add((songs, startIndex));
  }

  @override
  Future queueNext(List<String> songs) async {
    queuedNext.add(songs);
  }

  @override
  Future queueLast(List<String> songs, {bool autoPlay = true}) async {
    queuedLast.add(songs);
  }
}

class FakePinManager extends Mock implements pin.Manager {}

/// Menus tell whether their song or directory is available offline, which the test harness has no answer for.
void registerPinManager() {
  final pinManager = FakePinManager();
  when(() => pinManager.isSongPinned(any(), any())).thenReturn(false);
  when(() => pinManager.isDirectoryPinned(any(), any())).thenReturn(false);
  GetIt.instance.registerSingleton<pin.Manager>(pinManager);
}

/// The font used by tests is much wider than real ones, which makes the labels of menus overflow.
void shrinkText(WidgetTester tester) {
  tester.platformDispatcher.textScaleFactorTestValue = 0.5;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<RecordingPlaylist> openAegeusDirectory(WidgetTester tester) async {
  shrinkText(tester);
  await Harness.reconnect();
  registerPinManager();
  final playlist = RecordingPlaylist();
  GetIt.instance.registerSingleton<Playlist>(playlist);

  await tester.pumpWidget(const PolarisApp());
  await tester.pumpAndSettle();
  for (final directory in [rootDirectory, heronDirectory, aegeusDirectory]) {
    await tester.tap(directory);
    await tester.pumpAndSettle();
  }
  expect(labyrinthSong, findsOneWidget);
  expect(fallInwardsSong, findsOneWidget);
  return playlist;
}

void songInteractionTests() {
  testWidgets('Tapping a song plays its directory from that song', (WidgetTester tester) async {
    final playlist = await openAegeusDirectory(tester);

    await tester.tap(fallInwardsSong);
    await tester.pumpAndSettle();
    expect(playlist.playedNow.length, equals(1));
    expect(playlist.playedNow.last.$1, equals([labyrinthFilePath, fallInwardsFilePath]));
    expect(playlist.playedNow.last.$2, equals(1));

    await tester.tap(labyrinthSong);
    await tester.pumpAndSettle();
    expect(playlist.playedNow.length, equals(2));
    expect(playlist.playedNow.last.$1, equals([labyrinthFilePath, fallInwardsFilePath]));
    expect(playlist.playedNow.last.$2, equals(0));
    expect(playlist.queuedLast, isEmpty);
    expect(playlist.queuedNext, isEmpty);
  });

  testWidgets('Pressing a song for a long time opens its menu', (WidgetTester tester) async {
    final playlist = await openAegeusDirectory(tester);
    expect(find.text(contextMenuQueueNext), findsNothing);

    await tester.longPress(fallInwardsSong);
    await tester.pumpAndSettle();
    expect(find.text(contextMenuPlayNow), findsOneWidget);
    expect(find.text(contextMenuQueueNext), findsOneWidget);
    expect(find.text(contextMenuQueueLast), findsOneWidget);
    // Opening the menu does not play anything by itself
    expect(playlist.playedNow, isEmpty);

    await tester.tap(find.text(contextMenuQueueNext));
    await tester.pumpAndSettle();
    expect(
        playlist.queuedNext,
        equals([
          [fallInwardsFilePath]
        ]));
    expect(playlist.playedNow, isEmpty);
    expect(find.text(contextMenuQueueNext), findsNothing);
  });

  testWidgets('The menu button of a song still opens its menu', (WidgetTester tester) async {
    final playlist = await openAegeusDirectory(tester);

    final labyrinthEntry = find.widgetWithText(ListTile, '$labyrinthSongName.mp3');
    await tester.tap(find.descendant(of: labyrinthEntry, matching: find.byIcon(Icons.more_vert)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(contextMenuQueueLast));
    await tester.pumpAndSettle();
    expect(
        playlist.queuedLast,
        equals([
          [labyrinthFilePath]
        ]));
    expect(playlist.playedNow, isEmpty);
  });

  testWidgets('Pressing a directory for a long time opens its menu', (WidgetTester tester) async {
    shrinkText(tester);
    await Harness.reconnect();
    registerPinManager();
    await tester.pumpWidget(const PolarisApp());
    await tester.pumpAndSettle();

    await tester.longPress(rootDirectory);
    await tester.pumpAndSettle();
    expect(find.text(contextMenuPlayNow), findsOneWidget);
    // The directory was not opened
    expect(heronDirectory, findsNothing);
  });
}
