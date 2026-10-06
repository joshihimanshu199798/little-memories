import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const LittleMemoriesApp());

class LittleMemoriesApp extends StatefulWidget {
  const LittleMemoriesApp({super.key});
  @override State<LittleMemoriesApp> createState() => _LittleMemoriesAppState();
}

class _LittleMemoriesAppState extends State<LittleMemoriesApp> {
  bool dark = false;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Little Memories',
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFFE58A9A), scaffoldBackgroundColor: const Color(0xFFFFFAFC)),
    darkTheme: ThemeData.dark(useMaterial3: true).copyWith(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFE58A9A), brightness: Brightness.dark)),
    home: GalleryHome(onTheme: () => setState(() => dark = !dark)),
  );
}

class Timeline {
  String id, name, description;
  List<String> assetIds;
  Timeline({required this.id, required this.name, this.description = '', List<String>? assetIds}) : assetIds = assetIds ?? [];
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'description': description, 'assetIds': assetIds};
  factory Timeline.fromJson(Map<String, dynamic> j) => Timeline(id: '${j['id']}', name: '${j['name']}', description: '${j['description'] ?? ''}', assetIds: List<String>.from(j['assetIds'] ?? const []));
}

class GalleryHome extends StatefulWidget {
  final VoidCallback onTheme;
  const GalleryHome({super.key, required this.onTheme});
  @override State<GalleryHome> createState() => _GalleryHomeState();
}

class _GalleryHomeState extends State<GalleryHome> {
  int tab = 0, grid = 3;
  bool loading = true, permissionDenied = false;
  List<AssetEntity> assets = [];
  List<Timeline> timelines = [];
  Set<String> favorites = {};
  Map<String, String> titles = {}, notes = {};
  String query = '';
  bool newestFirst = true;

  AssetEntity? assetById(String id) {
    for (final a in assets) { if (a.id == id) return a; }
    return null;
  }

