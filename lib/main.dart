
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:image_editor_plus/image_editor_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

void main() => runApp(const LittleMemoriesApp());

class Timeline {
  String id, title, description;
  List<String> assets;
  String? coverId;
  Timeline({required this.id, required this.title, this.description = '', List<String>? assets, this.coverId})
      : assets = assets ?? [];
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'description': description, 'assets': assets, 'coverId': coverId};
  factory Timeline.fromJson(Map<String, dynamic> j) => Timeline(
    id: j['id'] as String, title: j['title'] as String,
    description: (j['description'] ?? '') as String,
    assets: List<String>.from(j['assets'] ?? const []),
    coverId: ((j['coverId'] ?? '') as String).isEmpty ? null : (j['coverId'] as String),
  );
}


class PcConnectService {
  final List<AssetEntity> photos;
  final List<Timeline> timelines;
  final Map<String, String> names;
  final Map<String, String> captions;
  final VoidCallback onConnected;
  final VoidCallback onBackupStarted;
  HttpServer? _server;
  RawDatagramSocket? _discoverySocket;
  String? url;
  final String token = List.generate(18, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
  final String pairingKey;

  PcConnectService({required this.photos, required this.timelines, required this.names, required this.captions, required this.onConnected, required this.onBackupStarted, required this.pairingKey});

  static Future<String> loadPairingKey() async {
    final prefs = await SharedPreferences.getInstance();
    var key = prefs.getString('pcPairingKey');
    if (key == null || key.length < 32) {
      key = List.generate(48, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
      await prefs.setString('pcPairingKey', key);
    }
    return key;
  }
  bool get running => _server != null;

  Future<void> start() async {
    if (running) return;
    final handler = const shelf.Pipeline().addHandler(_handle);
    try {
      _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, 47832, poweredByHeader: null);
    } catch (_) {
      _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, 0, poweredByHeader: null);
    }
    final ip = await _findLocalIp();
    if (ip == null) { await stop(); throw StateError('Could not find a Wi-Fi network address.'); }
    url = 'http://${ip}:${_server!.port}/?token=${token}&pair=${Uri.encodeQueryComponent(pairingKey)}';
    await _startDiscoveryResponder();
  }

  Future<void> _startDiscoveryResponder() async {
    try {
      _discoverySocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 47833);
      _discoverySocket!.broadcastEnabled = true;
      _discoverySocket!.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = _discoverySocket!.receive();
        if (d == null) return;
        final message = utf8.decode(d.data, allowMalformed: true);
        if (!message.startsWith('LITTLE_MEMORIES_DISCOVER_V1|')) return;
        final suppliedPair = message.substring('LITTLE_MEMORIES_DISCOVER_V1|'.length);
        if (suppliedPair != pairingKey || _server == null) return;
        final host = d.address.address;
        final response = jsonEncode({'service': 'Little Memories', 'version': 1, 'port': _server!.port, 'pair': pairingKey});
        _discoverySocket!.send(utf8.encode(response), d.address, d.port);
      });
    } catch (_) {
      _discoverySocket = null;
    }
  }

  Future<String?> _findLocalIp() async {
    final interfaces = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
    final candidates = <String>[];
    for (final ni in interfaces) {
      for (final a in ni.addresses) {
        if (!a.isLoopback && !a.address.startsWith('169.254.')) candidates.add(a.address);
      }
    }
    if (candidates.isEmpty) return null;
    for (final ip in candidates) {
      if (ip.startsWith('192.168.') || ip.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2[0-9]|3[0-1])\.').hasMatch(ip)) return ip;
    }
    return candidates.first;
  }

  bool _authorized(shelf.Request request) =>
      request.url.queryParameters['token'] == token ||
      request.url.queryParameters['pair'] == pairingKey;
  AssetEntity? _asset(String id) {
    for (final a in photos) { if (a.id == id) return a; }
    return null;
  }
  String _mime(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.webp')) return 'image/webp';
    if (p.endsWith('.gif')) return 'image/gif';
    if (p.endsWith('.heic') || p.endsWith('.heif')) return 'image/heic';
    return 'image/jpeg';
  }
  String _safe(String value) => const HtmlEscape().convert(value);

  Future<shelf.Response> _handle(shelf.Request request) async {
    if (!_authorized(request)) return shelf.Response.unauthorized('This Little Memories connection has expired.');
    if (request.url.path == '/') {
      onConnected();
      return shelf.Response.ok(_html(), headers: {'content-type': 'text/html; charset=utf-8'});
    }
    if (request.url.path == '/api/backup-start') {
      onBackupStarted();
      return shelf.Response.ok(jsonEncode({'ok': true, 'count': photos.length}), headers: {'content-type': 'application/json'});
    }
    if (request.url.path == '/api/photos') {
      onConnected();
      final data = <Map<String, dynamic>>[];
      for (final a in photos) {
        data.add({'id': a.id, 'name': names[a.id] ?? a.title ?? 'Memory', 'caption': captions[a.id] ?? ''});
      }
      return shelf.Response.ok(jsonEncode({'photos': data, 'count': data.length}), headers: {'content-type': 'application/json'});
    }
    final parts = request.url.pathSegments;
    if (parts.length == 2 && (parts[0] == 'photo' || parts[0] == 'download')) {
      final id = Uri.decodeComponent(parts[1]);
      final a = _asset(id);
      if (a == null) return shelf.Response.notFound('Photo not found.');
      final file = await a.file;
      if (file == null || !await file.exists()) return shelf.Response.notFound('Photo file is unavailable.');
      onConnected();
      final filename = (a.title ?? 'memory').replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final headers = <String, Object>{'content-type': _mime(file.path), 'cache-control': 'private, max-age=3600'};
      if (parts[0] == 'download') headers['content-disposition'] = 'attachment; filename="$filename"';
      return shelf.Response.ok(file.openRead(), headers: headers);
    }
    return shelf.Response.notFound('Not found.');
  }

  String _html() {
    final photoCount = photos.length;
    final timelineHtml = timelines.map((t) {
      final ids = t.assets.where((id) => _asset(id) != null).map((id) => "'${id.replaceAll("'", "\\'")}'").join(',');
      return '<div class="timeline"><div><b>${_safe(t.title)}</b><span>${t.assets.length} photos</span></div><button onclick="downloadMany([$ids])">Download timeline</button></div>';
    }).join();
    return '''<!doctype html>
<html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Little Memories — PC Connect</title>
<style>
body{font-family:system-ui,-apple-system,sans-serif;margin:0;background:#f6f3f4;color:#202124}
header{padding:22px;background:#202124;color:white;position:sticky;top:0;z-index:2}
main{max-width:1200px;margin:auto;padding:18px}
.toolbar{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-bottom:16px}
button{border:0;border-radius:12px;padding:10px 14px;background:#e58a9a;color:white;font-weight:700;cursor:pointer}
button.secondary{background:#ddd;color:#222}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:12px}
.card{background:white;border-radius:16px;overflow:hidden;box-shadow:0 2px 10px #0001}
.card img{width:100%;height:180px;object-fit:cover;background:#ddd}
.meta{padding:10px}.meta b{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.meta small{color:#666;display:block;margin:4px 0 8px;min-height:18px}
.timeline{background:white;padding:12px 14px;border-radius:14px;margin:8px 0;display:flex;justify-content:space-between;align-items:center;gap:12px}
input{accent-color:#e58a9a}.count{opacity:.75}
</style></head><body>
<header><h2 style="margin:0">Little Memories — PC Connect</h2><div class="count">$photoCount photos available</div></header>
<main>
<div class="toolbar"><button onclick="selectAll(true)">Select all</button><button class="secondary" onclick="selectAll(false)">Clear</button><button onclick="downloadSelected()">Download selected</button><button onclick="fullBackup()">Backup all to PC</button></div>
<h3>Timelines</h3>$timelineHtml
<h3>All memories</h3><div id="grid" class="grid">Loading…</div>
</main>
<script>
const token=${jsonEncode(token)};
const pair=${jsonEncode(pairingKey)};
let data=[];
function auth(){return 'pair='+encodeURIComponent(pair)+'&token='+encodeURIComponent(token)}
function url(type,id){return '/'+type+'/'+encodeURIComponent(id)+'?'+auth()}
async function load(){
 const r=await fetch('/api/photos?'+auth()); const j=await r.json(); data=j.photos||[];
 document.getElementById('grid').innerHTML=data.map(p=>'<div class="card"><img loading="lazy" src="'+url('photo',p.id)+'"><div class="meta"><label><input type="checkbox" class="pick" value="'+p.id.replace(/"/g,'&quot;')+'"> Select</label><b>'+escapeHtml(p.name)+'</b><small>'+escapeHtml(p.caption||'')+'</small><a href="'+url('download',p.id)+'">Download photo</a></div></div>').join('');
}
function escapeHtml(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
function selectAll(v){document.querySelectorAll('.pick').forEach(x=>x.checked=v)}
function downloadMany(ids){ids.filter(Boolean).forEach((id,i)=>setTimeout(()=>{const a=document.createElement('a');a.href=url('download',id);a.download='';document.body.appendChild(a);a.click();a.remove()},i*500))}
function downloadSelected(){downloadMany([...document.querySelectorAll('.pick:checked')].map(x=>x.value))}
async function fullBackup(){
 const r=await fetch('/api/backup-start?'+auth());
 if(r.ok){ downloadMany(data.map(p=>p.id)); alert('Full backup started. Keep this browser tab open until the downloads finish.'); }
}
load();
</script></body></html>''';
  }

  Future<void> stop() async {
    _discoverySocket?.close();
    _discoverySocket = null;
    final s = _server; _server = null; url = null;
    if (s != null) await s.close(force: true);
  }
}

