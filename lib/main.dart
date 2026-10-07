
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:image_editor_plus/image_editor_plus.dart';

void main() => runApp(const LittleMemoriesApp());

class Timeline {
  String id, title, description;
  List<String> assets;
  Timeline({required this.id, required this.title, this.description = '', List<String>? assets})
      : assets = assets ?? [];
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'description': description, 'assets': assets};
  factory Timeline.fromJson(Map<String, dynamic> j) => Timeline(
    id: j['id'] as String, title: j['title'] as String,
    description: (j['description'] ?? '') as String,
    assets: List<String>.from(j['assets'] ?? const []),
  );
}

class LittleMemoriesApp extends StatefulWidget {
  const LittleMemoriesApp({super.key});
  @override State<LittleMemoriesApp> createState() => _AppState();
}
class _AppState extends State<LittleMemoriesApp> {
  bool dark = false;
  @override Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Little Memories',
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFFE58A9A)),
    darkTheme: ThemeData.dark(useMaterial3: true).copyWith(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFE58A9A), brightness: Brightness.dark)),
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    home: Home(onDark: (v) => setState(() => dark = v)),
  );
}

class Home extends StatefulWidget {
  final ValueChanged<bool> onDark;
  const Home({super.key, required this.onDark});
  @override State<Home> createState() => _HomeState();
}
class _HomeState extends State<Home> {
  int tab = 0, grid = 3;
  bool loading = true, permissionDenied = false;
  List<AssetEntity> photos = [];
  List<Timeline> timelines = [];
  Set<String> favorites = {};
  Map<String, String> names = {}, captions = {};
  String childName = 'My Little Star', childBirthday = '';
  String searchQuery = '';
  final TextEditingController searchController = TextEditingController();

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth && !permission.hasAccess) {
      if (mounted) setState(() { permissionDenied = true; loading = false; });
      return;
    }
    await _refreshPhotos();
    final raw = p.getString('timelines');
    if (raw != null) timelines = (jsonDecode(raw) as List).map((e) => Timeline.fromJson(e)).toList();
    favorites = (p.getStringList('favorites') ?? const []).toSet();
    final n = p.getString('names'); if (n != null) names = Map<String, String>.from(jsonDecode(n));
    final c = p.getString('captions'); if (c != null) captions = Map<String, String>.from(jsonDecode(c));
    grid = p.getInt('grid') ?? 3;
    childName = p.getString('childName') ?? 'My Little Star';
    childBirthday = p.getString('childBirthday') ?? '';
    setState(() => loading = false);
  }

  Future<void> _refreshPhotos() async {
    final paths = await PhotoManager.getAssetPathList(type: RequestType.image, onlyAll: true);
    if (paths.isNotEmpty) {
      final all = <AssetEntity>[];
      var page = 0;
      const pageSize = 200;
      while (true) {
        final batch = await paths.first.getAssetListPaged(page: page, size: pageSize);
        if (batch.isEmpty) break;
        all.addAll(batch);
        if (batch.length < pageSize) break;
        page++;
      }
      photos = all;
    }
    if (mounted) setState(() {});
  }

  Future<void> _requestPhotos() async {
    setState(() => loading = true);
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth && !permission.hasAccess) {
      setState(() { permissionDenied = true; loading = false; });
      return;
    }
    permissionDenied = false;
    await _refreshPhotos();
    if (mounted) setState(() => loading = false);
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('timelines', jsonEncode(timelines.map((e) => e.toJson()).toList()));
    await p.setStringList('favorites', favorites.toList());
    await p.setString('names', jsonEncode(names));
    await p.setString('captions', jsonEncode(captions));
    await p.setInt('grid', grid);
    await p.setString('childName', childName);
    await p.setString('childBirthday', childBirthday);
  }

  AssetEntity? _find(String id) {
    for (final a in photos) { if (a.id == id) return a; }
    return null;
  }

  Future<void> _editMemory(AssetEntity a) async {
    final n = TextEditingController(text: names[a.id] ?? a.title ?? 'Photo');
    final cap = TextEditingController(text: captions[a.id] ?? '');
    await showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text('Memory details'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: n, decoration: const InputDecoration(labelText: 'Photo name')),
        const SizedBox(height: 8),
        TextField(controller: cap, maxLines: 3, decoration: const InputDecoration(labelText: 'Caption / memory note')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () {
          setState(() { names[a.id] = n.text.trim(); captions[a.id] = cap.text.trim(); });
          _save(); Navigator.pop(context);
        }, child: const Text('Save')),
      ],
    ));
  }

  Future<void> _openPhotoEditor(AssetEntity a) async {
    final file = await a.file;
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final edited = await Navigator.push<Uint8List>(
      context,
      MaterialPageRoute(
        builder: (_) => ImageEditor(
          image: bytes,
          outputFormat: OutputFormat.jpeg,
        ),
      ),
    );
    if (edited == null || edited.isEmpty) return;
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final base = (a.title ?? 'memory').replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final filename = 'LittleMemories_' + stamp.toString() + '_' + base;
      final saved = await PhotoManager.editor.saveImage(
        edited,
        filename: filename.toLowerCase().endsWith('.jpg') ? filename : filename + '.jpg',
        title: 'Edited ' + ((names[a.id] ?? '').isEmpty ? 'memory' : (names[a.id] ?? 'memory')),
        relativePath: 'Pictures/Little Memories',
      );
      if (saved != null) {
        await _refreshPhotos();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Edited photo saved as a new photo. Original is preserved.')),
          );
        }
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save edited photo: $e')));
    }
  }

  Future<void> _share(List<AssetEntity> list, String text) async {
    final files = <XFile>[];
    for (final a in list) { final f = await a.file; if (f != null) files.add(XFile(f.path)); }
    if (files.isNotEmpty) await Share.shareXFiles(files, text: text);
  }

  Future<void> _editChildProfile() async {
    final n = TextEditingController(text: childName);
    final b = TextEditingController(text: childBirthday);
    await showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text('Child profile'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: n, decoration: const InputDecoration(labelText: 'Child name')),
        TextField(controller: b, decoration: const InputDecoration(labelText: 'Birthday (DD/MM/YYYY)')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () {
          setState(() { childName = n.text.trim().isEmpty ? 'My Little Star' : n.text.trim(); childBirthday = b.text.trim(); });
          _save(); Navigator.pop(context);
        }, child: const Text('Save')),
      ],
    ));
  }

  Future<void> _createTimeline({Timeline? existing}) async {
    final t = existing ?? Timeline(id: DateTime.now().microsecondsSinceEpoch.toString(), title: '');
    final title = TextEditingController(text: t.title);
    final desc = TextEditingController(text: t.description);
    await showDialog(context: context, builder: (_) => AlertDialog(
      title: Text(existing == null ? 'Create timeline' : 'Edit timeline'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: title, decoration: const InputDecoration(labelText: 'Timeline name')),
        TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () {
          if (title.text.trim().isEmpty) return;
          setState(() {
            t.title = title.text.trim(); t.description = desc.text.trim();
            if (existing == null) timelines.add(t);
          });
          _save(); Navigator.pop(context);
        }, child: const Text('Save')),
      ],
    ));
  }

  Future<void> _addToTimeline(Timeline t) async {
    final selected = <String>{...t.assets};
    await showModalBottomSheet(context: context, isScrollControlled: true, builder: (_) =>
      StatefulBuilder(builder: (context, setSheet) => SafeArea(child: SizedBox(
        height: MediaQuery.of(context).size.height * .88,
        child: Column(children: [
          ListTile(
            title: Text('Add photos to ' + t.title, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(selected.length.toString() + ' selected'),
            trailing: FilledButton(onPressed: () {
              setState(() => t.assets = selected.toList()); _save(); Navigator.pop(context);
            }, child: const Text('Done')),
          ),
          Expanded(child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: grid, crossAxisSpacing: 5, mainAxisSpacing: 5),
            itemCount: photos.length,
            itemBuilder: (_, i) {
              final a = photos[i], chosen = selected.contains(a.id);
              return GestureDetector(
                onTap: () => setSheet(() { chosen ? selected.remove(a.id) : selected.add(a.id); }),
                child: Stack(fit: StackFit.expand, children: [
                  ClipRRect(borderRadius: BorderRadius.circular(8), child: Thumb(a)),
                  if (chosen) const Align(alignment: Alignment.topRight, child: Padding(
                    padding: EdgeInsets.all(5), child: CircleAvatar(radius: 14, child: Icon(Icons.check, size: 17)))),
                ]),
              );
            },
          )),
        ]),
      ))));
    setState(() {});
  }

  void _openPhoto(AssetEntity a, List<AssetEntity> list) => Navigator.push(context,
    MaterialPageRoute(builder: (_) => Viewer(asset: a, all: list, onEdit: _openPhotoEditor, onShare: (x) => _share([x], 'Shared from Little Memories'))));

  Widget _gallery({bool onlyFavorites = false}) {
    final q = searchQuery.trim().toLowerCase();
    final source = (onlyFavorites ? photos.where((a) => favorites.contains(a.id)) : photos)
      .where((a) => q.isEmpty || (names[a.id] ?? a.title ?? 'Photo').toLowerCase().contains(q) || (captions[a.id] ?? '').toLowerCase().contains(q))
      .toList();
    if (source.isEmpty) return Center(child: Text(q.isEmpty ? (onlyFavorites ? 'No favorite memories yet.' : 'No photos found on this device.') : 'No memories match "$searchQuery".'));
    return RefreshIndicator(
      onRefresh: _refreshPhotos,
      child: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: grid, crossAxisSpacing: 5, mainAxisSpacing: 5),
        itemCount: source.length,
        itemBuilder: (_, i) {
          final a = source[i], fav = favorites.contains(a.id);
          return GestureDetector(
            onTap: () => _openPhoto(a, source),
            onLongPress: () => _editMemory(a),
            child: Stack(fit: StackFit.expand, children: [
              ClipRRect(borderRadius: BorderRadius.circular(9), child: Thumb(a)),
              if (fav) const Positioned(right: 6, top: 6, child: Icon(Icons.favorite, color: Colors.white, shadows: [Shadow(blurRadius: 5)])),
            ]),
          );
        },
      ),
    );
  }

  Widget _timelines() => timelines.isEmpty
    ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.auto_stories_outlined, size: 72),
        const SizedBox(height: 12),
        const Text('Create your first timeline', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: () => _createTimeline(), icon: const Icon(Icons.add), label: const Text('Create timeline')),
      ]))
    : ListView.builder(
      padding: const EdgeInsets.all(12), itemCount: timelines.length,
      itemBuilder: (_, i) {
        final t = timelines[i];
        final imgs = t.assets.map(_find).whereType<AssetEntity>().take(4).toList();
        return Card(clipBehavior: Clip.antiAlias, margin: const EdgeInsets.only(bottom: 12), child: Column(children: [
          SizedBox(height: 150, child: imgs.isEmpty
            ? Container(color: Theme.of(context).colorScheme.surfaceContainerHighest, child: const Center(child: Icon(Icons.photo_library_outlined, size: 55)))
            : Row(children: imgs.map((a) => Expanded(child: Thumb(a))).toList())),
          ListTile(
            title: Text(t.title, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(t.assets.length.toString() + ' photos' + (t.description.isEmpty ? '' : ' • ' + t.description)),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TimelinePage(t: t, find: _find, grid: grid, onEdit: _openPhotoEditor, onShare: (a) => _share([a], t.title)))),
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'add') _addToTimeline(t);
                if (v == 'edit') _createTimeline(existing: t);
                if (v == 'share') _share(t.assets.map(_find).whereType<AssetEntity>().toList(), t.title);
                if (v == 'delete') { setState(() => timelines.remove(t)); _save(); }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'add', child: Text('Add / remove photos')),
                PopupMenuItem(value: 'edit', child: Text('Rename / edit')),
                PopupMenuItem(value: 'share', child: Text('Share timeline')),
                PopupMenuItem(value: 'delete', child: Text('Delete timeline')),
              ],
            ),
          ),
        ]));
      },
    );

  @override void dispose() { searchController.dispose(); super.dispose(); }

  @override Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (permissionDenied) {
      return Scaffold(
        appBar: AppBar(title: const Text('Little Memories')),
        body: Center(child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.photo_library_outlined, size: 82),
            const SizedBox(height: 18),
            const Text('Allow access to your photos', textAlign: TextAlign.center,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            const Text('Little Memories does not upload your photos. It needs photo-library permission so your existing phone gallery can appear here.',
              textAlign: TextAlign.center),
            const SizedBox(height: 22),
            FilledButton.icon(onPressed: _requestPhotos, icon: const Icon(Icons.photo_library), label: const Text('Allow photos')),
          ]),
        )),
      );
    }
    final galleryBody = Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 4), child: Row(children: [
        Expanded(child: Text('Hello, $childName ❤️', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
        IconButton(onPressed: _editChildProfile, icon: const Icon(Icons.child_care_outlined)),
      ])),
      Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 8), child: TextField(
        controller: searchController,
        onChanged: (v) => setState(() => searchQuery = v),
        decoration: InputDecoration(
          hintText: 'Search photos, captions & memories',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: searchQuery.isEmpty ? null : IconButton(onPressed: () { searchController.clear(); setState(() => searchQuery = ''); }, icon: const Icon(Icons.clear)),
          filled: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        ),
      )),
      Expanded(child: _gallery()),
    ]);
    final body = tab == 0 ? galleryBody : tab == 1 ? _timelines() : tab == 2 ? _gallery(onlyFavorites: true) : SettingsPage(
      grid: grid, dark: Theme.of(context).brightness == Brightness.dark,
      onGrid: (v) { setState(() => grid = v); _save(); },
      onDark: widget.onDark,
      onShare: () => _share(photos, 'My Little Memories'),
      childName: childName,
      childBirthday: childBirthday,
      onChildEdit: _editChildProfile,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Little Memories', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [IconButton(onPressed: _refreshPhotos, icon: const Icon(Icons.refresh))],
      ),
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab, onDestinationSelected: (v) => setState(() => tab = v),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.photo_library_outlined), selectedIcon: Icon(Icons.photo_library), label: 'Gallery'),
          NavigationDestination(icon: Icon(Icons.auto_stories_outlined), selectedIcon: Icon(Icons.auto_stories), label: 'Timelines'),
          NavigationDestination(icon: Icon(Icons.favorite_border), selectedIcon: Icon(Icons.favorite), label: 'Favorites'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
      floatingActionButton: tab == 1 ? FloatingActionButton.extended(onPressed: () => _createTimeline(), icon: const Icon(Icons.add), label: const Text('Timeline')) : null,
    );
  }
}