  @override void initState() { super.initState(); load(); }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    grid = p.getInt('grid') ?? 3;
    favorites = {...?p.getStringList('favorites')};
    final raw = p.getString('timelines');
    if (raw != null) {
      final decoded = jsonDecode(raw);
      timelines = (decoded as List).map((e) => Timeline.fromJson(Map<String, dynamic>.from(e))).toList();
    }
    final tr = p.getString('titles'); if (tr != null) titles = Map<String, String>.from(jsonDecode(tr));
    final nr = p.getString('notes'); if (nr != null) notes = Map<String, String>.from(jsonDecode(nr));
    await scanGallery();
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('grid', grid);
    await p.setStringList('favorites', favorites.toList());
    await p.setString('timelines', jsonEncode(timelines.map((e) => e.toJson()).toList()));
    await p.setString('titles', jsonEncode(titles));
    await p.setString('notes', jsonEncode(notes));
  }

  Future<void> scanGallery() async {
    setState(() => loading = true);
    final state = await PhotoManager.requestPermissionExtend();
    if (!state.isAuth) {
      if (mounted) setState(() { loading = false; permissionDenied = true; });
      return;
    }
    final paths = await PhotoManager.getAssetPathList(onlyAll: true, type: RequestType.image);
    if (paths.isEmpty) {
      if (mounted) setState(() { assets = []; loading = false; permissionDenied = false; });
      return;
    }
    final list = await paths.first.getAssetListRange(start: 0, end: 100000);
    if (mounted) setState(() { assets = list; loading = false; permissionDenied = false; });
  }

  List<AssetEntity> visibleAssets({bool onlyFavorites = false}) {
    var list = onlyFavorites ? assets.where((a) => favorites.contains(a.id)).toList() : List<AssetEntity>.from(assets);
    if (query.trim().isNotEmpty) {
      final q = query.toLowerCase();
      list = list.where((a) => '${titles[a.id] ?? ''} ${notes[a.id] ?? ''} ${a.title ?? ''}'.toLowerCase().contains(q)).toList();
    }
    list.sort((a, b) => newestFirst ? b.createDateTime.compareTo(a.createDateTime) : a.createDateTime.compareTo(b.createDateTime));
    return list;
  }

  Future<void> newTimeline() async {
    final data = await timelineDialog();
    if (data == null) return;
    setState(() => timelines.insert(0, Timeline(id: DateTime.now().microsecondsSinceEpoch.toString(), name: data.$1, description: data.$2)));
    await save();
  }

  Future<void> editTimeline(Timeline t) async {
    final data = await timelineDialog(initialName: t.name, initialDescription: t.description);
    if (data == null) return;
    setState(() { t.name = data.$1; t.description = data.$2; });
    await save();
  }

  Future<(String, String)?> timelineDialog({String initialName = '', String initialDescription = ''}) async {
    final n = TextEditingController(text: initialName);
    final d = TextEditingController(text: initialDescription);
    return showDialog<(String, String)>(context: context, builder: (_) => AlertDialog(
      title: Text(initialName.isEmpty ? 'Create timeline' : 'Edit timeline'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: n, autofocus: true, decoration: const InputDecoration(labelText: 'Timeline name', hintText: 'Sarthak — 1st Birthday')),
        TextField(controller: d, decoration: const InputDecoration(labelText: 'Description')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, (n.text.trim().isEmpty ? 'Untitled' : n.text.trim(), d.text.trim())), child: const Text('Save')),
      ],
    ));
  }

  Future<void> pickForTimeline(Timeline t) async {
    final chosen = <String>{...t.assetIds};
    await showModalBottomSheet(
      context: context, isScrollControlled: true,
      builder: (_) => StatefulBuilder(builder: (context, ss) => DraggableScrollableSheet(
        expand: false, initialChildSize: .92,
        builder: (_, sc) => Column(children: [
          Padding(padding: const EdgeInsets.all(16), child: Row(children: [
            Expanded(child: Text('Add photos to ${t.name}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
            Text('${chosen.length} selected'),
          ])),
          Expanded(child: GridView.builder(
            controller: sc, padding: const EdgeInsets.all(10),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: grid, crossAxisSpacing: 6, mainAxisSpacing: 6),
            itemCount: assets.length,
            itemBuilder: (_, i) {
              final a = assets[i];
              final selected = chosen.contains(a.id);
              return GestureDetector(
                onTap: () { ss(() { if (selected) { chosen.remove(a.id); } else { chosen.add(a.id); } }); },
                child: FutureBuilder<Uint8List?>(future: a.thumbnailDataWithSize(const ThumbnailSize(360, 360)), builder: (_, s) => Stack(fit: StackFit.expand, children: [
                  if (s.data != null) Image.memory(s.data!, fit: BoxFit.cover) else const ColoredBox(color: Colors.black12),
                  if (selected) Container(color: Colors.black38, child: const Center(child: Icon(Icons.check_circle, color: Colors.white, size: 34))),
                ])),
              );
            },
          )),
          Padding(padding: const EdgeInsets.all(12), child: FilledButton.icon(
            onPressed: () { Navigator.pop(context); setState(() => t.assetIds = chosen.toList()); save(); },
            icon: const Icon(Icons.check), label: const Text('Save timeline photos'),
          )),
        ]),
      )),
    );
  }

  Future<void> photoDetails(AssetEntity a) async {
    final title = TextEditingController(text: titles[a.id] ?? a.title ?? '');
    final note = TextEditingController(text: notes[a.id] ?? '');
    final result = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Edit photo'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: title, decoration: const InputDecoration(labelText: 'Photo name')),
        TextField(controller: note, maxLines: 3, decoration: const InputDecoration(labelText: 'Caption / memory note')),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save'))],
    ));
    if (result == true) {
      setState(() { titles[a.id] = title.text.trim(); notes[a.id] = note.text.trim(); });
      await save();
    }
  }

  Future<void> shareTimeline(Timeline t) async {
    final files = <XFile>[];
    for (final id in t.assetIds) {
      final a = assetById(id);
      if (a != null) { final f = await a.file; if (f != null) files.add(XFile(f.path)); }
    }
    final text = '${t.name}\n${t.description}\nShared from Little Memories';
    if (files.isEmpty) { await Share.share(text); } else { await Share.shareXFiles(files, text: text); }
  }

  Future<void> shareSelected(List<AssetEntity> list) async {
    final files = <XFile>[];
    for (final a in list.take(30)) { final f = await a.file; if (f != null) files.add(XFile(f.path)); }
    if (files.isNotEmpty) await Share.shareXFiles(files, text: 'Memories shared from Little Memories');
  }

  Future<void> collaborate(Timeline t) async {
    final invite = 'Little Memories collaboration invite\nTimeline: ${t.name}\nInvite ID: ${t.id}\n\nThis invite is for a private family timeline.';
    await Share.share(invite);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invite shared. Live multi-device sync requires a cloud workspace connection.')));
  }

  Future<void> settings() async {
    await showModalBottomSheet(context: context, builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const ListTile(title: Text('Display'), subtitle: Text('Personalize your memory gallery', style: TextStyle(fontWeight: FontWeight.bold))),
      ListTile(leading: const Icon(Icons.grid_view), title: const Text('Grid size'), subtitle: Slider(value: grid.toDouble(), min: 2, max: 6, divisions: 4, label: '$grid columns', onChanged: (v) { setState(() => grid = v.round()); save(); }), trailing: Text('$grid×')),
      ListTile(leading: const Icon(Icons.sort), title: const Text('Sort order'), trailing: DropdownButton<bool>(value: newestFirst, items: const [DropdownMenuItem(value: true, child: Text('Newest')), DropdownMenuItem(value: false, child: Text('Oldest'))], onChanged: (v) { if (v != null) setState(() => newestFirst = v); })),
      ListTile(leading: const Icon(Icons.lock_outline), title: const Text('Privacy'), subtitle: const Text('Photos remain on the phone unless you share them.')),
      ListTile(leading: const Icon(Icons.group_outlined), title: const Text('Family collaboration'), subtitle: const Text('Cloud sync, reactions and comments are planned for the connected edition.')),
    ])));
  }

  @override Widget build(BuildContext context) {
    if (permissionDenied) return Scaffold(appBar: AppBar(title: const Text('Little Memories')), body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.photo_library_outlined, size: 72), const SizedBox(height: 16),
      const Text('Allow photo access to automatically show your existing phone gallery.', textAlign: TextAlign.center), const SizedBox(height: 18),
      FilledButton(onPressed: () => PhotoManager.openSetting(), child: const Text('Open photo permissions')),
    ]))));
    final titlesByTab = ['Gallery', 'Timelines', 'Favorites', 'More'];
    return Scaffold(
      appBar: AppBar(
        title: Text(titlesByTab[tab], style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (tab == 0) IconButton(onPressed: scanGallery, icon: const Icon(Icons.refresh)),
          if (tab == 0) IconButton(onPressed: () => setState(() => newestFirst = !newestFirst), icon: Icon(newestFirst ? Icons.arrow_downward : Icons.arrow_upward)),
          IconButton(onPressed: widget.onTheme, icon: const Icon(Icons.dark_mode_outlined)),
        ],
      ),
      floatingActionButton: tab == 1 ? FloatingActionButton.extended(onPressed: newTimeline, icon: const Icon(Icons.add), label: const Text('Timeline')) : null,
      body: loading ? const Center(child: CircularProgressIndicator()) : _body(),
      bottomNavigationBar: NavigationBar(selectedIndex: tab, onDestinationSelected: (i) => setState(() => tab = i), destinations: const [
        NavigationDestination(icon: Icon(Icons.photo_library_outlined), selectedIcon: Icon(Icons.photo_library), label: 'Gallery'),
        NavigationDestination(icon: Icon(Icons.timeline), label: 'Timelines'),
        NavigationDestination(icon: Icon(Icons.favorite_border), selectedIcon: Icon(Icons.favorite), label: 'Favorites'),
        NavigationDestination(icon: Icon(Icons.more_horiz), label: 'More'),
      ]),
    );
  }

  Widget _body() {
    if (tab == 0) return _gallery(visibleAssets());
    if (tab == 2) return _gallery(visibleAssets(onlyFavorites: true));
    if (tab == 1) return ListView(padding: const EdgeInsets.all(14), children: [
      ...timelines.map(timelineCard),
      if (timelines.isEmpty) const Padding(padding: EdgeInsets.all(40), child: Center(child: Text('Create your first timeline — birthdays, first steps, trips and everyday magic.', textAlign: TextAlign.center))),
    ]);
    return ListView(children: [
      ListTile(leading: const Icon(Icons.grid_view), title: const Text('Grid size'), subtitle: Slider(value: grid.toDouble(), min: 2, max: 6, divisions: 4, label: '$grid columns', onChanged: (v) { setState(() => grid = v.round()); save(); }), trailing: Text('$grid×')),
      ListTile(leading: const Icon(Icons.sort), title: const Text('Sort order'), subtitle: Text(newestFirst ? 'Newest first' : 'Oldest first'), onTap: () => setState(() => newestFirst = !newestFirst)),
      ListTile(leading: const Icon(Icons.refresh), title: const Text('Rescan phone gallery'), onTap: scanGallery),
      ListTile(leading: const Icon(Icons.settings_outlined), title: const Text('Advanced settings'), onTap: settings),
      const Divider(),
      const ListTile(leading: Icon(Icons.cloud_outlined), title: Text('Cloud family edition'), subtitle: Text('Secure accounts, live sync, reactions, comments, roles, notifications and shared albums can be connected when a cloud backend is configured.')),
      const ListTile(leading: Icon(Icons.auto_awesome), title: Text('Smart memories roadmap'), subtitle: Text('AI grouping, duplicate detection, captions, yearly recaps, memory videos and natural-language search.')),
    ]);
  }

  Widget _gallery(List<AssetEntity> list) => Column(children: [
    Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 4), child: TextField(onChanged: (v) => setState(() => query = v), decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'Search photos, captions or names', suffixIcon: query.isEmpty ? null : IconButton(onPressed: () => setState(() => query = ''), icon: const Icon(Icons.clear)), border: OutlineInputBorder(borderRadius: BorderRadius.circular(18))))),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6), child: Row(children: [Text('${list.length} photos'), const Spacer(), if (list.isNotEmpty) TextButton.icon(onPressed: () => shareSelected(list), icon: const Icon(Icons.share_outlined), label: const Text('Share'))])),
    Expanded(child: list.isEmpty ? const Center(child: Text('No photos found.')) : GridView.builder(padding: const EdgeInsets.all(8), gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: grid, crossAxisSpacing: 6, mainAxisSpacing: 6), itemCount: list.length, itemBuilder: (_, i) {
      final a = list[i]; final fav = favorites.contains(a.id);
      return GestureDetector(onTap: () => photoDetails(a), child: Stack(fit: StackFit.expand, children: [
        FutureBuilder<Uint8List?>(future: a.thumbnailDataWithSize(const ThumbnailSize(500, 500)), builder: (_, s) => ClipRRect(borderRadius: BorderRadius.circular(12), child: s.data == null ? const ColoredBox(color: Colors.black12) : Image.memory(s.data!, fit: BoxFit.cover))),
        Positioned(right: 5, top: 5, child: CircleAvatar(radius: 15, backgroundColor: Colors.black45, child: IconButton(padding: EdgeInsets.zero, iconSize: 17, onPressed: () { setState(() { if (fav) { favorites.remove(a.id); } else { favorites.add(a.id); } }); save(); }, icon: Icon(fav ? Icons.favorite : Icons.favorite_border, color: Colors.white)))),
        if ((titles[a.id] ?? '').isNotEmpty) Positioned(left: 6, right: 6, bottom: 6, child: Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)), child: Text(titles[a.id]!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 11)))),
      ]));
    })));
  }

  Widget timelineCard(Timeline t) {
    final cover = t.assetIds.isEmpty ? null : assetById(t.assetIds.first);
    return Card(child: ListTile(
      leading: cover == null ? const CircleAvatar(child: Icon(Icons.timeline)) : FutureBuilder<Uint8List?>(future: cover.thumbnailDataWithSize(const ThumbnailSize(120, 120)), builder: (_, s) => CircleAvatar(backgroundImage: s.data == null ? null : MemoryImage(s.data!))),
      title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text('${t.assetIds.length} photos${t.description.isEmpty ? '' : ' • ${t.description}'}'),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TimelinePage(t: t, home: this))),
      trailing: PopupMenuButton<String>(onSelected: (v) { if (v == 'edit') editTimeline(t); if (v == 'add') pickForTimeline(t); if (v == 'share') shareTimeline(t); if (v == 'collab') collaborate(t); if (v == 'delete') { setState(() => timelines.remove(t)); save(); } }, itemBuilder: (_) => const [
        PopupMenuItem(value: 'add', child: Text('Add / remove photos')), PopupMenuItem(value: 'edit', child: Text('Rename / edit')), PopupMenuItem(value: 'share', child: Text('Share timeline')), PopupMenuItem(value: 'collab', child: Text('Collaborate')), PopupMenuItem(value: 'delete', child: Text('Delete timeline')),
      ]),
    ));
  }
}