class ComicTheme { final String name; final Color seed; final Color background; final Color surface; final double radius; const ComicTheme(this.name,this.seed,this.background,this.surface,this.radius); }
const comicThemes=<ComicTheme>[ComicTheme('Comic Pop',Color(0xFFE85D75),Color(0xFFFFF8F0),Color(0xFFFFFFFF),22),ComicTheme('Sky Doodle',Color(0xFF3B82F6),Color(0xFFF3FAFF),Color(0xFFFFFFFF),22),ComicTheme('Mint Story',Color(0xFF10A77A),Color(0xFFF1FFF8),Color(0xFFFFFFFF),22),ComicTheme('Purple Comic',Color(0xFF8B5CF6),Color(0xFFF8F5FF),Color(0xFFFFFFFF),22),ComicTheme('Sunshine',Color(0xFFF59E0B),Color(0xFFFFFCF0),Color(0xFFFFFFFF),22)];

class LittleMemoriesApp extends StatefulWidget {
  const LittleMemoriesApp({super.key});
  @override State<LittleMemoriesApp> createState() => _AppState();
}
class _AppState extends State<LittleMemoriesApp> {
  bool dark = false; int themeIndex = 0;
  @override Widget build(BuildContext context) { final t=comicThemes[themeIndex.clamp(0,comicThemes.length-1)]; return MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Little Memories',
    theme: ThemeData(useMaterial3:true,colorSchemeSeed:t.seed,scaffoldBackgroundColor:t.background,cardTheme:CardThemeData(color:t.surface,elevation:0,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(t.radius),side:BorderSide(color:t.seed.withValues(alpha:.18),width:2))),appBarTheme:AppBarTheme(backgroundColor:t.background,elevation:0),filledButtonTheme:FilledButtonThemeData(style:FilledButton.styleFrom(shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(16),side:BorderSide(color:t.seed,width:1.5))))),
    darkTheme:ThemeData.dark(useMaterial3:true).copyWith(colorScheme:ColorScheme.fromSeed(seedColor:t.seed,brightness:Brightness.dark)),themeMode:dark?ThemeMode.dark:ThemeMode.light,home:Home(themeIndex:themeIndex,onDark:(v)=>setState(()=>dark=v),onTheme:(v) async {final p=await SharedPreferences.getInstance();await p.setInt('comicTheme',v);if(mounted)setState(()=>themeIndex=v);}),); }