class Thumb extends StatelessWidget {
  final AssetEntity asset;
  const Thumb(this.asset, {super.key});
  @override Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: asset.thumbnailDataWithSize(const ThumbnailSize(500, 500)),
    builder: (_, s) => s.hasData
      ? Image.memory(s.data!, fit: BoxFit.cover)
      : Container(color: Theme.of(context).colorScheme.surfaceContainerHighest, child: const Center(child: CircularProgressIndicator(strokeWidth: 2))),
  );
}

class TimelinePage extends StatelessWidget {
  final Timeline t;
  final AssetEntity? Function(String) find;
  final int grid;
  final Future<void> Function(AssetEntity) onEdit;
  final Future<void> Function(AssetEntity) onShare;
  const TimelinePage({super.key, required this.t, required this.find, required this.grid, required this.onEdit, required this.onShare});
  @override Widget build(BuildContext context) {
    final imgs = t.assets.map(find).whereType<AssetEntity>().toList();
    return Scaffold(
      appBar: AppBar(title: Text(t.title), actions: [
        IconButton(onPressed: () => showDialog(context: context, builder: (_) => const AlertDialog(
          title: Text('Collaborate with family'),
          content: Text('Cloud collaboration is the next stage: family accounts, shared timelines, reactions, comments and real-time sync. This local version never pretends that feature is active.'),
        )), icon: const Icon(Icons.people_outline)),
      ]),
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (t.description.isNotEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(t.description)),
        Expanded(child: GridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: grid, crossAxisSpacing: 5, mainAxisSpacing: 5),
          itemCount: imgs.length,
          itemBuilder: (_, i) => GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => Viewer(asset: imgs[i], all: imgs, onEdit: onEdit, onShare: onShare))),
            child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Thumb(imgs[i])),
          ),
        )),
      ]),
    );
  }
}

