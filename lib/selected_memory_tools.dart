import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

/// New local-first memory tools. No OCR or cloud service is used here.
class NaturalLanguageSearchPage extends StatefulWidget {
  final List<AssetEntity> photos;
  final Map<String, String> names;
  final Map<String, String> captions;
  final Map<String, Set<String>> tags;
  final Set<String> favorites;

  const NaturalLanguageSearchPage({
    super.key,
    required this.photos,
    required this.names,
    required this.captions,
    required this.tags,
    required this.favorites,
  });

  @override
  State<NaturalLanguageSearchPage> createState() => _NaturalLanguageSearchPageState();
}

class _NaturalLanguageSearchPageState extends State<NaturalLanguageSearchPage> {
  String query = '';

  List<AssetEntity> get results {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return widget.photos;
    final yearMatch = RegExp(r'\b(19\d{2}|20\d{2})\b').firstMatch(q);
    final year = yearMatch?.group(0);
    final tokens = q
        .replaceAll(RegExp(r'\b(photos?|pictures?|memories|show|find|me|from|in|the|with|of|at|on)\b'), ' ')
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty && part != year)
        .toList();
    return widget.photos.where((asset) {
      if (year != null && asset.createDateTime.year.toString() != year) return false;
      if (q.contains('favorite') && !widget.favorites.contains(asset.id)) return false;
      final metadata = [
        widget.names[asset.id] ?? '',
        asset.title ?? '',
        widget.captions[asset.id] ?? '',
        ...(widget.tags[asset.id] ?? <String>{}),
        asset.createDateTime.toIso8601String(),
      ].join(' ').toLowerCase();
      return tokens.isEmpty || tokens.every(metadata.contains);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final items = results;
    return Scaffold(
      appBar: AppBar(title: const Text('Natural-Language Search')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            onChanged: (value) => setState(() => query = value),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: 'Try “birthday photos from 2024”',
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(onPressed: () => setState(() => query = ''), icon: const Icon(Icons.clear)),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Private and offline: searches filenames, captions, tags, dates, and favorites. Visual-concept matching such as “beach at sunset” needs a separate on-device vision model and is not claimed here.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('${items.length} matching memories', style: Theme.of(context).textTheme.titleSmall),
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('No matching memories. Try a date, caption, filename, or tag.'))
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3, crossAxisSpacing: 5, mainAxisSpacing: 5,
                  ),
                  itemCount: items.length,
                  itemBuilder: (_, index) => _AssetThumbnail(asset: items[index]),
                ),
        ),
      ]),
    );
  }
}

class ThreeDMemoryCardsPage extends StatefulWidget {
  final List<AssetEntity> photos;
  final Map<String, String> names;
  final Map<String, String> captions;

  const ThreeDMemoryCardsPage({
    super.key,
    required this.photos,
    required this.names,
    required this.captions,
  });

  @override
  State<ThreeDMemoryCardsPage> createState() => _ThreeDMemoryCardsPageState();
}

class _ThreeDMemoryCardsPageState extends State<ThreeDMemoryCardsPage> {
  int index = 0;
  double tiltX = 0;
  double tiltY = 0;

  void _step(int delta) {
    if (widget.photos.isEmpty) return;
    setState(() {
      index = (index + delta + widget.photos.length) % widget.photos.length;
      tiltX = 0;
      tiltY = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.photos.isEmpty) {
      return Scaffold(appBar: AppBar(title: const Text('3D Memory Cards')), body: const Center(child: Text('No photos available.')));
    }
    final asset = widget.photos[index];
    final name = widget.names[asset.id] ?? asset.title ?? 'A little memory';
    final caption = widget.captions[asset.id] ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('3D Memory Cards')),
      body: Column(children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Text('Drag the card gently to tilt it. This is a visual depth effect; the original photo is unchanged.'),
        ),
        Expanded(
          child: Center(
            child: GestureDetector(
              onPanUpdate: (details) => setState(() {
                tiltY = (tiltY + details.delta.dx * 0.008).clamp(-0.28, 0.28);
                tiltX = (tiltX - details.delta.dy * 0.006).clamp(-0.2, 0.2);
              }),
              onPanEnd: (_) => setState(() { tiltX = 0; tiltY = 0; }),
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0015)
                  ..rotateX(tiltX)
                  ..rotateY(tiltY),
                child: Container(
                  width: 300,
                  height: 420,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.22), blurRadius: 28, offset: const Offset(0, 18)),
                    ],
                    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(children: [
                    Expanded(child: _AssetThumbnail(asset: asset, fit: BoxFit.cover)),
                    Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                        if (caption.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(caption, maxLines: 3, overflow: TextOverflow.ellipsis),
                        ],
                        const SizedBox(height: 8),
                        Text(asset.createDateTime.toLocal().toString().split(' ').first, style: Theme.of(context).textTheme.bodySmall),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            IconButton.filledTonal(onPressed: () => _step(-1), icon: const Icon(Icons.chevron_left), tooltip: 'Previous memory'),
            Text('${index + 1} / ${widget.photos.length}'),
            IconButton.filledTonal(onPressed: () => _step(1), icon: const Icon(Icons.chevron_right), tooltip: 'Next memory'),
          ]),
        ),
      ]),
    );
  }
}