class Home extends StatefulWidget {
  final ValueChanged<bool> onDark; final ValueChanged<int> onTheme; final int themeIndex;
  const Home({super.key,required this.onDark,required this.onTheme,required this.themeIndex});
  @override State<Home> createState() => _HomeState();
}
class _HomeState extends State<Home> {
  int tab = 0, grid = 3;
  bool galleryNewestFirst = true;
  bool galleryShowNames = false;
  bool loading = true, permissionDenied = false;
  List<AssetEntity> photos = [];
  List<Timeline> timelines = [];
  Set<String> favorites = {};
  Map<String, String> names = {}, captions = {};
  List<String> backupHistory = [];
  bool selectionMode = false;
  Set<String> selectedIds = {};  String childName = 'My Little Star', childBirthday = '';  String searchQuery = '';
  bool showAllPhotos = false;
  Set<String> hiddenIds = {};
  int galleryFilter = 0;
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
    backupHistory = p.getStringList('backupHistory') ?? [];
    hiddenIds = (p.getStringList('hiddenIds') ?? const []).toSet();
    galleryFilter = p.getInt('galleryFilter') ?? 0;
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
    await p.setStringList('backupHistory', backupHistory);
    await p.setStringList('hiddenIds', hiddenIds.toList());
    await p.setInt('galleryFilter', galleryFilter);
    await p.setInt('grid', grid);
    await p.setString('childName', childName);
    await p.setString('childBirthday', childBirthday);
  }

  AssetEntity? _find(String id) {
    for (final a in photos) { if (a.id == id) return a; }
    return null;
  }

  Future<void> _recordBackup() async {
    final stamp = DateTime.now().toIso8601String();
    setState(() {
      backupHistory.insert(0, stamp);
      if (backupHistory.length > 20) backupHistory = backupHistory.take(20).toList();
    });
    await _save();
  }

  void _toggleSelection(AssetEntity a) {
    setState(() {
      if (selectedIds.contains(a.id)) { selectedIds.remove(a.id); } else { selectedIds.add(a.id); }
      selectionMode = selectedIds.isNotEmpty;
    });
  }

  void _clearSelection() {
    setState(() { selectedIds.clear(); selectionMode = false; });
  }

  Future<void> _bulkFavorite() async {
    if (selectedIds.isEmpty) return;
    setState(() {
      for (final id in selectedIds) {
        if (favorites.contains(id)) { favorites.remove(id); } else { favorites.add(id); }
      }
    });
    await _save();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${selectedIds.length} memories updated')));
    _clearSelection();
  }

  Future<void> _hideSelected() async {
    if (selectedIds.isEmpty) return;
    setState(() => hiddenIds.addAll(selectedIds));
    await _save();
    _clearSelection();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Memories moved to Private / Hidden.')));
  }

  Future<void> _showHiddenMemories() async {
    final hidden = photos.where((a) => hiddenIds.contains(a.id)).toList();
    if (hidden.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No hidden memories.')));
      return;
    }
    await showModalBottomSheet(context: context, isScrollControlled: true, builder: (_) => SafeArea(
      child: SizedBox(height: MediaQuery.of(context).size.height * .75, child: Column(children: [
        ListTile(title: const Text('Private / Hidden memories', style: TextStyle(fontWeight: FontWeight.w900)), subtitle: Text(hidden.length.toString() + ' memories'), trailing: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close))),
        Expanded(child: GridView.builder(
          padding: const EdgeInsets.all(10),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: grid, crossAxisSpacing: 5, mainAxisSpacing: 5),
          itemCount: hidden.length,
          itemBuilder: (_, i) {
            final a = hidden[i];
            return Stack(fit: StackFit.expand, children: [
              ClipRRect(borderRadius: BorderRadius.circular(10), child: Thumb(a)),
              Positioned(right: 4, top: 4, child: IconButton(
                style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
                onPressed: () async { setState(() => hiddenIds.remove(a.id)); await _save(); Navigator.pop(context); _showHiddenMemories(); },
                icon: const Icon(Icons.visibility_rounded, size: 18),
              )),
            ]);
          },
        )),
      ])),
    ));
  }

  Future<void> _smartDuplicateScan() async {
    final groups = <String, List<AssetEntity>>{};
    for (final a in photos) {
      final key = a.createDateTime.year.toString() + '-' + a.createDateTime.month.toString() + '-' + a.createDateTime.day.toString() + '-' + (a.title ?? '').toLowerCase();
      groups.putIfAbsent(key, () => []).add(a);
    }
    final duplicates = groups.values.where((g) => g.length > 1).toList();
    if (!mounted) return;
    final count = duplicates.fold<int>(0, (n, g) => n + g.length - 1);
    await showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text('Duplicate scan'),
      content: duplicates.isEmpty ? const Text('No likely duplicates found. Nothing is deleted automatically.') : Text(count.toString() + ' likely duplicate copies found across ' + duplicates.length.toString() + ' groups. Review them before deleting anything.'),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    ));
  }

  Future<void> _memoryStatistics() async {
    final years = <int>{}; final months = <String>{};
    for (final a in photos) {
      years.add(a.createDateTime.year);
      months.add(a.createDateTime.year.toString() + '-' + a.createDateTime.month.toString());
    }
    final milestones = <String>[];
    if (photos.length >= 100) milestones.add('100 memories');
    if (photos.length >= 500) milestones.add('500 memories');
    if (photos.length >= 1000) milestones.add('1,000 memories');
    if (timelines.length >= 5) milestones.add('5 stories');
    await showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text('Memory statistics'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('📸 ' + photos.length.toString() + ' photos'),
        Text('❤️ ' + favorites.length.toString() + ' favorites'),
        Text('📖 ' + timelines.length.toString() + ' stories'),
        Text('📅 ' + years.length.toString() + ' years • ' + months.length.toString() + ' months'),
        const SizedBox(height: 14),
        Text(milestones.isEmpty ? 'Next milestone: keep collecting memories ✨' : 'Milestones reached: ' + milestones.join(', ')),
      ]),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Great'))],
    ));
  }

  void _startSlideshow() { if (photos.isNotEmpty) _openPhoto(photos.first, photos); }
  Future<void> _shareMemoryCollection() => _share(photos.take(20).toList(), 'My Little Memories');

  Future<void> _bulkShare() async {
    final list = selectedIds.map(_find).whereType<AssetEntity>().toList();
    if (list.isEmpty) return;
    await _share(list, 'Shared from Little Memories');
    _clearSelection();
  }

  Future<void> _bulkAddToTimeline() async {
    if (timelines.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Create a timeline first, then add selected memories.')));
      return;
    }
    final chosen = await showDialog<Timeline>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Add selected memories to'),
        children: timelines.map((t) => SimpleDialogOption(onPressed: () => Navigator.pop(context, t), child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(t.title)))).toList(),
      ),
    );
    if (chosen == null) return;
    setState(() { chosen.assets = <String>{...chosen.assets, ...selectedIds}.toList(); });
    await _save();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${selectedIds.length} memories added to ${chosen.title}')));
    _clearSelection();
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
          ),          Expanded(child: GridView.builder(
            padding: const EdgeInsets.all(8),            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
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
    MaterialPageRoute(builder: (_) => Viewer(
      asset: a,
      all: list,
      onEdit: _openPhotoEditor,
      onShare: (x) => _share([x], 'Shared from Little Memories'),
      memoryName: names[a.id] ?? a.title ?? 'Memory',
      caption: captions[a.id] ?? '',
      favorite: favorites.contains(a.id),
      onToggleFavorite: () async {
        setState(() {
          if (favorites.contains(a.id)) { favorites.remove(a.id); } else { favorites.add(a.id); }
        });
        await _save();
      },
    )));


  List<AssetEntity> _onThisDayMemories() {
    final now = DateTime.now();
    final matches = photos.where((a) {
      final d = a.createDateTime;
      return d.month == now.month && d.day == now.day && d.year < now.year;
    }).toList();
    matches.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
    return matches;
  }

  Widget _onThisDay() {
    final memories = _onThisDayMemories();
    if (memories.isEmpty) return const SizedBox.shrink();
    final years = memories.map((a) => a.createDateTime.year).toSet().length;
    return Column(children: [
      _sectionTitle('On this day', () => _openMomentsPage()),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Row(children: [
          const Icon(Icons.auto_awesome, size: 18),
          const SizedBox(width: 7),
          Expanded(child: Text(
            years == 1 ? 'A little memory from a previous year' : '$years years of memories from this day',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          )),
        ]),
      ),
      _memoryStrip(memories.take(12).toList()),
    ]);
  }

  void _openMomentsPage() {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => MomentsPage(
        photos: photos,
        names: names,
        captions: captions,
        favorites: favorites,
        onToggleFavorite: (a) async {
          setState(() {
            if (favorites.contains(a.id)) { favorites.remove(a.id); } else { favorites.add(a.id); }
          });
          await _save();
        },
        onEdit: _openPhotoEditor,
        onShare: (a) => _share([a], 'Shared from Little Memories'),
      ),
    ));
  }

  Widget _smartAlbums() {
    final groups = <String, List<AssetEntity>>{};
    for (final a in photos) {
      final d = a.createDateTime;
      final key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
      groups.putIfAbsent(key, () => []).add(a);
    }
    final entries = groups.entries.take(6).toList();
    if (entries.isEmpty) return const SizedBox.shrink();
    return Column(children: [
      _sectionTitle('Smart albums', () => setState(() => showAllPhotos = true)),
      SizedBox(height: 132, child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16), scrollDirection: Axis.horizontal,
        itemCount: entries.length, separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final e = entries[i]; final parts = e.key.split('-');
          final label = '${parts[0]} • ${_monthName(int.parse(parts[1]))}';
          return GestureDetector(onTap: () => _openPhoto(e.value.first, e.value), child: SizedBox(width: 150,
            child: ClipRRect(borderRadius: BorderRadius.circular(16), child: Stack(fit: StackFit.expand, children: [
              Thumb(e.value.first),
              Positioned(left: 10, right: 10, bottom: 10, child: Text('$label\n${e.value.length} memories', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, shadows: [Shadow(blurRadius: 6)]))),
            ])),));
        },
      )),
    ]);
  }

  String _monthName(int month) {
    const names = ['January','February','March','April','May','June','July','August','September','October','November','December'];
    return names[month - 1];
  }

  Widget _memoryStrip(List<AssetEntity> items, {String emptyText = 'No memories yet'}) {
    if (items.isEmpty) return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      child: Text(emptyText, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
    );
    return SizedBox(
      height: 142,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final a = items[i];
          return GestureDetector(
            onTap: () => _openPhoto(a, items),
            child: SizedBox(
              width: 118,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(fit: StackFit.expand, children: [
                  Thumb(a),
                  Positioned(left: 8, right: 8, bottom: 8, child: Text(
                    names[a.id] ?? a.title ?? 'Memory',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, shadows: [Shadow(blurRadius: 5)]),
                  )),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _experienceHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Your memories', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onSurface)),
          const SizedBox(height: 3),
          Text('Moments worth keeping close', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ])),
        Container(
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, shape: BoxShape.circle),
          child: IconButton(onPressed: () => setState(() => tab = 3), icon: const Icon(Icons.settings_outlined), tooltip: 'Settings'),
        ),
      ]),
    );
  }

  Widget _modernQuickActions() {
    final List<Map<String, dynamic>> actions = [
      {'icon': Icons.search, 'label': 'Find a memory', 'onTap': () => setState(() => showAllPhotos = true)},
      {'icon': Icons.favorite_rounded, 'label': 'Favorites', 'onTap': () => setState(() => tab = 2)},
      {'icon': Icons.collections_bookmark_rounded, 'label': 'Albums', 'onTap': () => setState(() => tab = 1)},
      {'icon': Icons.auto_awesome, 'label': 'On this day', 'onTap': _openMomentsPage},
    ];
    return SizedBox(
      height: 92,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: actions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final a = actions[i];
          return InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: a['onTap'] as VoidCallback,
            child: Container(
              width: 142,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                color: Theme.of(context).colorScheme.surface,
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(a['icon'] as IconData, size: 23),
                const Spacer(),
                Text(a['label'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
            ),
          );
        },
      ),
    );
  }

  Widget _dashboard() {
    final recent = photos.take(12).toList();
    final favs = photos.where((a) => favorites.contains(a.id)).take(12).toList();
    return RefreshIndicator(
      onRefresh: _refreshPhotos,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          _experienceHeader(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Card(
              elevation: 0,
              color: Theme.of(context).colorScheme.primaryContainer,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                leading: const CircleAvatar(child: Icon(Icons.child_care_outlined)),
                title: Text('Hello, ' + childName + ' ❤️', style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text(photos.isEmpty ? 'Your memory story starts here.' : photos.length.toString() + ' memories waiting to be rediscovered.'),
                trailing: IconButton(onPressed: _editChildProfile, icon: const Icon(Icons.edit_outlined)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(children: [
              Expanded(child: _statCard(Icons.photo_library_outlined, photos.length.toString(), 'Memories')),
              const SizedBox(width: 10),
              Expanded(child: _statCard(Icons.favorite, favs.length.toString(), 'Favorites')),
              const SizedBox(width: 10),
              Expanded(child: _statCard(Icons.auto_stories_outlined, _albumCount().toString(), 'Albums')),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Quick access', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              TextButton(onPressed: () => setState(() => showAllPhotos = true), child: const Text('All photos')),
            ]),
          ),
          _modernQuickActions(),
          _sectionTitle('Recent memories', () => setState(() => showAllPhotos = true)),
          _memoryStrip(recent, emptyText: 'Add photos to your phone gallery to see them here.'),
          _smartAlbums(),
          _onThisDay(),
          if (favs.isNotEmpty) ...[
            _sectionTitle('Favorite memories', () => setState(() => tab = 2)),
            _memoryStrip(favs),
          ],
        ],
      ),
    );
  }

  int _albumCount(){final s=<String>{};for(final a in photos){final d=a.createDateTime;s.add(d.year.toString()+'-'+d.month.toString());}return s.length;}

  Widget _statCard(IconData icon, String value, String label) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Column(children: [
        Icon(icon, size: 21),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
        Text(label, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    ),
  );

  Widget _quickAction(IconData icon, String label, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.only(right: 10),
    child: FilledButton.tonalIcon(onPressed: onTap, icon: Icon(icon), label: Text(label)),
  );

  Widget _sectionTitle(String title, VoidCallback onSeeAll) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 10, 6),
    child: Row(children: [
      Expanded(child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
      TextButton(onPressed: onSeeAll, child: const Text('See all')),    ]),
  );

  Widget _albumsTab() {
    final groups=<String,List<AssetEntity>>{};
    for(final a in photos){final d=a.createDateTime;final k=d.year.toString()+'-'+d.month.toString().padLeft(2,'0');groups.putIfAbsent(k,()=>[]).add(a);}
    final entries=groups.entries.toList()..sort((a,b)=>b.key.compareTo(a.key));
    return ListView(padding:const EdgeInsets.fromLTRB(16,12,16,30),children:[
      Row(children:[Expanded(child:Text('Albums',style:const TextStyle(fontSize:30,fontWeight:FontWeight.w900))),Icon(Icons.auto_stories_rounded,color:Theme.of(context).colorScheme.primary)]),
      const SizedBox(height:6),Text('Your memories, organized into colorful comic-style chapters.',style:TextStyle(color:Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height:14),
      Row(children:[Expanded(child:FilledButton.icon(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>DuplicatePhotosPage(photos:photos))),icon:const Icon(Icons.copy_all_outlined),label:const Text('Duplicates'))),const SizedBox(width:10),Expanded(child:FilledButton.tonalIcon(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>BlurryPhotosPage(photos:photos))),icon:const Icon(Icons.blur_on),label:const Text('Blurry')))]),
      const SizedBox(height:14),
      ...entries.map((e){final parts=e.key.split('-');final title=parts[0]+' • '+_monthName(int.parse(parts[1]));return Card(clipBehavior:Clip.antiAlias,child:InkWell(onTap:()=>_openPhoto(e.value.first,e.value),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[SizedBox(height:190,width:double.infinity,child:Stack(fit:StackFit.expand,children:[Thumb(e.value.first),Positioned(left:12,bottom:12,child:DecoratedBox(decoration:BoxDecoration(color:Colors.black54,borderRadius:BorderRadius.circular(12)),child:Padding(padding:const EdgeInsets.symmetric(horizontal:12,vertical:7),child:Text(title,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w900,fontSize:16)))))])),Padding(padding:const EdgeInsets.all(14),child:Row(children:[Expanded(child:Text(e.value.length.toString()+' memories',style:const TextStyle(fontWeight:FontWeight.w800))),const Icon(Icons.chevron_right)]))])));})
    ]);
  }

  Widget _gallery({bool onlyFavorites = false}) {
    final q = searchQuery.trim().toLowerCase();
    final storyIds = timelines.expand((t) => t.assets).toSet();
    var source = photos.where((a) => !hiddenIds.contains(a.id)).toList();
    if (onlyFavorites || galleryFilter == 1) source = source.where((a) => favorites.contains(a.id)).toList();
    if (galleryFilter == 2) source = source.where((a) => (names[a.id] ?? '').trim().isNotEmpty).toList();
    if (galleryFilter == 3) source = source.where((a) => (captions[a.id] ?? '').trim().isNotEmpty).toList();
    if (galleryFilter == 4) source = source.where((a) => storyIds.contains(a.id)).toList();
    source = source.where((a) {
      final text = ((names[a.id] ?? a.title ?? 'Photo') + ' ' + (captions[a.id] ?? '')).toLowerCase();
      return q.isEmpty || text.contains(q) || a.createDateTime.year.toString() == q;
    }).toList();
    source.sort((a, b) => galleryNewestFirst ? b.createDateTime.compareTo(a.createDateTime) : a.createDateTime.compareTo(b.createDateTime));
    if (source.isEmpty) return Center(child: Text(q.isEmpty ? (onlyFavorites ? 'No favorite memories yet.' : 'No memories match this filter.') : 'No memories match "' + searchQuery + '".'));
    return RefreshIndicator(onRefresh: _refreshPhotos, child: GridView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 28),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: grid, crossAxisSpacing: 5, mainAxisSpacing: 5),
      itemCount: source.length,
      itemBuilder: (_, i) {
        final a = source[i], fav = favorites.contains(a.id);
        return GestureDetector(
          onTap: () => selectionMode ? _toggleSelection(a) : _openPhoto(a, source),
          onLongPress: () => _toggleSelection(a),
          child: Stack(fit: StackFit.expand, children: [
            ClipRRect(borderRadius: BorderRadius.circular(9), child: Thumb(a)),
            if (galleryShowNames && grid <= 3) Positioned(left: 6, right: 6, bottom: 6, child: Text(names[a.id] ?? a.title ?? 'Memory', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, shadows: [Shadow(blurRadius: 6)]))),
            if (fav) const Positioned(right: 6, top: 6, child: Icon(Icons.favorite, color: Colors.white, shadows: [Shadow(blurRadius: 5)])),
            if (selectedIds.contains(a.id)) Positioned.fill(child: Container(
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary.withOpacity(.28), borderRadius: BorderRadius.circular(9), border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3)),
              child: const Align(alignment: Alignment.topRight, child: Padding(padding: EdgeInsets.all(6), child: CircleAvatar(radius: 14, child: Icon(Icons.check, size: 17)))),
            )),
          ]),
        );
      },
    ));
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
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TimelinePage(
              t: t, find: _find, grid: grid, onEdit: _openPhotoEditor,
              onShare: (a) => _share([a], t.title),
              onAddPhotos: () => _addToTimeline(t),
              onEditTimeline: () => _createTimeline(existing: t),
              onSave: _save,
              nameFor: (id) => names[id] ?? _find(id)?.title ?? 'Memory',
                    captionFor: (id) => captions[id] ?? '',
                    isFavorite: (id) => favorites.contains(id),
                    onToggleFavorite: (a) async {
                      setState(() {
                        if (favorites.contains(a.id)) { favorites.remove(a.id); } else { favorites.add(a.id); }
                      });
                      await _save();
                    },
            ))),
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
    final galleryBody = showAllPhotos
      ? Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 4), child: Row(children: [
            IconButton(onPressed: () => setState(() => showAllPhotos = false), icon: const Icon(Icons.arrow_back)),
            const Expanded(child: Text('All memories', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
          ])),
          Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 6), child: TextField(
            controller: searchController,
            onChanged: (v) => setState(() => searchQuery = v),
            decoration: InputDecoration(
              hintText: 'Search memories',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: searchQuery.isEmpty ? null : IconButton(onPressed: () { searchController.clear(); setState(() => searchQuery = ''); }, icon: const Icon(Icons.clear)),
              filled: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            ),
          )),
          Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 4), child: Row(children: [
            Expanded(child: Text(photos.length.toString() + ' memories', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600))),
            IconButton(tooltip: galleryNewestFirst ? 'Showing newest first' : 'Showing oldest first', onPressed: () => setState(() => galleryNewestFirst = !galleryNewestFirst), icon: Icon(galleryNewestFirst ? Icons.south_rounded : Icons.north_rounded)),
            IconButton(tooltip: galleryShowNames ? 'Hide names' : 'Show names', onPressed: () => setState(() => galleryShowNames = !galleryShowNames), icon: Icon(galleryShowNames ? Icons.text_fields : Icons.text_fields_outlined)),
            PopupMenuButton<int>(tooltip: 'Grid size', initialValue: grid, onSelected: (v) => setState(() => grid = v), itemBuilder: (_) => [2,3,4,5,6].map((v) => PopupMenuItem(value: v, child: Text('$v columns'))).toList(), child: const Icon(Icons.grid_view_rounded)),
          ])),
          SizedBox(height: 42, child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12), scrollDirection: Axis.horizontal,
            children: [
              for (final f in const [0, 1, 2, 3, 4])
                Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(
                  label: Text(['All', 'Favorites', 'Named', 'Captions', 'In stories'][f]),
                  selected: galleryFilter == f,
                  onSelected: (_) async { setState(() => galleryFilter = f); await _save(); },
                )),
            ],
          )),
          Expanded(child: _gallery()),
        ])
      : _dashboard();
    final body = tab == 0 ? galleryBody : tab == 1 ? _albumsTab() : tab == 2 ? _gallery(onlyFavorites: true) : SettingsPage(
      grid: grid, dark: Theme.of(context).brightness == Brightness.dark, themeIndex: widget.themeIndex,
      onGrid: (v) { setState(() => grid = v); _save(); },
      onDark: widget.onDark, onTheme: widget.onTheme,
      onShare: () => _share(photos, 'My Little Memories'),
      childName: childName,
      childBirthday: childBirthday,
      onChildEdit: _editChildProfile,
      onPcConnect: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PcConnectPage(photos: photos, timelines: timelines, names: names, captions: captions, onBackupStarted: _recordBackup))),
      backupHistory: backupHistory,
      onBackup: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PcConnectPage(photos: photos, timelines: timelines, names: names, captions: captions, onBackupStarted: _recordBackup, startBackupMode: true))),
    );
    return Scaffold(
      appBar: AppBar(
        title: selectionMode ? Text('${selectedIds.length} selected', style: const TextStyle(fontWeight: FontWeight.w800)) : const Text('Little Memories', style: TextStyle(fontWeight: FontWeight.w800)),
        leading: selectionMode ? IconButton(onPressed: _clearSelection, icon: const Icon(Icons.close)) : null,
        actions: selectionMode
            ? [
                IconButton(onPressed: _bulkFavorite, tooltip: 'Favorite', icon: const Icon(Icons.favorite_border)),
                IconButton(onPressed: _bulkShare, tooltip: 'Share', icon: const Icon(Icons.share_outlined)),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'hide') _hideSelected();
                    if (v == 'all') setState(() => selectedIds = photos.map((a) => a.id).toSet());
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'hide', child: Text('Move to Private / Hidden')),
                    PopupMenuItem(value: 'all', child: Text('Select all memories')),
                  ],
                ),
              ]
            : [IconButton(onPressed: _refreshPhotos, icon: const Icon(Icons.refresh))],
      ),
      body: body,
      floatingActionButton: tab == 0 && !selectionMode ? FloatingActionButton.extended(
        onPressed: () => showModalBottomSheet(
          context: context,
          builder: (_) => SafeArea(child: Wrap(children: [
            const ListTile(title: Text('Memory tools', style: TextStyle(fontWeight: FontWeight.w900))),
            ListTile(leading: const Icon(Icons.insights_rounded), title: const Text('Memory statistics'), onTap: () { Navigator.pop(context); _memoryStatistics(); }),
            ListTile(leading: const Icon(Icons.content_copy_rounded), title: const Text('Find likely duplicates'), onTap: () { Navigator.pop(context); _smartDuplicateScan(); }),
            ListTile(leading: const Icon(Icons.lock_outline_rounded), title: const Text('Private / Hidden memories'), onTap: () { Navigator.pop(context); _showHiddenMemories(); }),
            ListTile(leading: const Icon(Icons.slideshow_rounded), title: const Text('Play memory slideshow'), onTap: () { Navigator.pop(context); _startSlideshow(); }),
            ListTile(leading: const Icon(Icons.auto_awesome_rounded), title: const Text('Ultimate Memory Center'), subtitle: const Text('Albums • milestones • storage • export • family tools'), onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => UltimateMemoryCenter(photos: photos, favorites: favorites, timelines: timelines, names: names, captions: captions, hiddenIds: hiddenIds))); }),
            ListTile(leading: const Icon(Icons.share_rounded), title: const Text('Share memory collection'), onTap: () { Navigator.pop(context); _shareMemoryCollection(); }),
          ])),
        ),
        icon: const Icon(Icons.auto_awesome_rounded),
        label: const Text('Memory tools'),
      ) : null,
      bottomNavigationBar: selectionMode
          ? null
          : NavigationBar(
        selectedIndex: tab, onDestinationSelected: (v) => setState(() { tab = v; if (v == 0) showAllPhotos = false; }),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.photo_library_outlined), selectedIcon: Icon(Icons.photo_library), label: 'Gallery'),
          NavigationDestination(icon: Icon(Icons.collections_bookmark_outlined), selectedIcon: Icon(Icons.collections_bookmark), label: 'Albums'),
          NavigationDestination(icon: Icon(Icons.favorite_border), selectedIcon: Icon(Icons.favorite), label: 'Favorites'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}


