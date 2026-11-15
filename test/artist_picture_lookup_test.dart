import 'harness.dart';
import 'mock/http_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:polaris/core/cleanup.dart' as cleanup;
import 'package:polaris/core/prefetch.dart' as prefetch;
import 'package:polaris/ui/utils/thumbnail.dart';

const unportrayedArtistName = 'Aegeus';

Iterable<Uri> pictureRequests(Harness harness, String artistName) {
  return harness.mockHTTPClient.requestedURLs.where((u) => u.path == '/api/artist/$artistName/thumbnail');
}

// Stops the background work of the app, as closing the app does
void stopBackgroundWork() {
  GetIt.instance<prefetch.Manager>().dispose();
  GetIt.instance<cleanup.Manager>().dispose();
}

// Shows an artist the collection has no picture of
Future<void> showArtist(WidgetTester tester, String artistName) async {
  final thumbnail = ArtistThumbnail(null, artistName: artistName, key: UniqueKey());
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: thumbnail))));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Shows the picture the server found of an artist', (WidgetTester tester) async {
    final harness = await Harness.reconnect();
    await tester.pumpAndSettle();

    await showArtist(tester, portrayedArtistName);

    expect(pictureRequests(harness, portrayedArtistName), hasLength(1));
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.person), findsNothing);

    stopBackgroundWork();
  });

  testWidgets('Shows an icon for artists the server found no picture of', (WidgetTester tester) async {
    final harness = await Harness.reconnect();
    await tester.pumpAndSettle();

    await showArtist(tester, unportrayedArtistName);

    expect(pictureRequests(harness, unportrayedArtistName), hasLength(1));
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.person), findsOneWidget);

    stopBackgroundWork();
  });

  testWidgets('Asks only once for a picture the server does not have', (WidgetTester tester) async {
    final harness = await Harness.reconnect();
    await tester.pumpAndSettle();

    const artistName = 'Labyrinth';
    await showArtist(tester, artistName);
    await showArtist(tester, artistName);

    expect(pictureRequests(harness, artistName), hasLength(1));
    expect(find.byIcon(Icons.person), findsOneWidget);

    stopBackgroundWork();
  });
}
