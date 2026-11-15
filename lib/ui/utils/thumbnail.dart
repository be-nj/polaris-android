import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:polaris/core/cache/media.dart';
import 'package:polaris/core/client/app_client.dart';
import 'package:polaris/ui/utils/fallback_artwork.dart';

final getIt = GetIt.instance;

class Thumbnail extends StatefulWidget {
  final String? path;
  final ArtworkSize size;

  /// What to show when there is no image
  final Widget fallback;

  const Thumbnail(this.path, this.size, {this.fallback = const FallbackArtwork(), Key? key}) : super(key: key);

  @override
  State<Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<Thumbnail> {
  Future<Uint8List?>? futureImage;

  @override
  void initState() {
    super.initState();
    _fetchImage();
  }

  @override
  void didUpdateWidget(Thumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      setState(() {
        _fetchImage();
      });
    }
  }

  void _fetchImage() {
    String? path = widget.path;
    if (path != null) {
      futureImage = getIt<AppClient>().getImage(path, widget.size);
    } else {
      futureImage = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: futureImage,
      builder: (context, snapshot) {
        switch (snapshot.connectionState) {
          case ConnectionState.none:
            return widget.fallback;
          case ConnectionState.waiting:
          case ConnectionState.active:
            return Container();
          case ConnectionState.done:
            if (!snapshot.hasData || snapshot.data == null) {
              return widget.fallback;
            }
            return Image.memory(
              snapshot.data!,
              fit: BoxFit.cover,
            );
        }
      },
    );
  }
}

class LargeThumbnail extends StatelessWidget {
  final String? path;

  const LargeThumbnail(this.path, {Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8.0),
      child: AspectRatio(
        aspectRatio: 1.0,
        child: Thumbnail(path, ArtworkSize.small),
      ),
    );
  }
}

class ListThumbnail extends StatelessWidget {
  final String? path;

  const ListThumbnail(this.path, {Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4.0),
      child: SizedBox(
        width: 44,
        height: 44,
        child: Thumbnail(path, ArtworkSize.tiny),
      ),
    );
  }
}

/// Round picture of an artist. Artists without a picture are shown as an icon.
class ArtistThumbnail extends StatelessWidget {
  final String? path;
  final double size;

  const ArtistThumbnail(this.path, {this.size = 36, Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      color: Theme.of(context).textTheme.labelSmall?.color?.withValues(alpha: 0.1),
      alignment: Alignment.center,
      child: Icon(Icons.person, size: size * 2 / 3),
    );
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: Thumbnail(path, ArtworkSize.tiny, fallback: placeholder),
      ),
    );
  }
}