class PcConnectPage extends StatefulWidget {
  final List<AssetEntity> photos;
  final List<Timeline> timelines;
  final Map<String, String> names;
  final Map<String, String> captions;
  final VoidCallback onBackupStarted;
  final bool startBackupMode;
  const PcConnectPage({super.key, required this.photos, required this.timelines, required this.names, required this.captions, required this.onBackupStarted, this.startBackupMode = false});
  @override State<PcConnectPage> createState() => _PcConnectPageState();
}
class _PcConnectPageState extends State<PcConnectPage> {
  PcConnectService? service;
  bool starting = true;
  String? error;
  DateTime? connectedAt;

  @override void initState() { super.initState(); _start(); }
  Future<void> _start() async {
    setState(() { starting = true; error = null; });
    final pairingKey = await PcConnectService.loadPairingKey();
    final s = PcConnectService(photos: widget.photos, timelines: widget.timelines, names: widget.names, captions: widget.captions, pairingKey: pairingKey, onConnected: () { if (mounted) setState(() => connectedAt = DateTime.now()); }, onBackupStarted: widget.onBackupStarted);
    try {
      await s.start();
      if (mounted) setState(() { service = s; starting = false; });
    } catch (e) {
      await s.stop();
      if (mounted) setState(() { error = e.toString(); starting = false; });
    }
  }
  @override void dispose() { service?.stop(); super.dispose(); }