class Viewer extends StatefulWidget {
  final AssetEntity asset;
  final List<AssetEntity> all;
  final Future<void> Function(AssetEntity) onEdit;
  final Future<void> Function(AssetEntity) onShare;
  const Viewer({super.key, required this.asset, required this.all, required this.onEdit, required this.onShare});
  @override State<Viewer> createState() => _ViewerState();
}
class _ViewerState extends State<Viewer> {
  late int index;
  late final PageController controller;
  @override void initState() {
    super.initState(); index = widget.all.indexOf(widget.asset); if (index < 0) index = 0; controller = PageController(initialPage: index);
  }
  @override Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text((index + 1).toString() + '/' + widget.all.length.toString()), actions: [
      IconButton(onPressed: () => widget.onEdit(widget.all[index]), tooltip: 'Edit photo', icon: const Icon(Icons.tune_outlined)),
      IconButton(onPressed: () => widget.onShare(widget.all[index]), icon: const Icon(Icons.share_outlined)),
    ]),
    body: PageView.builder(controller: controller, itemCount: widget.all.length, onPageChanged: (i) => setState(() => index = i),
      itemBuilder: (_, i) => FutureBuilder<File?>(
        future: widget.all[i].file,
        builder: (_, s) => s.hasData ? InteractiveViewer(child: Center(child: Image.file(s.data!, fit: BoxFit.contain))) : const Center(child: CircularProgressIndicator()),
      )),
  );
}