class TimelinePage extends StatelessWidget {
  final Timeline t;
  final _GalleryHomeState home;
  const TimelinePage({super.key, required this.t, required this.home});
  @override Widget build(BuildContext context) {
    final list = <AssetEntity>[];
    for (final id in t.assetIds) { final a = home.assetById(id); if (a != null) list.add(a); }
    return Scaffold(
      appBar: AppBar(title: Text(t.name), actions: [
        IconButton(onPressed: () => home.collaborate(t), icon: const Icon(Icons.group_add_outlined)),
        IconButton(onPressed: () => home.shareTimeline(t), icon: const Icon(Icons.share_outlined)),
        IconButton(onPressed: () => home.editTimeline(t), icon: const Icon(Icons.edit_outlined)),
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => home.pickForTimeline(t), icon: const Icon(Icons.add_photo_alternate_outlined), label: const Text('Add photos')),
      body: Column(children: [
        if (t.description.isNotEmpty) Padding(padding: const EdgeInsets.all(14), child: Align(alignment: Alignment.centerLeft, child: Text(t.description))),
        Expanded(child: list.isEmpty ? const Center(child: Text('No photos yet. Add memories from your phone gallery.')) : GridView.builder(padding: const EdgeInsets.all(8), gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: home.grid, crossAxisSpacing: 6, mainAxisSpacing: 6), itemCount: list.length, itemBuilder: (_, i) {
          final a = list[i];
          return GestureDetector(onTap: () => home.photoDetails(a), child: FutureBuilder<Uint8List?>(future: a.thumbnailDataWithSize(const ThumbnailSize(500, 500)), builder: (_, s) => ClipRRect(borderRadius: BorderRadius.circular(10), child: s.data == null ? const ColoredBox(color: Colors.black12) : Image.memory(s.data!, fit: BoxFit.cover))));
        })),
      ]),
    );
  }
}