  @override Widget build(BuildContext context) {
    final url = service?.url;
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to Windows PC')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(children: [
          const Icon(Icons.wifi, size: 42),
          const SizedBox(height: 8),
          const Text('Same Wi-Fi connection required', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          const SizedBox(height: 6),
          Text(starting ? 'Starting secure local transfer server…' : error != null ? 'Could not start: $error' : 'Your photos never leave your local network.'),
        ]))),
        if (starting) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (error != null) FilledButton.icon(onPressed: _start, icon: const Icon(Icons.refresh), label: const Text('Try again')),
        if (url != null) ...[
          const SizedBox(height: 18),
          Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(children: [
            const Text('1. Scan this QR code on your PC', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Container(padding: const EdgeInsets.all(12), color: Colors.white, child: QrImageView(data: url, size: 230, version: QrVersions.auto)),
            const SizedBox(height: 12),
            const Text('Or type this address in Chrome/Edge:', textAlign: TextAlign.center),
            const SizedBox(height: 6),
            SelectableText(url, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
          ]))),
          const SizedBox(height: 12),          Card(child: ListTile(leading: const Icon(Icons.photo_library_outlined), title: Text('${widget.photos.length} photos ready'), subtitle: Text(widget.startBackupMode ? 'Backup mode: download every photo to Windows.' : 'Preview, select and download photos and complete timelines.'))),
          if (widget.startBackupMode) Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Full PC backup', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            const SizedBox(height: 6),
            const Text('Download all memories from this phone to the connected Windows PC.'),
            const SizedBox(height: 12),
            FilledButton.icon(onPressed: () { widget.onBackupStarted(); }, icon: const Icon(Icons.backup_outlined), label: const Text('Open full backup page')),
          ]))),
          if (connectedAt != null) Card(child: ListTile(leading: const Icon(Icons.check_circle_outline), title: const Text('PC connected'), subtitle: Text('Last activity: ${connectedAt!.hour.toString().padLeft(2, '0')}:${connectedAt!.minute.toString().padLeft(2, '0')}'))),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: () async { await service?.stop(); if (mounted) setState(() => service = null); }, icon: const Icon(Icons.stop_circle_outlined), label: const Text('Stop PC connection')),
        ],
        const SizedBox(height: 16),
        const Card(child: Padding(padding: EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('What you can do', style: TextStyle(fontWeight: FontWeight.w800)),
          SizedBox(height: 8),
          Text('• Preview your phone photos on Windows\\n• Select individual memories\\n• Download selected photos\\n• Download an entire timeline\\n• No cloud upload\\n• Connection is protected by a temporary QR token'),
        ]))),
      ]),
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

class DuplicatePhotosPage extends StatefulWidget {
  final List<AssetEntity> photos; const DuplicatePhotosPage({super.key,required this.photos});
  @override State<DuplicatePhotosPage> createState()=>_DuplicatePhotosPageState();
}
class _DuplicatePhotosPageState extends State<DuplicatePhotosPage>{
  bool scanning=true; Map<String,List<AssetEntity>> groups={};
  @override void initState(){super.initState();_scan();}
  Future<void> _scan() async {final bySize=<int,List<AssetEntity>>{};for(final a in widget.photos){try{final f=await a.file;if(f!=null)bySize.putIfAbsent(await f.length(),()=>[]).add(a);}catch(_){}}
    final out=<String,List<AssetEntity>>{};for(final e in bySize.entries.where((x)=>x.value.length>1)){for(final a in e.value){try{final f=await a.file;if(f!=null){final h=sha256.convert(await f.readAsBytes()).toString();out.putIfAbsent(h,()=>[]).add(a);}}catch(_){}}}
    if(mounted)setState((){groups=Map.fromEntries(out.entries.where((e)=>e.value.length>1));scanning=false;});
  }
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Duplicate Photos')),body:scanning?const Center(child:Column(mainAxisSize:MainAxisSize.min,children:[CircularProgressIndicator(),SizedBox(height:14),Text('Scanning for exact duplicate photos…')])):groups.isEmpty?const Center(child:Text('No exact duplicate photos found.')):ListView(padding:const EdgeInsets.all(12),children:[const Padding(padding:EdgeInsets.all(8),child:Text('Exact duplicates are grouped by SHA-256. Nothing is deleted automatically.',style:TextStyle(fontWeight:FontWeight.w700))),...groups.values.map((g)=>Card(child:Padding(padding:const EdgeInsets.all(10),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(g.length.toString()+' identical copies',style:const TextStyle(fontWeight:FontWeight.w900)),const SizedBox(height:8),SizedBox(height:120,child:ListView.separated(scrollDirection:Axis.horizontal,itemCount:g.length,separatorBuilder:(_,__)=>const SizedBox(width:8),itemBuilder:(_,i)=>SizedBox(width:120,child:ClipRRect(borderRadius:BorderRadius.circular(14),child:Thumb(g[i])))))]))))]) );
}

