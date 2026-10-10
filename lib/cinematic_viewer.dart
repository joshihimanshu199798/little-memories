import 'dart:io';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

class CinematicViewer extends StatefulWidget {
  final AssetEntity asset;
  final List<AssetEntity> all;
  final String Function(String id)? nameFor;
  final String Function(String id)? captionFor;
  final bool Function(String id)? isFavorite;
  final Future<void> Function(AssetEntity)? onToggleFavorite;
  final Future<void> Function(AssetEntity) onEdit;
  final Future<void> Function(AssetEntity) onShare;

  const CinematicViewer({
    super.key, required this.asset, required this.all,
    required this.onEdit, required this.onShare,
    this.nameFor, this.captionFor, this.isFavorite, this.onToggleFavorite,
  });

  @override
  State<CinematicViewer> createState() => _CinematicViewerState();
}

class _CinematicViewerState extends State<CinematicViewer> {
  late final PageController _controller;
  late int _index;
  bool _controls = true;
  final Map<String, Future<File?>> _fileFutures = <String, Future<File?>>{};

  Future<File?> _fileFor(AssetEntity asset) =>
      _fileFutures.putIfAbsent(asset.id, () => asset.file);

  AssetEntity get _current => widget.all[_index];

  @override
  void initState() {
    super.initState();
    _index = widget.all.indexOf(widget.asset);
    if (_index < 0) _index = 0;
    _controller = PageController(initialPage: _index);
  }

  String _title(AssetEntity a) {
    final custom = widget.nameFor?.call(a.id)?.trim() ?? '';
    return custom.isEmpty ? (a.title ?? 'Memory') : custom;
  }

  String _caption(AssetEntity a) => widget.captionFor?.call(a.id) ?? '';
  bool _favorite(AssetEntity a) => widget.isFavorite?.call(a.id) ?? false;

  Future<void> _favoriteToggle() async {
    final action = widget.onToggleFavorite;
    if (action == null) return;
    await action(_current);
    if (mounted) setState(() {});
  }

