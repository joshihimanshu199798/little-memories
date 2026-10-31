import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:photo_manager/photo_manager.dart';

class _FilmPreset {
  final String name;
  final double contrast, saturation, warmth, fade, grain;
  const _FilmPreset(this.name, {this.contrast = 1, this.saturation = 1, this.warmth = 0, this.fade = 0, this.grain = 0});
}

const _presets = <_FilmPreset>[
  _FilmPreset('Portra Warm', contrast: .94, saturation: .88, warmth: .12, fade: .035, grain: .025),
  _FilmPreset('Golden 200', contrast: 1.06, saturation: 1.08, warmth: .20, fade: .015, grain: .035),
  _FilmPreset('Ektar Vivid', contrast: 1.16, saturation: 1.24, warmth: .02, grain: .012),
  _FilmPreset('Muted Classic', contrast: .94, saturation: .78, warmth: -.04, fade: .07, grain: .03),
  _FilmPreset('Cine Bloom', contrast: 1.08, saturation: .94, warmth: -.12, fade: .025, grain: .045),
  _FilmPreset('Retro 90s', contrast: .88, saturation: .82, warmth: .16, fade: .12, grain: .055),
  _FilmPreset('Instant Soft', contrast: .91, saturation: .90, warmth: .10, fade: .08, grain: .02),
  _FilmPreset('Mono Silver', contrast: 1.18, saturation: 0, fade: .025, grain: .04),
  _FilmPreset('Night Chrome', contrast: 1.22, saturation: .90, warmth: -.18, fade: .01, grain: .05),
  _FilmPreset('Pastel Day', contrast: .86, saturation: .84, warmth: .06, fade: .09, grain: .015),
];

class FilmLabScreen extends StatefulWidget {
  final List<AssetEntity> photos;
  const FilmLabScreen({super.key, required this.photos});
  @override State<FilmLabScreen> createState() => _FilmLabScreenState();
}

class _FilmLabScreenState extends State<FilmLabScreen> {
  AssetEntity? selected;
  int presetIndex = 0;
  double intensity = 1;
  Uint8List? previewBytes;
  bool rendering = false, exporting = false;

  @override void initState() { super.initState(); if (widget.photos.isNotEmpty) selected = widget.photos.first; _renderPreview(); }