class BlurryPhotosPage extends StatefulWidget {
  final List<AssetEntity> photos; const BlurryPhotosPage({super.key,required this.photos});
  @override State<BlurryPhotosPage> createState()=>_BlurryPhotosPageState();
}
class _BlurryPhotosPageState extends State<BlurryPhotosPage>{
  bool scanning=true; List<AssetEntity> blurry=[];
  @override void initState(){super.initState();_scan();}
  Future<void> _scan() async {final out=<AssetEntity>[];for(final a in widget.photos){try{final bytes=await a.thumbnailDataWithSize(const ThumbnailSize(160,160));if(bytes==null)continue;final decoded=img.decodeImage(bytes);if(decoded==null)continue;double total=0,sq=0;int n=0;for(int y=1;y<decoded.height-1;y+=2){for(int x=1;x<decoded.width-1;x+=2){final c=decoded.getPixel(x,y);final lum=.299*c.r+.587*c.g+.114*c.b;final r=decoded.getPixel(x+1,y);final rr=.299*r.r+.587*r.g+.114*r.b;final d=decoded.getPixel(x,y+1);final dd=.299*d.r+.587*d.g+.114*d.b;final edge=(lum-rr).abs()+(lum-dd).abs();total+=edge;sq+=edge*edge;n++;}}if(n>0){final avg=total/n;final variance=(sq/n)-(avg*avg);if(avg<11.5&&variance<70)out.add(a);}}catch(_){}if(mounted)setState(()=>blurry=List.of(out));}if(mounted)setState(()=>scanning=false);}
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Blurry Photos')),body:scanning?const Center(child:Column(mainAxisSize:MainAxisSize.min,children:[CircularProgressIndicator(),SizedBox(height:14),Text('Analyzing photo sharpness on device…')])):blurry.isEmpty?const Center(child:Text('No likely blurry photos found.')):GridView.builder(padding:const EdgeInsets.all(10),gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:3,crossAxisSpacing:6,mainAxisSpacing:6),itemCount:blurry.length,itemBuilder:(_,i)=>Stack(fit:StackFit.expand,children:[ClipRRect(borderRadius:BorderRadius.circular(14),child:Thumb(blurry[i])),const Positioned(left:6,top:6,child:Chip(label:Text('Blurry')))])));
}

class TimelinePage extends StatefulWidget {
  final Timeline t;
  final AssetEntity? Function(String) find;
  final int grid;
  final Future<void> Function(AssetEntity) onEdit;
  final Future<void> Function(AssetEntity) onShare;
  final Future<void> Function() onAddPhotos;
  final Future<void> Function() onEditTimeline;
  final Future<void> Function() onSave;
  final String Function(String) nameFor;
  final String Function(String) captionFor;
  final bool Function(String) isFavorite;
  final Future<void> Function(AssetEntity) onToggleFavorite;
  const TimelinePage({super.key, required this.t, required this.find, required this.grid, required this.onEdit, required this.onShare, required this.onAddPhotos, required this.onEditTimeline, required this.onSave, required this.nameFor, required this.captionFor, required this.isFavorite, required this.onToggleFavorite});
  @override State<TimelinePage> createState() => _TimelinePageState();
}
class _TimelinePageState extends State<TimelinePage> {
  List<AssetEntity> get imgs {
    final list = widget.t.assets.map(widget.find).whereType<AssetEntity>().toList();
    list.sort((a, b) => a.createDateTime.compareTo(b.createDateTime));
    return list;
  }
  String _date(DateTime d) => '${_month(d.month)} ${d.day}, ${d.year}';
  String _month(int m) => const ['January','February','March','April','May','June','July','August','September','October','November','December'][m - 1];

  Future<void> _changeCover() async {
    final list = imgs;
    if (list.isEmpty) return;
    final picked = await showModalBottomSheet<AssetEntity>(
      context: context, showDragHandle: true,
      builder: (_) => SafeArea(child: SizedBox(height: 330, child: Column(children: [
        const ListTile(title: Text('Choose cover photo', style: TextStyle(fontWeight: FontWeight.w800))),
        Expanded(child: GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, crossAxisSpacing: 6, mainAxisSpacing: 6),
          itemCount: list.length,
          itemBuilder: (_, i) => GestureDetector(onTap: () => Navigator.pop(context, list[i]), child: ClipRRect(borderRadius: BorderRadius.circular(10), child: Thumb(list[i]))),
        )),
      ]))),
    );
    if (picked != null) { setState(() => widget.t.coverId = picked.id); await widget.onSave(); }
  }

  @override Widget build(BuildContext context) {
    final list = imgs;
    final cover = widget.t.coverId == null ? (list.isEmpty ? null : list.first) : widget.find(widget.t.coverId!);
    DateTime? first, last;
    if (list.isNotEmpty) { first = list.first.createDateTime; last = list.last.createDateTime; }
    final range = first == null ? 'No memories yet' : first.year == last!.year && first.month == last!.month && first.day == last.day ? _date(first) : '${_date(first)} – ${_date(last)}';
    return Scaffold(
      appBar: AppBar(title: Text(widget.t.title), actions: [
        IconButton(onPressed: widget.onEditTimeline, tooltip: 'Edit timeline', icon: const Icon(Icons.edit_outlined)),
        IconButton(onPressed: widget.onAddPhotos, tooltip: 'Add photos', icon: const Icon(Icons.add_photo_alternate_outlined)),
      ]),
      body: CustomScrollView(slivers: [
        SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(16,12,16,8), child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: SizedBox(height: 245, child: Stack(fit: StackFit.expand, children: [
            if (cover != null) Thumb(cover) else Container(color: Theme.of(context).colorScheme.surfaceContainerHighest, child: const Icon(Icons.auto_stories_outlined, size: 72)),
            Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black])))),
            Positioned(left: 18, right: 18, bottom: 18, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.t.title, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900)),
              const SizedBox(height: 5),
              Text('${list.length} memories • $range', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ])),
            Positioned(top: 12, right: 12, child: FilledButton.tonalIcon(onPressed: _changeCover, icon: const Icon(Icons.image_outlined), label: const Text('Cover'))),
          ])),
        ))),
        if (widget.t.description.isNotEmpty) SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(18,4,18,12), child: Text(widget.t.description, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 15)))),
        SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(16,4,16,8), child: Row(children: [
          Expanded(child: FilledButton.icon(onPressed: widget.onAddPhotos, icon: const Icon(Icons.add_photo_alternate_outlined), label: const Text('Manage photos'))),
          const SizedBox(width: 10),
          Expanded(child: OutlinedButton.icon(onPressed: list.isEmpty ? null : () => widget.onShare(list.first), icon: const Icon(Icons.share_outlined), label: const Text('Share'))),
        ]))),
        if (list.isEmpty) const SliverFillRemaining(hasScrollBody: false, child: Center(child: Text('Add memories to this timeline to get started.')))
        else SliverPadding(padding: const EdgeInsets.all(8), sliver: SliverGrid(
          delegate: SliverChildBuilderDelegate((_, i) => GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => Viewer(asset: list[i], all: list, onEdit: widget.onEdit, onShare: widget.onShare, memoryName: widget.nameFor(list[i].id), caption: widget.captionFor(list[i].id), favorite: widget.isFavorite(list[i].id), onToggleFavorite: () => widget.onToggleFavorite(list[i])))),
            child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Thumb(list[i])),
          ), childCount: list.length),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: widget.grid, crossAxisSpacing: 5, mainAxisSpacing: 5),
        )),
      ]),
    );
  }
}

class MomentsPage extends StatelessWidget {
  final List<AssetEntity> photos;
  final Map<String, String> names;
  final Map<String, String> captions;
  final Set<String> favorites;
  final Future<void> Function(AssetEntity) onToggleFavorite;
  final Future<void> Function(AssetEntity) onEdit;
  final Future<void> Function(AssetEntity) onShare;

  const MomentsPage({
    super.key, required this.photos, required this.names, required this.captions,
    required this.favorites, required this.onToggleFavorite, required this.onEdit, required this.onShare,
  });

  List<AssetEntity> _memories() {
    final now = DateTime.now();
    final list = photos.where((a) {
      final d = a.createDateTime;
      return d.month == now.month && d.day == now.day && d.year < now.year;
    }).toList();
    list.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
    return list;
  }

  String _date(DateTime d) {
    const months=['January','February','March','April','May','June','July','August','September','October','November','December'];
    return months[d.month - 1] + ' ' + d.day.toString() + ', ' + d.year.toString();
  }

