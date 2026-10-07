
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
import 'cinematic_viewer.dart';

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

class ComicTheme {
  final String name, subtitle, fontFamily;
  final Color seed, background, surface;
  final double radius, cardElevation, buttonRadius;
  final int style;
  const ComicTheme(this.name,this.subtitle,this.fontFamily,this.seed,this.background,this.surface,this.radius,this.cardElevation,this.buttonRadius,this.style);
}
const comicThemes=<ComicTheme>[
  ComicTheme('Comic Pop','Playful bubbles, stickers and bold panels','sans-serif-rounded',Color(0xFFE85D75),Color(0xFFFFF8F0),Color(0xFFFFFFFF),24,0,26,0),
  ComicTheme('Scrapbook','Paper layers, tape and handmade memories','serif',Color(0xFFB86B45),Color(0xFFF5EBDD),Color(0xFFFFFCF5),14,3,14,1),
  ComicTheme('Watercolor','Soft gallery, airy cards and painted mood','sans-serif',Color(0xFF4C8DCE),Color(0xFFF2F8FB),Color(0xFFFFFFFF),26,2,28,2),
  ComicTheme('Polaroid','Film frames, compact cards and photo-book feel','sans-serif',Color(0xFF6B6258),Color(0xFFECE7DE),Color(0xFFFFFEFA),8,1,10,3),
  ComicTheme('Midnight','Cinematic dark gallery with glowing accents','sans-serif',Color(0xFF8B7CFF),Color(0xFF090B14),Color(0xFF151927),18,2,20,4),
  ComicTheme('Minimal','Clean editorial layout and calm spacing','sans-serif',Color(0xFF3D6B5B),Color(0xFFF7F8F6),Color(0xFFFFFFFF),12,0,12,5),
];