class SettingsPage extends StatelessWidget {
  final int grid; final bool dark; final ValueChanged<int> onGrid; final ValueChanged<bool> onDark; final VoidCallback onShare; final String childName; final String childBirthday; final VoidCallback onChildEdit;
  const SettingsPage({super.key, required this.grid, required this.dark, required this.onGrid, required this.onDark, required this.onShare, required this.childName, required this.childBirthday, required this.onChildEdit});
  @override Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
    const Text('Professional controls', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800)),
    const SizedBox(height: 14),
    Card(child: SwitchListTile(value: dark, onChanged: onDark, title: const Text('Dark mode'), secondary: const Icon(Icons.dark_mode_outlined))),
    Card(child: ListTile(title: const Text('Gallery grid size'), subtitle: Slider(value: grid.toDouble(), min: 2, max: 6, divisions: 4, label: grid.toString() + ' columns', onChanged: (v) => onGrid(v.round())), trailing: Text(grid.toString() + '×'))),
    Card(child: ListTile(leading: const Icon(Icons.child_care_outlined), title: Text(childName), subtitle: Text(childBirthday.isEmpty ? 'Add birthday and milestones' : 'Birthday: $childBirthday'), onTap: onChildEdit)),
    Card(child: ListTile(leading: const Icon(Icons.people_outline), title: const Text('Family collaboration'), subtitle: const Text('Private accounts, shared timelines, reactions and comments are planned for the cloud edition.'))),
    Card(child: ListTile(leading: const Icon(Icons.share_outlined), title: const Text('Share gallery'), onTap: onShare)),
    const Card(child: ListTile(leading: Icon(Icons.lock_outline), title: Text('Privacy first'), subtitle: Text('Photos stay in your device library. The app stores timeline metadata locally.'))),
  ]);
}