  @override
  Widget build(BuildContext context) {
    final memories=_memories();
    final grouped=<int,List<AssetEntity>>{};
    for(final a in memories){ grouped.putIfAbsent(a.createDateTime.year,()=>[]).add(a); }
    final years=grouped.keys.toList()..sort((a,b)=>b.compareTo(a));
    final now=DateTime.now();
    return Scaffold(
      appBar: AppBar(title: const Text('On this day'), actions: [
        if(memories.isNotEmpty) Padding(padding: const EdgeInsets.only(right:16), child: Center(child: Text(memories.length.toString()+' memories'))),
      ]),
      body: memories.isEmpty
        ? const Center(child: Text('No memories from this day in previous years yet.'))
        : ListView(padding: const EdgeInsets.fromLTRB(16,12,16,30), children: [
            Card(child: Padding(padding: const EdgeInsets.all(18), child: Row(children: [
              const Icon(Icons.auto_awesome,size:30), const SizedBox(width:14),
              Expanded(child: Text('Look back at '+now.day.toString()+' '+_monthName(now.month)+' — moments captured in previous years.', style: const TextStyle(fontWeight:FontWeight.w700))),
            ]))),
            const SizedBox(height:14),
            ...years.map((year)=>Padding(
              padding: const EdgeInsets.only(bottom:22),
              child: Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
                Text(year.toString(),style:const TextStyle(fontSize:22,fontWeight:FontWeight.w900)),
                const SizedBox(height:8),
                GridView.builder(
                  shrinkWrap:true, physics:const NeverScrollableScrollPhysics(), itemCount:grouped[year]!.length,
                  gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:3,crossAxisSpacing:6,mainAxisSpacing:6),
                  itemBuilder:(_,i){
                    final a=grouped[year]![i];
                    return GestureDetector(
                      onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>Viewer(
                        asset:a, all:grouped[year]!, onEdit:onEdit, onShare:onShare,
                        memoryName:names[a.id]??a.title??'Memory', caption:captions[a.id]??'',
                        favorite:favorites.contains(a.id),
                        nameFor:(id)=>names[id]??'Memory', captionFor:(id)=>captions[id]??'',
                        isFavorite:(id)=>favorites.contains(id), onToggleFavoriteAsset:onToggleFavorite,
                      ))),
                      child:ClipRRect(borderRadius:BorderRadius.circular(10),child:Stack(fit:StackFit.expand,children:[
                        Thumb(a),
                        Positioned(left:7,right:7,bottom:7,child:Text(_date(a.createDateTime),maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white,fontSize:11,fontWeight:FontWeight.w700,shadows:[Shadow(blurRadius:5)]))),
                        if(favorites.contains(a.id)) const Positioned(top:7,right:7,child:Icon(Icons.favorite,color:Colors.white,size:18)),
                      ])),
                    );
                  },
                ),
              ]),
            )),
          ]),
    );
  }

  String _monthName(int m)=>const ['January','February','March','April','May','June','July','August','September','October','November','December'][m-1];
}

class Viewer extends StatefulWidget {  final AssetEntity asset;
  final List<AssetEntity> all;
  final Future<void> Function(AssetEntity) onEdit;
  final Future<void> Function(AssetEntity) onShare;
  final String? memoryName;
  final String? caption;
  final bool favorite;
  final String Function(String id)? nameFor;
  final String Function(String id)? captionFor;
  final bool Function(String id)? isFavorite;
  final Future<void> Function(AssetEntity)? onToggleFavoriteAsset;
  final Future<void> Function()? onToggleFavorite;
  const Viewer({
    super.key,
    required this.asset,
    required this.all,
    required this.onEdit,
    required this.onShare,
    this.memoryName,
    this.caption,
    this.favorite = false,
    this.nameFor,
    this.captionFor,
    this.isFavorite,
    this.onToggleFavoriteAsset,
    this.onToggleFavorite,
  });
  @override State<Viewer> createState() => _ViewerState();
}
class _ViewerState extends State<Viewer> {
  late int index;
  late final PageController controller;

  @override void initState() {
    super.initState();
    index = widget.all.indexOf(widget.asset);
    if (index < 0) index = 0;
    controller = PageController(initialPage: index);
  }

  @override Widget build(BuildContext context) {
    final current = widget.all[index];
    final currentName = widget.nameFor?.call(current.id) ?? (index == widget.all.indexOf(widget.asset) ? widget.memoryName : current.title);
    final currentCaption = widget.captionFor?.call(current.id) ?? (index == widget.all.indexOf(widget.asset) ? widget.caption : null);
    final currentFavorite = widget.isFavorite?.call(current.id) ?? (index == widget.all.indexOf(widget.asset) ? widget.favorite : false);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${index + 1}/${widget.all.length}'),
        actions: [
          if (widget.onToggleFavoriteAsset != null || widget.onToggleFavorite != null)
            IconButton(
              onPressed: () async {
                if (widget.onToggleFavoriteAsset != null) {
                  await widget.onToggleFavoriteAsset!(current);
                  if (mounted) setState(() {});
                } else {
                  await widget.onToggleFavorite!();
                  if (mounted) setState(() {});
                }
              },
              tooltip: currentFavorite ? 'Remove favorite' : 'Add favorite',
              icon: Icon(currentFavorite ? Icons.favorite : Icons.favorite_border),
            ),
          IconButton(onPressed: () => widget.onEdit(current), tooltip: 'Edit photo', icon: const Icon(Icons.tune_outlined)),
          IconButton(onPressed: () => widget.onShare(current), tooltip: 'Share', icon: const Icon(Icons.share_outlined)),
        ],
      ),
      body: Stack(
        children: [
          PageView.builder(
            controller: controller,
            itemCount: widget.all.length,
            onPageChanged: (i) => setState(() => index = i),
            itemBuilder: (_, i) => FutureBuilder<File?>(
              future: widget.all[i].file,
              builder: (_, s) => s.hasData
                  ? InteractiveViewer(child: Center(child: Image.file(s.data!, fit: BoxFit.contain)))
                  : const Center(child: CircularProgressIndicator()),
            ),
          ),
          Positioned(
            left: 12, right: 12, bottom: 12,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.72),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white.withOpacity(.12)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      currentName?.trim().isNotEmpty == true ? currentName! : 'Memory',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(_dateLabel(current.createDateTime), style: TextStyle(color: Colors.white.withOpacity(.72), fontSize: 12)),
                    if (currentCaption?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: 7),
                      Text(currentCaption!, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 14)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _dateLabel(DateTime d) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year} • ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override void dispose() {
    controller.dispose();
    super.dispose();
  }
}

class SettingsPage extends StatelessWidget {
  final int grid; final bool dark; final int themeIndex; final ValueChanged<int> onGrid; final ValueChanged<int> onTheme; final ValueChanged<bool> onDark; final VoidCallback onShare; final String childName; final String childBirthday; final VoidCallback onChildEdit; final VoidCallback onPcConnect; final VoidCallback onBackup; final List<String> backupHistory;
  const SettingsPage({super.key, required this.grid, required this.dark, required this.themeIndex, required this.onGrid, required this.onTheme, required this.onDark, required this.onShare, required this.childName, required this.childBirthday, required this.onChildEdit, required this.onPcConnect, required this.onBackup, required this.backupHistory});
  @override Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
    const Text('Professional controls', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800)),
    const SizedBox(height: 14),    Card(child:ListTile(leading:const Icon(Icons.palette_outlined),title:const Text('Comic app theme'),subtitle:Text(comicThemes[themeIndex].name),onTap:()=>showModalBottomSheet(context:context,builder:(_)=>SafeArea(child:ListView(padding:const EdgeInsets.all(16),children:[const Text('Choose your comic style',style:TextStyle(fontSize:22,fontWeight:FontWeight.w900)),const SizedBox(height:12),...List.generate(comicThemes.length,(i)=>Card(child:RadioListTile<int>(value:i,groupValue:themeIndex,title:Text(comicThemes[i].name),secondary:CircleAvatar(backgroundColor:comicThemes[i].seed),onChanged:(v){if(v!=null){onTheme(v);Navigator.pop(context);}})))]))))),
    Card(child: SwitchListTile(value: dark, onChanged: onDark, title: const Text('Dark mode'), secondary: const Icon(Icons.dark_mode_outlined))),
    Card(child: ListTile(title: const Text('Gallery grid size'), subtitle: Slider(value: grid.toDouble(), min: 2, max: 6, divisions: 4, label: grid.toString() + ' columns', onChanged: (v) => onGrid(v.round())), trailing: Text(grid.toString() + '×'))),
    Card(child: ListTile(leading: const Icon(Icons.child_care_outlined), title: Text(childName), subtitle: Text(childBirthday.isEmpty ? 'Add birthday and milestones' : 'Birthday: $childBirthday'), onTap: onChildEdit)),
    Card(child: ListTile(leading: const Icon(Icons.desktop_windows_outlined), title: const Text('Connect to Windows PC'), subtitle: const Text('Pair on the same Wi-Fi and transfer photos from your phone to your PC.'), trailing: const Icon(Icons.qr_code_2), onTap: onPcConnect)),
    Card(child: ListTile(leading: const Icon(Icons.backup_outlined), title: const Text('Backup Center'), subtitle: Text(backupHistory.isEmpty ? 'No PC backups recorded yet.' : 'Last backup: ${backupHistory.first.substring(0, 16).replaceAll('T', ' ')}'), trailing: const Icon(Icons.chevron_right), onTap: onBackup)),
    Card(child: ListTile(leading: const Icon(Icons.people_outline), title: const Text('Family collaboration'), subtitle: const Text('Private accounts, shared timelines, reactions and comments are planned for the cloud edition.'))),
    Card(child: ListTile(leading: const Icon(Icons.share_outlined), title: const Text('Share gallery'), onTap: onShare)),    const Card(child: ListTile(leading: Icon(Icons.lock_outline), title: Text('Privacy first'), subtitle: Text('Photos stay in your device library. The app stores timeline metadata locally.'))),
  ]);
}