enum _ScreenshotKind { screenshot, receiptOrTicket, memeOrDownload, other }

_ScreenshotKind _classifyAsset(AssetEntity asset) {
  final title = (asset.title ?? '').toLowerCase();
  if (RegExp(r'(screenshot|screen_shot|screen-shot|screen capture)').hasMatch(title)) {
    return _ScreenshotKind.screenshot;
  }
  if (RegExp(r'(receipt|invoice|ticket|boarding|booking|bill)').hasMatch(title)) {
    return _ScreenshotKind.receiptOrTicket;
  }
  if (RegExp(r'(meme|whatsapp|telegram|download|shared)').hasMatch(title)) {
    return _ScreenshotKind.memeOrDownload;
  }
  final width = asset.width;
  final height = asset.height;
  if (width > 0 && height > 0 && height > width && width <= 1440 && height <= 3200) {
    return _ScreenshotKind.screenshot;
  }
  return _ScreenshotKind.other;
}

class ScreenshotIntelligencePage extends StatefulWidget {
  final List<AssetEntity> photos;
  const ScreenshotIntelligencePage({super.key, required this.photos});

  @override
  State<ScreenshotIntelligencePage> createState() => _ScreenshotIntelligencePageState();
}

class _ScreenshotIntelligencePageState extends State<ScreenshotIntelligencePage> {
  int filter = 0;
  @override
  Widget build(BuildContext context) {
    final classified = widget.photos.map((asset) => (asset, _classifyAsset(asset))).toList();
    final visible = classified.where((item) => filter == 0 || item.$2.index == filter - 1).toList();
    const labels = ['All groups', 'Screenshots', 'Receipts & tickets', 'Memes & downloads', 'Other'];
    return Scaffold(
      appBar: AppBar(title: const Text('Screenshot Intelligence')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: DropdownButtonFormField<int>(
            value: filter,
            decoration: const InputDecoration(labelText: 'Suggested category'),
            items: List.generate(labels.length, (i) => DropdownMenuItem(value: i, child: Text(labels[i]))),
            onChanged: (value) => setState(() => filter = value ?? 0),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('Local suggestions based on filenames and image dimensions. No OCR is used; classifications can be wrong, so this page never deletes or moves files automatically.'),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: visible.isEmpty
              ? const Center(child: Text('No items in this category.'))
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 5, mainAxisSpacing: 5),
                  itemCount: visible.length,
                  itemBuilder: (_, i) => _AssetThumbnail(asset: visible[i].$1),
                ),
        ),
      ]),
    );
  }
}

class MetadataInspectorPage extends StatefulWidget {
  final List<AssetEntity> photos;
  const MetadataInspectorPage({super.key, required this.photos});

  @override
  State<MetadataInspectorPage> createState() => _MetadataInspectorPageState();
}

class _MetadataInspectorPageState extends State<MetadataInspectorPage> {
  bool busy = false;
  String? status;

  Future<void> _exportCleanCopy(AssetEntity asset) async {
    if (busy) return;
    setState(() { busy = true; status = null; });
    Directory? temp;
    try {
      final source = await asset.file;
      if (source == null || !await source.exists()) throw StateError('Local original file is unavailable.');
      if (await source.length() > 40 * 1024 * 1024) throw StateError('This file exceeds the 40 MB safety limit.');
      final bytes = await source.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw FormatException('This format cannot be re-encoded by the local metadata cleaner.');
      final upright = img.bakeOrientation(decoded);
      final ext = (source.path.split('.').last.toLowerCase() == 'png') ? 'png' : 'jpg';
      final cleanBytes = ext == 'png' ? img.encodePng(upright) : img.encodeJpg(upright, quality: 95);
      // Re-encoding creates a new file and does not carry the source EXIF block.
      temp = await Directory.systemTemp.createTemp('little_memories_clean_export_');
      final output = File('${temp.path}/LittleMemories_clean_${DateTime.now().millisecondsSinceEpoch}.$ext');
      await output.writeAsBytes(cleanBytes, flush: true);
      final saved = await PhotoManager.editor.saveImage(
        Uint8List.fromList(cleanBytes),
        filename: 'LittleMemories_clean_${DateTime.now().millisecondsSinceEpoch}.$ext',
        title: 'Metadata-clean copy',
        relativePath: 'Pictures/Little Memories',
      );
      final savedFile = await saved.file;
      if (savedFile == null || !await savedFile.exists()) throw StateError('Clean copy saved but could not be opened for sharing.');
      await Share.shareXFiles([XFile(savedFile.path)], text: 'Metadata-clean copy created by Little Memories. Original preserved.');
      if (mounted) setState(() => status = 'A separate cleaned copy was created. The original is unchanged.');
    } catch (error) {
      if (mounted) setState(() => status = 'Could not create a cleaned copy: ${error.toString()}');
    } finally {
      if (temp != null && await temp.exists()) await temp.delete(recursive: true);
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy & Metadata Inspector')),
      body: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: widget.photos.length + 1,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.all(8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Review basic photo metadata and create a re-encoded copy that omits source EXIF metadata. The original is never modified. Unsupported formats may fail safely.'),
                if (status != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(status!)),
                if (busy) const LinearProgressIndicator(),
              ]),
            );
          }
          final asset = widget.photos[index - 1];
          return ListTile(
            leading: SizedBox(width: 52, height: 52, child: _AssetThumbnail(asset: asset)),
            title: Text(asset.title?.isNotEmpty == true ? asset.title! : 'Photo', maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${asset.width} × ${asset.height} • ${asset.createDateTime.toLocal()}\n${asset.mimeType ?? 'Unknown format'}'),
            isThreeLine: true,
            trailing: IconButton(
              tooltip: 'Create metadata-clean copy',
              onPressed: busy ? null : () => _exportCleanCopy(asset),
              icon: const Icon(Icons.privacy_tip_outlined),
            ),
          );
        },
      ),
    );
  }
}