  void _applyFilm(img.Image image, _FilmPreset preset, double amount, {required int seed}) {
    final random = math.Random(seed);
    final contrast = 1 + (preset.contrast - 1) * amount;
    final saturation = 1 + (preset.saturation - 1) * amount;
    final warmth = preset.warmth * amount * 30;
    final fade = preset.fade * amount;
    final grain = preset.grain * amount * 255;
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final p = image.getPixel(x, y);
        final r0 = p.r.toDouble(), g0 = p.g.toDouble(), b0 = p.b.toDouble();
        final l = r0 * .2126 + g0 * .7152 + b0 * .0722;
        var r = l + (r0 - l) * saturation;
        var g = l + (g0 - l) * saturation;
        var b = l + (b0 - l) * saturation;
        r = (r - 127.5) * contrast + 127.5 + warmth;
        g = (g - 127.5) * contrast + 127.5 + warmth * .12;
        b = (b - 127.5) * contrast + 127.5 - warmth;
        r = r * (1 - fade) + 128 * fade;
        g = g * (1 - fade) + 128 * fade;
        b = b * (1 - fade) + 128 * fade;
        if (grain > 0) { final n = (random.nextDouble() - .5) * grain; r += n; g += n; b += n; }
        image.setPixelRgba(x, y, r.round().clamp(0, 255), g.round().clamp(0, 255), b.round().clamp(0, 255), p.a.round().clamp(0, 255));
      }
    }
  }

  Future<void> _renderPreview() async {
    final asset = selected;
    if (asset == null) return;
    if (mounted) setState(() => rendering = true);
    try {
      final file = await asset.file;
      if (file == null) return;
      final decoded = img.decodeImage(await file.readAsBytes());
      if (decoded == null) return;
      final preview = img.copyResize(decoded, width: decoded.width > 1200 ? 1200 : decoded.width);
      _applyFilm(preview, _presets[presetIndex], intensity, seed: 42);
      final bytes = Uint8List.fromList(img.encodeJpg(preview, quality: 88));
      if (mounted) setState(() => previewBytes = bytes);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not render this photo preview.')));
    } finally {
      if (mounted) setState(() => rendering = false);
    }
  }

  Future<void> _export() async {
    final asset = selected;
    if (asset == null || exporting) return;
    setState(() => exporting = true);
    try {
      final file = await asset.file;
      if (file == null) throw StateError('The original photo is unavailable.');
      final decoded = img.decodeImage(await file.readAsBytes());
      if (decoded == null) throw StateError('This image format could not be decoded.');
      _applyFilm(decoded, _presets[presetIndex], intensity, seed: DateTime.now().millisecondsSinceEpoch);
      final bytes = Uint8List.fromList(img.encodeJpg(decoded, quality: 95));
      final filename = 'FilmLab_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final saved = await PhotoManager.editor.saveImage(bytes, filename: filename, title: filename, relativePath: 'Pictures/Simple Gallery/Film Lab');
      if (saved == null) throw StateError('Android did not save the edited image.');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Film edit saved as a new photo. Original preserved.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Film Lab'), actions: [
        TextButton.icon(onPressed: selected == null || exporting ? null : _export,
          icon: exporting ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_alt_rounded),
          label: const Text('Save')),
      ]),
      body: widget.photos.isEmpty ? const Center(child: Text('No accessible photos are available.')) : ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          AspectRatio(aspectRatio: 4 / 4.6, child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Stack(fit: StackFit.expand, children: [
              if (previewBytes != null) Image.memory(previewBytes!, fit: BoxFit.contain, gaplessPlayback: true)
              else Container(color: cs.surfaceContainerHighest, child: const Center(child: Icon(Icons.photo_outlined, size: 50))),
              if (rendering) const Positioned(top: 12, right: 12, child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
            ]),
          )),
          const SizedBox(height: 18),
          Text('Choose a film look', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          SizedBox(height: 82, child: ListView.separated(
            scrollDirection: Axis.horizontal, itemCount: _presets.length, separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, index) {
              final preset = _presets[index], active = presetIndex == index;
              return InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () { setState(() => presetIndex = index); _renderPreview(); },
                child: Container(
                  width: 112, padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: active ? cs.primaryContainer : cs.surfaceContainerLow, borderRadius: BorderRadius.circular(14), border: Border.all(color: active ? cs.primary : cs.outlineVariant)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.photo_filter_rounded, color: active ? cs.onPrimaryContainer : cs.primary),
                    const SizedBox(height: 5),
                    Text(preset.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
                  ]),
                ),
              );
            },
          )),
          const SizedBox(height: 18),
          Row(children: [Expanded(child: Text('Film intensity', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))), Text('${(intensity * 100).round()}%', style: const TextStyle(fontWeight: FontWeight.w900))]),
          Slider(value: intensity, min: 0, max: 1, divisions: 100, onChanged: (v) => setState(() => intensity = v), onChangeEnd: (_) => _renderPreview()),
          const SizedBox(height: 10),
          Text('Select another photo', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          SizedBox(height: 88, child: ListView.separated(
            scrollDirection: Axis.horizontal, itemCount: widget.photos.length, separatorBuilder: (_, __) => const SizedBox(width: 7),
            itemBuilder: (_, index) {
              final asset = widget.photos[index], active = selected?.id == asset.id;
              return FutureBuilder<File?>(
                future: asset.file,
                builder: (_, snapshot) => InkWell(
                  onTap: () { setState(() { selected = asset; previewBytes = null; }); _renderPreview(); },
                  child: Container(
                    width: 88,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: active ? cs.primary : Colors.transparent, width: 3)),
                    clipBehavior: Clip.antiAlias,
                    child: snapshot.data == null ? Container(color: cs.surfaceContainerHighest) : Image.file(snapshot.data!, fit: BoxFit.cover),
                  ),
                ),
              );
            },
          )),
          const SizedBox(height: 12),
          Text('These are editable film-inspired looks, not exact reproductions of proprietary film stocks. Exports are saved as new JPEG files; the original photo is preserved.', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}