class UltimateMemoryCenter extends StatefulWidget {
  final List<AssetEntity> photos;
  final Set<String> favorites;
  final List<Timeline> timelines;
  final Map<String,String> names;
  final Map<String,String> captions;
  final Set<String> hiddenIds;
  const UltimateMemoryCenter({super.key,required this.photos,required this.favorites,required this.timelines,required this.names,required this.captions,required this.hiddenIds});
  @override State<UltimateMemoryCenter> createState()=>_UltimateMemoryCenterState();
}

class _UltimateMemoryCenterState extends State<UltimateMemoryCenter> {
  List<String> profiles=[]; Set<String> tags={}; bool loading=true;
  @override void initState(){super.initState(); _load();}
  Future<void> _load() async { final p=await SharedPreferences.getInstance(); profiles=p.getStringList('familyProfiles')??[]; tags=(p.getStringList('memoryTags')??[]).toSet(); if(mounted)setState(()=>loading=false); }
  Future<void> _save() async { final p=await SharedPreferences.getInstance(); await p.setStringList('familyProfiles',profiles); await p.setStringList('memoryTags',tags.toList()); }
  List<MapEntry<String,List<AssetEntity>>> _albums(){final g=<String,List<AssetEntity>>{}; for(final a in widget.photos){final d=a.createDateTime; final k=d.year.toString()+'-'+d.month.toString().padLeft(2,'0'); g.putIfAbsent(k,()=>[]).add(a);} final e=g.entries.toList()..sort((a,b)=>b.key.compareTo(a.key)); return e;}
  Future<void> _milestones() async {final c=widget.photos.length,s=widget.timelines.length,f=widget.favorites.length; final m=<String>[]; for(final n in [10,25,50,100,250,500,1000,2500])if(c>=n)m.add('📸 '+n.toString()+' memories'); for(final n in [1,5,10,25])if(s>=n)m.add('📖 '+n.toString()+' stories'); if(f>=25)m.add('❤️ 25 favorites'); if(widget.hiddenIds.isNotEmpty)m.add('🔐 Private memories enabled'); await showDialog(context:context,builder:(_)=>AlertDialog(title:const Text('Milestones'),content:Text(m.isEmpty?'Your first milestone is waiting ✨':m.join('\n')),actions:[FilledButton(onPressed:()=>Navigator.pop(context),child:const Text('Done'))]));}
  Future<void> _storage() async {int total=0,count=0; for(final a in widget.photos){try{final f=await a.file;if(f!=null&&await f.exists()){total+=await f.length();count++;}}catch(_){}} final mb=total/(1024*1024); final text=mb>=1024?(mb/1024).toStringAsFixed(2)+' GB':mb.toStringAsFixed(1)+' MB'; if(!mounted)return; await showDialog(context:context,builder:(_)=>AlertDialog(title:const Text('Storage dashboard'),content:Text('Measured '+count.toString()+' files\n\n💾 '+text+'\n\nUse Duplicate Scan and PC Backup before deleting anything.'),actions:[FilledButton(onPressed:()=>Navigator.pop(context),child:const Text('Done'))]));}
  Future<void> _profiles() async {final c=TextEditingController(); await showDialog(context:context,builder:(_)=>AlertDialog(title:const Text('Family profiles'),content:Column(mainAxisSize:MainAxisSize.min,children:[if(profiles.isNotEmpty) ...profiles.map((x)=>ListTile(title:Text(x),trailing:IconButton(icon:const Icon(Icons.delete_outline),onPressed:()async{setState(()=>profiles.remove(x));await _save();Navigator.pop(context);_profiles();}))),TextField(controller:c,decoration:const InputDecoration(labelText:'Add family member'))]),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Cancel')),FilledButton(onPressed:()async{if(c.text.trim().isNotEmpty){setState(()=>profiles.add(c.text.trim()));await _save();}Navigator.pop(context);},child:const Text('Save'))]));}
  Future<void> _tags() async {final c=TextEditingController(); await showDialog(context:context,builder:(_)=>AlertDialog(title:const Text('Memory tags'),content:Column(mainAxisSize:MainAxisSize.min,children:[Wrap(spacing:6,children:tags.map((x)=>Chip(label:Text('#'+x),onDeleted:()async{setState(()=>tags.remove(x));await _save();Navigator.pop(context);_tags();})).toList()),TextField(controller:c,decoration:const InputDecoration(labelText:'New tag'))]),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Cancel')),FilledButton(onPressed:()async{final v=c.text.trim().replaceAll('#','');if(v.isNotEmpty)setState(()=>tags.add(v));await _save();Navigator.pop(context);},child:const Text('Add'))]));}
  Future<void> _export() async {final data=jsonEncode({'app':'Little Memories','exportedAt':DateTime.now().toIso8601String(),'photos':widget.photos.length,'favorites':widget.favorites.length,'stories':widget.timelines.length,'hidden':widget.hiddenIds.length,'profiles':profiles,'tags':tags.toList(),'albums':_albums().map((e)=>{'month':e.key,'count':e.value.length}).toList()}); await Share.share(data,subject:'Little Memories catalog');}
  Future<void> _qr() async {final data=jsonEncode({'app':'Little Memories','photos':widget.photos.length,'favorites':widget.favorites.length,'stories':widget.timelines.length}); await showDialog(context:context,builder:(_)=>AlertDialog(title:const Text('Memory QR'),content:Column(mainAxisSize:MainAxisSize.min,children:[Container(color:Colors.white,padding:const EdgeInsets.all(10),child:QrImageView(data:data,size:220)),const SizedBox(height:8),const Text('Safe summary only — no photo files are embedded.',textAlign:TextAlign.center)]),actions:[FilledButton(onPressed:()=>Navigator.pop(context),child:const Text('Done'))]));}
  @override Widget build(BuildContext context){if(loading)return const Scaffold(body:Center(child:CircularProgressIndicator())); final albums=_albums(); return Scaffold(appBar:AppBar(title:const Text('Ultimate Memory Center'),actions:[IconButton(onPressed:_export,icon:const Icon(Icons.ios_share_outlined))]),body:ListView(padding:const EdgeInsets.all(16),children:[Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Private family memory hub',style:TextStyle(fontSize:22,fontWeight:FontWeight.w900)),const SizedBox(height:6),Text(widget.photos.length.toString()+' photos • '+widget.timelines.length.toString()+' stories • '+widget.favorites.length.toString()+' favorites'),const SizedBox(height:12),Wrap(spacing:8,children:[Chip(label:Text(albums.length.toString()+' smart albums')),Chip(label:Text(widget.hiddenIds.length.toString()+' private')),Chip(label:Text(profiles.length.toString()+' profiles'))])]))),_card(Icons.auto_stories_outlined,'Smart Albums',albums.length.toString()+' automatic month/year groups',(){showModalBottomSheet(context:context,isScrollControlled:true,builder:(_)=>SafeArea(child:SizedBox(height:MediaQuery.of(context).size.height*.8,child:ListView.builder(padding:const EdgeInsets.all(16),itemCount:albums.length,itemBuilder:(_,i)=>ListTile(leading:SizedBox(width:56,height:56,child:ClipRRect(borderRadius:BorderRadius.circular(10),child:Thumb(albums[i].value.first))),title:Text(albums[i].key),subtitle:Text(albums[i].value.length.toString()+' memories'))))));}),_card(Icons.emoji_events_outlined,'Milestones','Track collection milestones',_milestones),_card(Icons.storage_outlined,'Storage Dashboard','Measure local photo storage',_storage),_card(Icons.local_offer_outlined,'Tags',tags.isEmpty?'Create reusable memory labels':tags.length.toString()+' tags',_tags),_card(Icons.people_outline,'Family Profiles',profiles.isEmpty?'Add family members':'Manage '+profiles.length.toString()+' profiles',_profiles),_card(Icons.lock_outline,'Private Memories',widget.hiddenIds.length.toString()+' hidden from the main gallery',(){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Use Memory tools → Private / Hidden memories to manage them.')));}),_card(Icons.ios_share_outlined,'Export Memory Catalog','Portable JSON index of your memories',_export),_card(Icons.qr_code_2_outlined,'Memory QR','Create a safe summary QR card',_qr),_card(Icons.cloud_outlined,'Private Cloud','PC companion provides local private-cloud backup',(){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Open Settings → Connect to Windows PC for local-cloud backup.')));}),_card(Icons.smart_toy_outlined,'AI Memory Assistant','AI captions, semantic search and story generation need an AI provider/API.',(){showDialog(context:context,builder:(_)=>const AlertDialog(title:Text('AI layer'),content:Text('The local memory foundation is ready. AI generation requires an API/service connection and credentials; it cannot be safely embedded without a provider.')));}),_card(Icons.movie_creation_outlined,'Memory Videos','Photo/video rendering needs a dedicated encoder pipeline.',(){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Video generation is the next media pipeline; the current APK keeps original photos safe.')));})]));}
  Widget _card(IconData icon,String title,String subtitle,VoidCallback onTap)=>Card(child:ListTile(contentPadding:const EdgeInsets.symmetric(horizontal:16,vertical:5),leading:CircleAvatar(child:Icon(icon)),title:Text(title,style:const TextStyle(fontWeight:FontWeight.w800)),subtitle:Text(subtitle),trailing:const Icon(Icons.chevron_right),onTap:onTap));
}