  Future<void> _showDetails() async {
    final asset = _current;
    int? bytes;
    try {
      final file = await asset.file;
      if (file != null && await file.exists()) bytes = await file.length();
    } catch (_) {}
    if (!mounted) return;

    final date = asset.createDateTime;
    final dateText = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    final sizeText = bytes == null
        ? 'Unavailable'
        : bytes < 1024
            ? '$bytes B'
            : bytes < 1024 * 1024
                ? '${(bytes / 1024).toStringAsFixed(1)} KB'
                : '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    final folder = (asset.relativePath ?? '').trim();

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: Text(_title(asset), maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: const Text('File details stay on this device'),
            ),
            _detailRow(Icons.calendar_today_outlined, 'Date taken', dateText),
            _detailRow(Icons.aspect_ratio_outlined, 'Resolution', '${asset.width} × ${asset.height} px'),
            _detailRow(Icons.storage_outlined, 'File size', sizeText),
            _detailRow(Icons.folder_outlined, 'Folder', folder.isEmpty ? 'Unavailable' : folder),
            _detailRow(Icons.photo_outlined, 'Media type', asset.type.name.toUpperCase()),
          ]),
        ),
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value) {
    return ListTile(
      dense: true,
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
    );
  }

  void _more() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => SafeArea(
        child: Container(
          margin: const EdgeInsets.all(10),
          padding: const EdgeInsets.only(top: 8, bottom: 12),
          decoration: BoxDecoration(color: const Color(0xFF171719), borderRadius: BorderRadius.circular(28)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 42, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(10))),
            ListTile(
              leading: Icon(_favorite(_current) ? Icons.favorite : Icons.favorite_border, color: Colors.white),
              title: Text(_favorite(_current) ? 'Remove from favorites' : 'Add to favorites',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              onTap: () async { Navigator.pop(context); await _favoriteToggle(); },
            ),
            ListTile(
              leading: const Icon(Icons.tune_rounded, color: Colors.white),
              title: const Text('Edit memory', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              onTap: () { Navigator.pop(context); widget.onEdit(_current); },
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined, color: Colors.white),
              title: const Text('Share memory', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              onTap: () { Navigator.pop(context); widget.onShare(_current); },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded, color: Colors.white),
              title: const Text('Photo details', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              onTap: () async {
                Navigator.pop(context);
                await Future<void>.delayed(const Duration(milliseconds: 150));
                if (mounted) await _showDetails();
              },
            ),
          ]),
        ),
      ),
    );
  }

  Widget _button(IconData icon, VoidCallback action, {String? tooltip}) {
    return Material(
      color: Colors.black.withOpacity(.36), shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(), onTap: action,
        child: Tooltip(message: tooltip ?? '',
          child: SizedBox(width: 46, height: 46, child: Icon(icon, color: Colors.white))),
      ),
    );
  }

  Widget _photo(AssetEntity asset) {
    return FutureBuilder<File?>(
      future: _fileFor(asset),
      builder: (_, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: Colors.white));
        }
        final file = snapshot.data;
        if (file == null) return const Center(child: Icon(Icons.broken_image_outlined, color: Colors.white54, size: 52));
        return InteractiveViewer(
          minScale: 1, maxScale: 5, clipBehavior: Clip.none,
          child: Center(child: Image.file(file, fit: BoxFit.contain, gaplessPlayback: true)),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final asset = _current;
    final title = _title(asset);
    final caption = _caption(asset);
    final favorite = _favorite(asset);

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _controls ? AppBar(
        backgroundColor: Colors.transparent, elevation: 0, foregroundColor: Colors.white,
        leading: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: _button(Icons.arrow_back_rounded, () => Navigator.pop(context), tooltip: 'Back'),
        ),
        title: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(color: Colors.black.withOpacity(.34), borderRadius: BorderRadius.circular(30)),
          child: Text('${_index + 1} / ${widget.all.length}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
        ),
        actions: [
          _button(favorite ? Icons.favorite : Icons.favorite_border, _favoriteToggle, tooltip: favorite ? 'Unfavorite' : 'Favorite'),
          const SizedBox(width: 8),
          _button(Icons.more_horiz_rounded, _more, tooltip: 'More'),
          const SizedBox(width: 10),
        ],
      ) : null,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _controls = !_controls),
        child: Stack(fit: StackFit.expand, children: [
          PageView.builder(
            controller: _controller, itemCount: widget.all.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) => _photo(widget.all[i]),
          ),
          if (_controls) Positioned(
            left: 16, right: 16, bottom: 18,
            child: SafeArea(child: Column(children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 15),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.58),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white.withOpacity(.12)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 5),
                  Text('${_month(asset.createDateTime.month)} ${asset.createDateTime.day}, ${asset.createDateTime.year}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700)),
                  if (caption.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(caption, maxLines: 3, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, height: 1.3)),
                  ],
                ]),
              ),
              const SizedBox(height: 10),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _dock(Icons.tune_rounded, 'Edit', () => widget.onEdit(asset)),
                const SizedBox(width: 8),
                _dock(favorite ? Icons.favorite : Icons.favorite_border, favorite ? 'Loved' : 'Love',
                  _favoriteToggle, active: favorite),
                const SizedBox(width: 8),
                _dock(Icons.share_outlined, 'Share', () => widget.onShare(asset)),
              ]),
            ])),
          ),
        ]),
      ),
    );
  }

  Widget _dock(IconData icon, String label, VoidCallback action, {bool active = false}) {
    return Material(
      color: active ? Colors.white : Colors.black.withOpacity(.56),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: action, borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 18, color: active ? Colors.black : Colors.white),
            const SizedBox(width: 7),
            Text(label, style: TextStyle(color: active ? Colors.black : Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
          ]),
        ),
      ),
    );
  }

  String _month(int m) => const ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][m - 1];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
