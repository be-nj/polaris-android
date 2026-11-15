import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:polaris/core/cache/media.dart';
import 'package:polaris/core/client/app_client.dart';
import 'package:polaris/core/client/api/v8_dto.dart' as dto;
import 'package:polaris/ui/utils/thumbnail.dart';

const artistJson = {
  'name': 'Khemmis',
  'num_albums_as_performer': 1,
  'num_albums_as_additional_performer': 0,
  'num_albums_as_composer': 0,
  'num_albums_as_lyricist': 0,
  'num_songs_by_genre': {'Metal': 5},
  'num_songs': 5,
};

class FakeAppClient extends Mock implements AppClient {}

/// Smallest valid PNG image
final Uint8List transparentPixel =
    base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');

void main() {
  setUpAll(() => registerFallbackValue(ArtworkSize.small));

  test('Reads pictures of artists', () {
    final artist = dto.ArtistHeader.fromJson({...artistJson, 'artwork': 'music/Khemmis/artist.jpg'});
    expect(artist.name, equals('Khemmis'));
    expect(artist.artwork, equals('music/Khemmis/artist.jpg'));

    final details = dto.Artist.fromJson({...artistJson, 'artwork': 'music/Khemmis/artist.jpg', 'albums': []});
    expect(details.artwork, equals('music/Khemmis/artist.jpg'));
  });

  test('Artists have no picture on servers which do not provide any', () {
    expect(dto.ArtistHeader.fromJson(artistJson).artwork, isNull);
    expect(dto.Artist.fromJson({...artistJson, 'albums': []}).artwork, isNull);
  });

  testWidgets('Artists without picture are shown as an icon', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: Center(child: ArtistThumbnail(null))));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.person), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(tester.getSize(find.byType(ArtistThumbnail)), equals(const Size(36, 36)));
  });

  testWidgets('Artists whose picture cannot be loaded are shown as an icon', (WidgetTester tester) async {
    final client = FakeAppClient();
    when(() => client.getImage(any(), any())).thenAnswer((_) async => null);
    GetIt.instance.allowReassignment = true;
    GetIt.instance.registerSingleton<AppClient>(client);

    await tester.pumpWidget(const MaterialApp(home: Center(child: ArtistThumbnail('music/Nobody/artist.jpg'))));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.person), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    verify(() => client.getImage('music/Nobody/artist.jpg', ArtworkSize.small)).called(1);
  });

  testWidgets('Artists with a picture are shown with it', (WidgetTester tester) async {
    final client = FakeAppClient();
    when(() => client.getImage(any(), any())).thenAnswer((_) async => transparentPixel);
    GetIt.instance.allowReassignment = true;
    GetIt.instance.registerSingleton<AppClient>(client);

    await tester.pumpWidget(const MaterialApp(home: Center(child: ArtistThumbnail('music/Khemmis/artist.jpg'))));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.person), findsNothing);
    // Pictures are round
    expect(find.ancestor(of: find.byType(Image), matching: find.byType(ClipOval)), findsOneWidget);
  });
}