class LittleMemoriesApp extends StatefulWidget {
  const LittleMemoriesApp({super.key});
  @override State<LittleMemoriesApp> createState() => _AppState();
}
class _AppState extends State<LittleMemoriesApp> {
  bool dark=false; int themeIndex=0;
  @override void initState(){super.initState();_loadTheme();}
  Future<void> _loadTheme() async {final p=await SharedPreferences.getInstance();final saved=p.getInt('comicTheme')??0;if(mounted)setState(()=>themeIndex=saved.clamp(0,comicThemes.length-1));}
  ThemeData _theme(ComicTheme t,bool isDark){
    final scheme=ColorScheme.fromSeed(seedColor:t.seed,brightness:isDark?Brightness.dark:Brightness.light);
    final text=ThemeData(useMaterial3:true).textTheme.apply(fontFamily:t.fontFamily,bodyColor:scheme.onSurface,displayColor:scheme.onSurface);
    final card=RoundedRectangleBorder(borderRadius:BorderRadius.circular(t.radius),side:BorderSide(color:scheme.primary.withValues(alpha:t.style==3 ? .22 : .16),width:t.style==0?2:1));
    final button=RoundedRectangleBorder(borderRadius:BorderRadius.circular(t.buttonRadius),side:BorderSide(color:scheme.primary.withValues(alpha:t.style==0 ? .7 : .25),width:t.style==0?1.5:1));
    return ThemeData(
      useMaterial3:true,colorScheme:scheme,scaffoldBackgroundColor:t.background,textTheme:text,
      visualDensity:t.style==5?VisualDensity.compact:VisualDensity.standard,
      cardTheme:CardThemeData(color:t.surface,elevation:t.cardElevation,margin:EdgeInsets.zero,clipBehavior:Clip.antiAlias,shape:card),
      appBarTheme:AppBarTheme(backgroundColor:t.background,surfaceTintColor:Colors.transparent,foregroundColor:scheme.onSurface,elevation:t.style==1?1:0,centerTitle:t.style==3||t.style==4,titleTextStyle:text.titleLarge?.copyWith(fontWeight:FontWeight.w900)),
      navigationBarTheme:NavigationBarThemeData(height:t.style==0?78:72,backgroundColor:t.style==4?t.surface:t.background,elevation:t.style==0?3:0,indicatorColor:scheme.primary.withValues(alpha:.18),indicatorShape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(t.style==0?24:t.radius)),labelBehavior:t.style==5?NavigationDestinationLabelBehavior.alwaysShow:NavigationDestinationLabelBehavior.onlyShowSelected),
      filledButtonTheme:FilledButtonThemeData(style:FilledButton.styleFrom(minimumSize:const Size(0,48),padding:const EdgeInsets.symmetric(horizontal:18,vertical:13),textStyle:TextStyle(fontFamily:t.fontFamily,fontWeight:FontWeight.w800),shape:button)),
      outlinedButtonTheme:OutlinedButtonThemeData(style:OutlinedButton.styleFrom(minimumSize:const Size(0,48),textStyle:TextStyle(fontFamily:t.fontFamily,fontWeight:FontWeight.w800),shape:button)),
      textButtonTheme:TextButtonThemeData(style:TextButton.styleFrom(textStyle:TextStyle(fontFamily:t.fontFamily,fontWeight:FontWeight.w800),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(t.radius)))),
      inputDecorationTheme:InputDecorationTheme(filled:true,fillColor:t.surface,contentPadding:const EdgeInsets.symmetric(horizontal:16,vertical:14),border:OutlineInputBorder(borderRadius:BorderRadius.circular(t.radius),borderSide:BorderSide(color:scheme.outlineVariant)),enabledBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(t.radius),borderSide:BorderSide(color:scheme.outlineVariant)),focusedBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(t.radius),borderSide:BorderSide(color:scheme.primary,width:2))),
      chipTheme:ChipThemeData(shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(t.style==0?22:t.radius),side:BorderSide(color:scheme.outlineVariant)),side:BorderSide(color:scheme.outlineVariant)),
      listTileTheme:ListTileThemeData(shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(t.radius))),
      dialogTheme:DialogThemeData(backgroundColor:t.surface,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(t.radius+4))),
      bottomSheetTheme:BottomSheetThemeData(backgroundColor:t.surface,shape:RoundedRectangleBorder(borderRadius:BorderRadius.vertical(top:Radius.circular(t.radius+8)))),
      popupMenuTheme:PopupMenuThemeData(color:t.surface,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(t.radius))),
      floatingActionButtonTheme:FloatingActionButtonThemeData(backgroundColor:scheme.primary,foregroundColor:scheme.onPrimary,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(t.buttonRadius))),
      snackBarTheme:SnackBarThemeData(behavior:SnackBarBehavior.floating,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(t.radius))),
    );
  }
  @override Widget build(BuildContext context){
    final t=comicThemes[themeIndex.clamp(0,comicThemes.length-1)];
    return MaterialApp(debugShowCheckedModeBanner:false,title:'Little Memories',theme:_theme(t,false),darkTheme:_theme(t,true),themeMode:dark?ThemeMode.dark:ThemeMode.light,home:Home(themeIndex:themeIndex,onDark:(v)=>setState(()=>dark=v),onTheme:(v)async{final p=await SharedPreferences.getInstance();await p.setInt('comicTheme',v);if(mounted)setState(()=>themeIndex=v);}));
  }
}

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
  Set<String> selectedIds = {};
  Map<String,List<String>> memoryAlbums = {};
  String childName = 'My Little Star', childBirthday = '';  String searchQuery = '';
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
    final albumRaw=p.getString('memoryAlbums');
    if(albumRaw!=null){final decoded=jsonDecode(albumRaw) as Map;memoryAlbums=decoded.map((k,v)=>MapEntry(k,List<String>.from(v)));}
    if (mounted) setState(() => loading = false);
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
    if (!mounted) return;
    setState(() => loading = true);
    final permission = await PhotoManager.requestPermissionExtend();
    if (!mounted) return;
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
    await p.setString('memoryAlbums', jsonEncode(memoryAlbums));
  }

  AssetEntity? _find(String id) {
    for (final a in photos) { if (a.id == id) return a; }
    return null;
  }

  Future<void> _recordBackup() async {
    if (!mounted) return;
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

  Future<void> _bulkDelete() async {
    if(selectedIds.isEmpty)return;
    final count=selectedIds.length;
    final ok=await showDialog<bool>(context:context,builder:(_)=>AlertDialog(
      title:Text('Delete '+count.toString()+' photos?'),
      content:const Text('The selected photos will be deleted from the phone gallery. This cannot be undone from Little Memories.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('Delete'))],
    ))??false;
    if(!ok)return;
    try{
      final deleted=await PhotoManager.editor.deleteWithIds(selectedIds.toList());
      if (!mounted) return;
      setState((){
        for(final id in deleted){favorites.remove(id);hiddenIds.remove(id);names.remove(id);captions.remove(id);memoryAlbums.forEach((k,v)=>v.remove(id));}
        selectedIds.clear();selectionMode=false;
      });
      await _save();await _refreshPhotos();
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(deleted.length.toString()+' photos deleted.')));
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Could not delete photos: '+e.toString())));}
  }

  Future<void> _createAlbumFromSelection() async {
    if(selectedIds.isEmpty)return;
    final controller=TextEditingController();
    final name=await showDialog<String>(context:context,builder:(_)=>AlertDialog(
      title:const Text('Create album from selection'),
      content:TextField(controller:controller,autofocus:true,decoration:const InputDecoration(labelText:'Album name',hintText:'Sarthak • 1st Birthday')),
      actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(context,controller.text.trim()),child:const Text('Create'))],
    ));
    if(name==null||name.isEmpty)return;
    setState(()=>memoryAlbums[name]=<String>{...(memoryAlbums[name]??[]),...selectedIds}.toList());
    await _save();_clearSelection();
    if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Album '+name+' created with '+memoryAlbums[name]!.length.toString()+' photos.')));
  }

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
    MaterialPageRoute(builder: (_) => CinematicViewer(
      asset: a,
      all: list,
      onEdit: _openPhotoEditor,
      onShare: (x) => _share([x], 'Shared from Little Memories'),
      nameFor: (id) => names[id] ?? '',
      captionFor: (id) => captions[id] ?? '',
      isFavorite: (id) => favorites.contains(id),
      onToggleFavorite: (x) async {
        setState(() {
          if (favorites.contains(x.id)) { favorites.remove(x.id); } else { favorites.add(x.id); }
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

  Widget _themeBackdrop({required Widget child}) {
    final t = comicThemes[widget.themeIndex.clamp(0, comicThemes.length - 1)];
    final cs = Theme.of(context).colorScheme;
    return Stack(children: [
      Positioned.fill(child: IgnorePointer(child: CustomPaint(
        painter: _MemoryPatternPainter(color: cs.primary.withValues(alpha: t.style == 0 ? .055 : .035), style: t.style),
      ))),
      child,
      if (t.style == 0) Positioned(
        right: -26, top: 96,
        child: IgnorePointer(child: Container(
          width: 84, height: 84,
          decoration: BoxDecoration(color: cs.primary.withValues(alpha: .10), shape: BoxShape.circle),
        )),
      ),
    ]);
  }

  Widget _dashboard() {
    final recent = photos.take(12).toList();
    final favs = photos.where((a) => favorites.contains(a.id)).take(10).toList();
    final featured = recent.isNotEmpty ? recent.first : null;
    final cs = Theme.of(context).colorScheme;

    return RefreshIndicator(
      onRefresh: _refreshPhotos,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
        children: [
          if (featured != null) ...[
            Row(children: [
              const Expanded(child: Text('THE MOMENT', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 1.5))),
              TextButton.icon(onPressed: () => _openPhoto(featured, recent), icon: const Icon(Icons.open_in_new_rounded, size: 16), label: const Text('Open')),
            ]),
            const SizedBox(height: 7),
            SizedBox(height: 390, child: InkWell(
              onTap: () => _openPhoto(featured, recent),
              borderRadius: BorderRadius.circular(30),
              child: ClipRRect(borderRadius: BorderRadius.circular(30), child: Stack(fit: StackFit.expand, children: [
                Thumb(featured),
                DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black.withValues(alpha: .04), Colors.black.withValues(alpha: .82)], stops: const [.35, 1]))),
                Positioned(top: 16, left: 16, child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7), decoration: BoxDecoration(color: Colors.black.withValues(alpha: .38), borderRadius: BorderRadius.circular(30)), child: const Text('LATEST MEMORY', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.1)))),
                Positioned(top: 12, right: 12, child: IconButton(
                  style: IconButton.styleFrom(backgroundColor: Colors.black.withValues(alpha: .38), foregroundColor: Colors.white),
                  onPressed: () async { setState(() => favorites.contains(featured.id) ? favorites.remove(featured.id) : favorites.add(featured.id)); await _save(); },
                  icon: Icon(favorites.contains(featured.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded),
                )),
                Positioned(left: 20, right: 20, bottom: 20, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text((names[featured.id] ?? '').trim().isEmpty ? 'A day worth remembering' : names[featured.id]!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 28, height: 1.0, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 7),
                  Text(featured.createDateTime.day.toString() + ' ' + _monthName(featured.createDateTime.month) + ' ' + featured.createDateTime.year.toString(), style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700)),
                ])),
              ])),
            )),
          ] else Card(child: Padding(padding: const EdgeInsets.all(28), child: Column(children: [
            Icon(Icons.photo_camera_back_rounded, size: 58, color: cs.primary),
            const SizedBox(height: 12),
            const Text('Your story starts here', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text('Allow photo access and Little Memories will build your private memory space.', textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
          ]))),
          const SizedBox(height: 24),
          const Text('JUMP INTO YOUR MEMORIES', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
          const SizedBox(height: 10),
          Row(children: [
            _studioAction(Icons.collections_rounded, 'Albums', 'Collections', () => setState(() => tab = 1), cs),
            const SizedBox(width: 10),
            _studioAction(Icons.favorite_rounded, 'Loved', favs.length.toString() + ' saved', () => setState(() => tab = 2), cs),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            _studioAction(Icons.auto_awesome_rounded, 'Moments', 'On this day', _openMomentsPage, cs),
            const SizedBox(width: 10),
            _studioAction(Icons.search_rounded, 'Search', 'Find anything', () => setState(() => showAllPhotos = true), cs),
          ]),
          if (recent.isNotEmpty) ...[
            const SizedBox(height: 28),
            Row(children: [
              const Expanded(child: Text('RECENTLY CAPTURED', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 1.5))),
              TextButton(onPressed: () => setState(() => showAllPhotos = true), child: const Text('All photos')),
            ]),
            const SizedBox(height: 8),
            SizedBox(height: 205, child: ListView.separated(
              scrollDirection: Axis.horizontal, itemCount: recent.length, separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, i) {
                final a = recent[i];
                return SizedBox(width: 158, child: InkWell(
                  onTap: () => _openPhoto(a, recent), borderRadius: BorderRadius.circular(24),
                  child: ClipRRect(borderRadius: BorderRadius.circular(24), child: Stack(fit: StackFit.expand, children: [
                    Thumb(a),
                    DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withValues(alpha: .78)]))),
                    Positioned(left: 11, right: 11, bottom: 11, child: Text((names[a.id] ?? '').trim().isEmpty ? 'Memory ' + (i + 1).toString() : names[a.id]!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13))),
                    if (favorites.contains(a.id)) const Positioned(top: 9, right: 9, child: Icon(Icons.favorite_rounded, color: Colors.white, size: 18)),
                  ])),
                ));
              },
            )),
          ],
          if (favs.isNotEmpty) ...[
            const SizedBox(height: 28),
            Row(children: [
              const Expanded(child: Text('LOVED MEMORIES', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 1.5))),
              TextButton(onPressed: () => setState(() => tab = 2), child: const Text('View all')),
            ]),
            const SizedBox(height: 8),
            SizedBox(height: 118, child: ListView.separated(
              scrollDirection: Axis.horizontal, itemCount: favs.length, separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) => InkWell(onTap: () => _openPhoto(favs[i], favs), borderRadius: BorderRadius.circular(20), child: ClipRRect(borderRadius: BorderRadius.circular(20), child: SizedBox(width: 118, child: Thumb(favs[i])))),
            )),
          ],
          const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(26), border: Border.all(color: cs.outlineVariant)),
            child: Row(children: [
              Container(width: 48, height: 48, decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(16)), child: Icon(Icons.auto_awesome_rounded, color: cs.onPrimary)),
              const SizedBox(width: 13),
              const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Ultimate Memory Center', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                SizedBox(height: 4),
                Text('Smart albums • storage • milestones • family tools', style: TextStyle(fontSize: 11)),
              ])),
              IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => UltimateMemoryCenter(photos: photos, favorites: favorites, timelines: timelines, names: names, captions: captions, hiddenIds: hiddenIds))), icon: const Icon(Icons.arrow_forward_rounded)),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _studioAction(IconData icon, String title, String subtitle, VoidCallback onTap, ColorScheme cs) => Expanded(
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        height: 82, padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(22), border: Border.all(color: cs.outlineVariant)),
        child: Row(children: [
          Container(width: 42, height: 42, decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(14)), child: Icon(icon, color: cs.onPrimaryContainer)),
          const SizedBox(width: 10),
          Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
            const SizedBox(height: 2),
            Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10)),
          ])),
        ]),
      ),
    ),
  );

  Widget _memoryHeroCard(AssetEntity a, List<AssetEntity> all, ComicTheme t) {
    final cs = Theme.of(context).colorScheme;
    final title = (names[a.id] ?? '').trim().isNotEmpty ? names[a.id]! : 'A moment worth remembering';
    final date = a.createDateTime;
    final liked = favorites.contains(a.id);
    return Card(clipBehavior: Clip.antiAlias, elevation: 0, child: InkWell(onTap: () => _openPhoto(a, all), child: SizedBox(height: 365, child: Stack(fit: StackFit.expand, children: [
      Thumb(a),
      DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withValues(alpha: .88)], stops: const [.34, 1]))),
      Positioned(left: 16, right: 16, top: 16, child: Row(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7), decoration: BoxDecoration(color: Colors.white.withValues(alpha: .88), borderRadius: BorderRadius.circular(18)), child: Text('TODAY • FEATURED', style: TextStyle(color: cs.onSurface, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.1))),
        const Spacer(),
        IconButton(style: IconButton.styleFrom(backgroundColor: Colors.black.withValues(alpha: .28)), onPressed: () async { setState(() => liked ? favorites.remove(a.id) : favorites.add(a.id)); await _save(); }, icon: Icon(liked ? Icons.favorite : Icons.favorite_border, color: Colors.white)),
      ])),
      Positioned(left: 17, right: 17, bottom: 17, child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 26, height: 1.02, fontWeight: FontWeight.w900)), const SizedBox(height: 6), Text(date.day.toString() + ' ' + _monthName(date.month) + ' ' + date.year.toString(), style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700))])),
        const SizedBox(width: 10),
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9), decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(20)), child: const Text('OPEN', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 10))),
      ])),
    ]))));
  }

  Widget _editorialAction(IconData icon, String title, String sub, VoidCallback onTap, ColorScheme cs) => Padding(padding: const EdgeInsets.only(right: 10), child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(20), child: Container(width: 138, padding: const EdgeInsets.all(13), decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: cs.outlineVariant)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(icon, size: 22, color: cs.primary), const Spacer(), Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)), Text(sub, style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant))]))));

  Widget _editorialRecentStrip(List<AssetEntity> items) {
    if (items.isEmpty) return const SizedBox.shrink();
    return SizedBox(height: 178, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: items.length, separatorBuilder: (_, __) => const SizedBox(width: 10), itemBuilder: (_, i) {
      final a = items[i];
      final title = (names[a.id] ?? '').trim().isNotEmpty ? names[a.id]! : 'Memory';
      return SizedBox(width: 142, child: InkWell(onTap: () => _openPhoto(a, items), borderRadius: BorderRadius.circular(20), child: ClipRRect(borderRadius: BorderRadius.circular(20), child: Stack(fit: StackFit.expand, children: [
        Thumb(a),
        DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withValues(alpha: .78)]))),
        Positioned(left: 10, right: 10, bottom: 10, child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13))),
        if (favorites.contains(a.id)) const Positioned(right: 8, top: 8, child: Icon(Icons.favorite, color: Colors.white, size: 18)),
      ]))));
    }));
  }

  Widget _editorialAlbumPreview() {
    final groups=<String,List<AssetEntity>>{};
    for(final a in photos){final d=a.createDateTime;final k=d.year.toString()+'-'+d.month.toString().padLeft(2,'0');groups.putIfAbsent(k,()=>[]).add(a);}
    final entries=groups.entries.toList()..sort((a,b)=>b.key.compareTo(a.key));
    if(entries.isEmpty) return const SizedBox.shrink();
    return SizedBox(height:190, child: ListView.separated(scrollDirection:Axis.horizontal,itemCount:entries.take(6).length,separatorBuilder:(_,__)=>const SizedBox(width:12),itemBuilder:(_,i){
      final e=entries[i];final parts=e.key.split('-');final title=parts[0]+' • '+_monthName(int.parse(parts[1]));
      return SizedBox(width:220, child:InkWell(onTap:()=>_openPhoto(e.value.first,e.value),borderRadius:BorderRadius.circular(22),child:ClipRRect(borderRadius:BorderRadius.circular(22),child:Stack(fit:StackFit.expand,children:[
        Thumb(e.value.first),
        DecoratedBox(decoration:BoxDecoration(gradient:LinearGradient(begin:Alignment.topCenter,end:Alignment.bottomCenter,colors:[Colors.transparent,Colors.black.withValues(alpha:.84)]))),
        Positioned(left:14,right:14,bottom:13,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:const TextStyle(color:Colors.white,fontSize:16,fontWeight:FontWeight.w900)),const SizedBox(height:2),Text(e.value.length.toString()+' photos',style:const TextStyle(color:Colors.white70,fontSize:11,fontWeight:FontWeight.w700))])),
      ]))));
    }));
  }
  Widget _featuredMemoryCard(AssetEntity featured, List<AssetEntity> all, ComicTheme t) {
    final cs = Theme.of(context).colorScheme;
    final title = (names[featured.id] ?? '').trim().isNotEmpty ? names[featured.id]! : 'A moment worth keeping';
    final date = featured.createDateTime;
    return Card(clipBehavior: Clip.antiAlias, elevation: t.style == 0 ? 0 : null, child: InkWell(
      onTap: () => _openPhoto(featured, all),
      child: SizedBox(height: 330, child: Stack(fit: StackFit.expand, children: [
        Thumb(featured),
        DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withValues(alpha: .82)], stops: const [.34, 1]))),
        Positioned(left: 18, right: 18, top: 16, child: Row(children: [
          Container(padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7), decoration: BoxDecoration(color: Colors.black.withValues(alpha: .30), borderRadius: BorderRadius.circular(t.style == 3 ? 8 : 20), border: Border.all(color: Colors.white.withValues(alpha: .22))), child: const Text('FEATURED MEMORY', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.3))),
          const Spacer(),
          InkWell(
            onTap: () async { setState(() => favorites.contains(featured.id) ? favorites.remove(featured.id) : favorites.add(featured.id)); await _save(); },
            borderRadius: BorderRadius.circular(30),
            child: CircleAvatar(radius: 21, backgroundColor: Colors.black.withValues(alpha: .30), child: Icon(favorites.contains(featured.id) ? Icons.favorite : Icons.favorite_border, color: Colors.white)),
          ),
        ])),
        Positioned(left: 18, right: 18, bottom: 18, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 25, fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          Row(children: [
            const Icon(Icons.calendar_today_rounded, color: Colors.white70, size: 13),
            const SizedBox(width: 5),
            Text('${date.day} ${_monthName(date.month)} ${date.year}', style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700)),
            const Spacer(),
            Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(18)), child: const Text('Open memory', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 11))),
          ]),
        ])),
      ])),
    ));
  }

  Widget _homeAction(IconData icon, String label, String sub, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(18), child: Container(
      height: 84, padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: cs.outlineVariant.withValues(alpha: .7))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 21, color: cs.primary),
        const Spacer(),
        Text(label, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
        Text(sub, style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
      ]),
    ));
  }

  Widget _todayMemoryMosaic(List<AssetEntity> items) {
    if (items.isEmpty) return Card(child: Padding(padding: const EdgeInsets.all(22), child: Text('Your newest memories will appear here.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))));
    final shown = items.take(5).toList();
    return SizedBox(height: 286, child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(flex: 3, child: _mosaicTile(shown[0], shown, radius: 22)),
      const SizedBox(width: 7),
      Expanded(flex: 2, child: Column(children: [
        Expanded(child: shown.length > 1 ? _mosaicTile(shown[1], shown, radius: 20) : const SizedBox()),
        const SizedBox(height: 7),
        Expanded(child: shown.length > 2 ? _mosaicTile(shown[2], shown, radius: 20) : const SizedBox()),
      ])),
    ]));
  }

  Widget _mosaicTile(AssetEntity a, List<AssetEntity> list, {required double radius}) {
    return InkWell(onTap: () => _openPhoto(a, list), borderRadius: BorderRadius.circular(radius), child: ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(fit: StackFit.expand, children: [
        Thumb(a),
        DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withValues(alpha: .58)]))),
        Positioned(left: 10, right: 10, bottom: 9, child: Text(names[a.id] ?? a.title ?? 'Memory', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, shadows: [Shadow(blurRadius: 5)]))),
      ]),
    ));
  }

  Widget _albumPreviewCards(){
    final groups=<String,List<AssetEntity>>{};
    for(final a in photos){final d=a.createDateTime;final k=d.year.toString()+'-'+d.month.toString().padLeft(2,'0');groups.putIfAbsent(k,()=>[]).add(a);}
    final entries=groups.entries.toList()..sort((a,b)=>b.key.compareTo(a.key));
    return SizedBox(height:154,child:ListView(scrollDirection:Axis.horizontal,children:entries.take(6).map((e){
      final parts=e.key.split('-');final title=parts[0]+' • '+_monthName(int.parse(parts[1]));
      return Padding(padding:const EdgeInsets.only(right:12),child:SizedBox(width:190,child:Card(clipBehavior:Clip.antiAlias,child:InkWell(onTap:()=>_openPhoto(e.value.first,e.value),child:Stack(fit:StackFit.expand,children:[
        Thumb(e.value.first),
        DecoratedBox(decoration:BoxDecoration(gradient:LinearGradient(begin:Alignment.topCenter,end:Alignment.bottomCenter,colors:[Colors.transparent,Colors.black.withValues(alpha:.75)]))),
        Positioned(left:12,right:12,bottom:12,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w900)),Text(e.value.length.toString()+' photos',style:TextStyle(color:Colors.white.withValues(alpha:.8),fontSize:12))])),
      ])))));
    }).toList()));
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
    final custom=memoryAlbums.entries.toList();
    final cs=Theme.of(context).colorScheme;
    return CustomScrollView(slivers:[SliverPadding(padding:const EdgeInsets.fromLTRB(18,14,18,100),sliver:SliverList(delegate:SliverChildListDelegate([
      Row(children:[const Expanded(child:Text('Albums',style:TextStyle(fontSize:32,fontWeight:FontWeight.w900,letterSpacing:-.7))),IconButton(style:IconButton.styleFrom(backgroundColor:cs.surface,side:BorderSide(color:cs.outlineVariant)),onPressed:()=>setState(()=>selectionMode=true),icon:const Icon(Icons.add_rounded),tooltip:'Create album from photos')]),
      const SizedBox(height:3),Text('Collections of the moments you never want to lose.',style:TextStyle(color:cs.onSurfaceVariant,fontSize:12)),
      const SizedBox(height:22),
      Row(children:[const Expanded(child:Text('Recently',style:TextStyle(fontSize:21,fontWeight:FontWeight.w900))),TextButton(onPressed:()=>setState(()=>tab=0),child:const Text('See all'))]),
      const SizedBox(height:7),
      if(favorites.isNotEmpty&&photos.isNotEmpty)_albumFeatureCard(title:'My Favorites',subtitle:favorites.length.toString()+' photos',asset:_find(favorites.first),onTap:()=>setState(()=>tab=2),favorite:true)
      else if(photos.isNotEmpty)_albumFeatureCard(title:'Your latest memories',subtitle:photos.length.toString()+' photos',asset:photos.first,onTap:()=>setState(()=>tab=0))
      else Card(child:Padding(padding:const EdgeInsets.all(24),child:Text('Your albums will appear here when photos are available.',style:TextStyle(color:cs.onSurfaceVariant)))),
      const SizedBox(height:26),
      Row(children:[const Expanded(child:Text('Your albums',style:TextStyle(fontSize:21,fontWeight:FontWeight.w900))),if(custom.isNotEmpty)Text(custom.length.toString()+' collections',style:TextStyle(color:cs.onSurfaceVariant,fontSize:11,fontWeight:FontWeight.w700))]),
      const SizedBox(height:10),
      if(custom.isNotEmpty)Wrap(spacing:12,runSpacing:12,children:custom.map((e){AssetEntity? cover;for(final id in e.value){final a=_find(id);if(a!=null){cover=a;break;}}return _smallAlbumCard(title:e.key,subtitle:e.value.length.toString()+' photos',asset:cover,onTap:cover==null?null:()=>_openPhoto(cover!,e.value.map(_find).whereType<AssetEntity>().toList()));}).toList())
      else Container(padding:const EdgeInsets.all(18),decoration:BoxDecoration(color:cs.surfaceContainerHighest.withValues(alpha:.55),borderRadius:BorderRadius.circular(20),border:Border.all(color:cs.outlineVariant)),child:Row(children:[Icon(Icons.collections_bookmark_outlined,color:cs.primary),const SizedBox(width:12),const Expanded(child:Text('Select photos anywhere in the gallery and tap + to create your first collection.'))])),
      const SizedBox(height:28),
      Row(children:[const Expanded(child:Text('Smart albums',style:TextStyle(fontSize:21,fontWeight:FontWeight.w900))),Text('Automatically grouped',style:TextStyle(color:cs.onSurfaceVariant,fontSize:11))]),
      const SizedBox(height:10),
      if(entries.isNotEmpty)Wrap(spacing:12,runSpacing:12,children:entries.take(12).map((e){final parts=e.key.split('-');return _smallAlbumCard(title:parts[0]+' • '+_monthName(int.parse(parts[1])),subtitle:e.value.length.toString()+' photos',asset:e.value.first,onTap:()=>_openPhoto(e.value.first,e.value));}).toList()) else const Text('No smart albums yet.'),
      const SizedBox(height:28),
      Row(children:[const Expanded(child:Text('Tools',style:TextStyle(fontSize:21,fontWeight:FontWeight.w900))),Text('Keep your library clean',style:TextStyle(color:cs.onSurfaceVariant,fontSize:11))]),
      const SizedBox(height:10),
      Row(children:[Expanded(child:FilledButton.icon(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>DuplicatePhotosPage(photos:photos))),icon:const Icon(Icons.copy_all_outlined),label:const Text('Duplicates'))),const SizedBox(width:10),Expanded(child:FilledButton.tonalIcon(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>BlurryPhotosPage(photos:photos))),icon:const Icon(Icons.blur_on),label:const Text('Blurry')))]),
    ])))]);
  }

  Widget _albumFeatureCard({required String title,required String subtitle,AssetEntity? asset,required VoidCallback onTap,bool favorite=false}) {
    final cs=Theme.of(context).colorScheme;
    return SizedBox(height:210,child:Card(clipBehavior:Clip.antiAlias,child:InkWell(onTap:onTap,child:Stack(fit:StackFit.expand,children:[
      asset==null?Container(color:cs.surfaceContainerHighest,child:Icon(Icons.photo_album_outlined,size:52,color:cs.primary)):Thumb(asset),
      DecoratedBox(decoration:BoxDecoration(gradient:LinearGradient(begin:Alignment.topCenter,end:Alignment.bottomCenter,colors:[Colors.transparent,Colors.black.withValues(alpha:.86)]))),
      Positioned(left:16,right:16,top:15,child:Row(children:[Container(padding:const EdgeInsets.symmetric(horizontal:10,vertical:6),decoration:BoxDecoration(color:Colors.white.withValues(alpha:.9),borderRadius:BorderRadius.circular(18)),child:Text(favorite?'FAVORITES':'RECENT',style:TextStyle(color:cs.onSurface,fontSize:9,fontWeight:FontWeight.w900,letterSpacing:1.1))),const Spacer(),if(favorite)const Icon(Icons.favorite,color:Colors.white)])),
      Positioned(left:16,right:16,bottom:15,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:const TextStyle(color:Colors.white,fontSize:24,fontWeight:FontWeight.w900)),const SizedBox(height:2),Text(subtitle,style:const TextStyle(color:Colors.white70,fontSize:12,fontWeight:FontWeight.w700))])),
    ]))));
  }

  Widget _smallAlbumCard({required String title,required String subtitle,AssetEntity? asset,required VoidCallback? onTap}) {
    final cs=Theme.of(context).colorScheme;
    return SizedBox(width:((MediaQuery.of(context).size.width-48)/2).clamp(145.0,220.0),height:178,child:Card(clipBehavior:Clip.antiAlias,child:InkWell(onTap:onTap,child:Stack(fit:StackFit.expand,children:[
      asset==null?Container(color:cs.surfaceContainerHighest,child:Icon(Icons.photo_album_outlined,size:42,color:cs.primary)):Thumb(asset),
      DecoratedBox(decoration:BoxDecoration(gradient:LinearGradient(begin:Alignment.topCenter,end:Alignment.bottomCenter,colors:[Colors.transparent,Colors.black.withValues(alpha:.82)]))),
      Positioned(left:12,right:12,bottom:12,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white,fontSize:15,fontWeight:FontWeight.w900)),const SizedBox(height:2),Text(subtitle,style:const TextStyle(color:Colors.white70,fontSize:10,fontWeight:FontWeight.w700))])),
    ]))));
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
            IconButton(tooltip:'Select multiple photos',onPressed:()=>setState(()=>selectionMode=true),icon:const Icon(Icons.checklist_rounded)),
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
      appBar: tab == 0 && !showAllPhotos && !selectionMode ? null : AppBar(
        title: selectionMode ? Text('${selectedIds.length} selected', style: const TextStyle(fontWeight: FontWeight.w800)) : const Text('Little Memories', style: TextStyle(fontWeight: FontWeight.w800)),
        leading: selectionMode ? IconButton(onPressed: _clearSelection, icon: const Icon(Icons.close)) : null,
        actions: selectionMode
            ? [
                IconButton(onPressed: _createAlbumFromSelection, tooltip: 'Create album from selected', icon: const Icon(Icons.create_new_folder_outlined)),
                IconButton(onPressed: _bulkFavorite, tooltip: 'Favorite', icon: const Icon(Icons.favorite_border)),
                IconButton(onPressed: _bulkShare, tooltip: 'Share', icon: const Icon(Icons.share_outlined)),
                IconButton(onPressed: _bulkDelete, tooltip: 'Delete selected photos', icon: const Icon(Icons.delete_outline)),
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
      floatingActionButton: tab == 0 && !selectionMode ? FloatingActionButton(
        tooltip: 'Memory tools',
        onPressed: () => showModalBottomSheet(
          context: context,
          builder: (_) => SafeArea(child: Wrap(children: [
            const ListTile(title: Text('Create your next memory collection', style: TextStyle(fontWeight: FontWeight.w900))),
            ListTile(leading: const Icon(Icons.checklist_rounded), title: const Text('Select photos'), onTap: () { Navigator.pop(context); setState(() => selectionMode = true); }),
            ListTile(leading: const Icon(Icons.insights_rounded), title: const Text('Memory statistics'), onTap: () { Navigator.pop(context); _memoryStatistics(); }),
            ListTile(leading: const Icon(Icons.content_copy_rounded), title: const Text('Find likely duplicates'), onTap: () { Navigator.pop(context); _smartDuplicateScan(); }),
            ListTile(leading: const Icon(Icons.lock_outline_rounded), title: const Text('Private / Hidden memories'), onTap: () { Navigator.pop(context); _showHiddenMemories(); }),
            ListTile(leading: const Icon(Icons.slideshow_rounded), title: const Text('Play memory slideshow'), onTap: () { Navigator.pop(context); _startSlideshow(); }),
            ListTile(leading: const Icon(Icons.auto_awesome_rounded), title: const Text('Ultimate Memory Center'), subtitle: const Text('Albums • milestones • storage • export • family tools'), onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => UltimateMemoryCenter(photos: photos, favorites: favorites, timelines: timelines, names: names, captions: captions, hiddenIds: hiddenIds))); }),
            ListTile(leading: const Icon(Icons.share_rounded), title: const Text('Share memory collection'), onTap: () { Navigator.pop(context); _shareMemoryCollection(); }),
          ])),
        ),
        child: const Icon(Icons.add_rounded),
      ) : null,
      bottomNavigationBar: selectionMode
          ? null
          : NavigationBar(
        selectedIndex: tab, onDestinationSelected: (v) => setState(() { tab = v; if (v == 0) showAllPhotos = false; }),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
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
    if (!mounted) return;
    setState(() { starting = true; error = null; });
    final pairingKey = await PcConnectService.loadPairingKey();
    if (!mounted) return;
    final s = PcConnectService(photos: widget.photos, timelines: widget.timelines, names: widget.names, captions: widget.captions, pairingKey: pairingKey, onConnected: () { if (mounted) setState(() => connectedAt = DateTime.now()); }, onBackupStarted: widget.onBackupStarted);
    try {
      await s.start();
      if (!mounted) {
        await s.stop();
        return;
      }
      setState(() { service = s; starting = false; });
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

class _MemoryPatternPainter extends CustomPainter {
  final Color color;
  final int style;
  const _MemoryPatternPainter({required this.color, required this.style});
  @override void paint(Canvas canvas, Size size) {
    final p=Paint()..color=color..style=PaintingStyle.stroke..strokeWidth=1.2;
    if(style==0){
      for(double x=-size.height;x<size.width;x+=58){final path=Path()..moveTo(x,0);for(double y=0;y<size.height;y+=42){path.quadraticBezierTo(x+18,y+21,x,y+42);}canvas.drawPath(path,p);}
    } else if(style==1){
      for(double x=0;x<size.width;x+=48) for(double y=0;y<size.height;y+=48) canvas.drawRect(Rect.fromLTWH(x+4,y+4,34,34),p);
    } else if(style==2){
      for(double x=0;x<size.width;x+=90){canvas.drawCircle(Offset(x,40),24,p);canvas.drawCircle(Offset(x+45,90),18,p);}
    } else if(style==3){
      for(double x=0;x<size.width;x+=70) canvas.drawLine(Offset(x,0),Offset(x+25,size.height),p);
    } else if(style==5){
      for(double y=26;y<size.height;y+=56) canvas.drawLine(Offset(0,y),Offset(size.width,y),p);
    }
  }
  @override bool shouldRepaint(covariant _MemoryPatternPainter old) => old.color!=color || old.style!=style;
}

class Thumb extends StatefulWidget {
  final AssetEntity asset;
  const Thumb(this.asset, {super.key});
  @override State<Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<Thumb> {
  Future<Uint8List?>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant Thumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id) _load();
  }

  void _load() {
    _future = widget.asset.thumbnailDataWithSize(const ThumbnailSize(800, 800));
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _future,
    builder: (_, s) {
      if (s.connectionState == ConnectionState.waiting) {
        return Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      }
      if (s.hasError || s.data == null) {
        return Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Center(child: Icon(Icons.broken_image_outlined)),
        );
      }
      return Image.memory(
        s.data!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Center(child: Icon(Icons.broken_image_outlined)),
        ),
      );
    },
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
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CinematicViewer(
              asset: list[i], all: list, onEdit: widget.onEdit, onShare: widget.onShare,
              nameFor: widget.nameFor, captionFor: widget.captionFor, isFavorite: widget.isFavorite,
              onToggleFavorite: widget.onToggleFavorite,
            ))),
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
                      onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>CinematicViewer(
                        asset:a, all:grouped[year]!, onEdit:onEdit, onShare:onShare,
                        nameFor:(id)=>names[id]??'', captionFor:(id)=>captions[id]??'',
                        isFavorite:(id)=>favorites.contains(id), onToggleFavorite:onToggleFavorite,
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