class StorageHealthPage extends StatefulWidget {
  final List<AssetEntity> photos;
  final List<AssetEntity> videos;
  const StorageHealthPage({super.key, required this.photos, required this.videos});

  @override
  State<StorageHealthPage> createState() => _StorageHealthPageState();
}

class _StorageHealthPageState extends State<StorageHealthPage> {
  bool scanning = false;
  int scanned = 0;
  int totalBytes = 0;
  List<(AssetEntity, int)> largest = [];
  String? error;

  String _size(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  Future<void> _scan() async {
    if (scanning) return;
    setState(() { scanning = true; scanned = 0; totalBytes = 0; largest = []; error = null; });
    final all = [...widget.photos, ...widget.videos];
    final found = <(AssetEntity, int)>[];
    try {
      for (var i = 0; i < all.length; i++) {
        final file = await all[i].file;
        if (file != null && await file.exists()) {
          final size = await file.length();
          totalBytes += size;
          found.add((all[i], size));
        }
        if ((i + 1) % 25 == 0 || i + 1 == all.length) {
          if (mounted) setState(() { scanned = i + 1; });
          await Future<void>.delayed(Duration.zero);
        }
      }
      found.sort((a, b) => b.$2.compareTo(a.$2));
      if (mounted) setState(() { largest = found.take(30).toList(); scanned = all.length; });
    } catch (_) {
      if (mounted) setState(() => error = 'Some files could not be measured. The scan may be incomplete.');
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.photos.length + widget.videos.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Storage Health Center'), actions: [
        IconButton(onPressed: scanning ? null : _scan, icon: const Icon(Icons.refresh), tooltip: 'Rescan'),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Estimated media size', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(_size(totalBytes), style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
            Text('$scanned of $count files checked'),
            if (scanning) ...[const SizedBox(height: 10), LinearProgressIndicator(value: count == 0 ? null : scanned / count.clamp(1, count))],
            if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          ]),
        )),
        const SizedBox(height: 12),
        Text('Largest files', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (largest.isEmpty && !scanning) const Text('No file sizes available.'),
        ...largest.map((entry) => ListTile(
          contentPadding: EdgeInsets.zero,
          leading: SizedBox(width: 52, height: 52, child: _AssetThumbnail(asset: entry.$1)),
          title: Text(entry.$1.title?.isNotEmpty == true ? entry.$1.title! : (entry.$1.type == AssetType.video ? 'Video' : 'Photo'), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${entry.$1.width} × ${entry.$1.height}'),
          trailing: Text(_size(entry.$2), style: const TextStyle(fontWeight: FontWeight.w800)),
        )),
        const SizedBox(height: 12),
        const Text('This is an estimate for accessible media files, not a complete measurement of all phone storage. No files are deleted by this screen.'),
      ]),
    );
  }
}

class CollaborativeMemoryWallPage extends StatelessWidget {
  const CollaborativeMemoryWallPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Collaborative Memory Wall')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Icon(Icons.groups_rounded, size: 64, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 18),
        Text('Secure sharing setup required', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
        const SizedBox(height: 10),
        const Text('Little Memories currently keeps personal photo data locally. True multi-person contributions and reactions need an authenticated sync service, access controls, and a place to store shared media. This screen deliberately does not pretend that local-only data is collaborative.'),
        const SizedBox(height: 14),
        const ListTile(leading: Icon(Icons.lock_outline), title: Text('Private by default'), subtitle: Text('No photos are uploaded from this screen.')),
        const ListTile(leading: Icon(Icons.verified_user_outlined), title: Text('Before activation'), subtitle: Text('Design invitations, membership removal, media deletion rights, abuse reporting, and backend costs.')),
      ]),
    );
  }
}

class _AssetThumbnail extends StatelessWidget {
  final AssetEntity asset;
  final BoxFit fit;
  const _AssetThumbnail({required this.asset, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: asset.thumbnailDataWithSize(const ThumbnailSize(420, 420)),
      builder: (context, snapshot) {
        if (snapshot.data == null) {
          return Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            alignment: Alignment.center,
            child: const Icon(Icons.photo_outlined),
          );
        }
        return Image.memory(snapshot.data!, fit: fit, gaplessPlayback: true);
      },
    );
  }
}
