
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:open_file/open_file.dart';
import 'package:video_player/video_player.dart';
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
  ComicTheme('Aurora','Iridescent night, glass panels and luminous accents','sans-serif',Color(0xFF6C63FF),Color(0xFF0B1020),Color(0xFF151C32),26,3,28,6),
  ComicTheme('Sage Garden','Natural greens, warm paper and calm organic shapes','sans-serif',Color(0xFF3E8064),Color(0xFFF1F5EE),Color(0xFFFFFEFA),20,2,22,7),
  ComicTheme('Sunset Film','Warm film tones, bold type and photo-journal energy','sans-serif',Color(0xFFE36B3D),Color(0xFFFFF2E8),Color(0xFFFFFBF7),16,2,18,8),
  ComicTheme('Mono Studio','Black, white and graphite with a premium gallery feel','sans-serif',Color(0xFF22252A),Color(0xFFF3F4F6),Color(0xFFFFFFFF),10,1,12,9),
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
  int tab = 0, grid = 3, albumGrid = 3, exploreGrid = 3;
  bool galleryNewestFirst = true;
  bool galleryShowNames = false;
  bool loading = true, permissionDenied = false;
  bool videosLoaded = false;
  bool backgroundSyncing = false;
  List<AssetEntity> photos = [];
  List<AssetPathEntity> deviceAlbums = [];
  List<AssetPathEntity> deviceVideoAlbums = [];
  List<AssetPathEntity> deviceDeletedAlbums = [];
  List<AssetEntity> videos = [];
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
  Map<String, Set<String>> photoTags = {};
  int galleryFilter = 0;
  final TextEditingController searchController = TextEditingController();

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    // Startup is intentionally split into a fast first screen and background indexing.
    // The old flow scanned the entire photo and video library before showing Home.
    final p = await SharedPreferences.getInstance();

    // Load user state first so the UI can be configured immediately.
    final raw = p.getString('timelines');
    if (raw != null) timelines = (jsonDecode(raw) as List).map((e) => Timeline.fromJson(e)).toList();
    favorites = (p.getStringList('favorites') ?? const []).toSet();
    final n = p.getString('names'); if (n != null) names = Map<String, String>.from(jsonDecode(n));
    final c = p.getString('captions'); if (c != null) captions = Map<String, String>.from(jsonDecode(c));
    backupHistory = p.getStringList('backupHistory') ?? [];
    hiddenIds = (p.getStringList('hiddenIds') ?? const []).toSet();
    final tagsRaw = p.getString('photoTags');
    if (tagsRaw != null) {
      final decoded = jsonDecode(tagsRaw) as Map;
      photoTags = decoded.map((k,v) => MapEntry(k.toString(), Set<String>.from(v as List)));
    }
    galleryFilter = p.getInt('galleryFilter') ?? 0;
    grid = p.getInt('grid') ?? 3;
    albumGrid = p.getInt('albumGrid') ?? 3;
    exploreGrid = p.getInt('exploreGrid') ?? 3;
    childName = p.getString('childName') ?? 'My Little Star';
    childBirthday = p.getString('childBirthday') ?? '';
    final albumRaw = p.getString('memoryAlbums');
    if (albumRaw != null) {
      final decoded = jsonDecode(albumRaw) as Map;
      memoryAlbums = decoded.map((k,v) => MapEntry(k, List<String>.from(v)));
    }

    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth && !permission.hasAccess) {
      if (mounted) setState(() { permissionDenied = true; loading = false; });
      return;
    }

    // Only load the first page for the first paint. photo_manager's paged API is lazy,
    // so we don't need to walk thousands of assets before showing the gallery.
    await _loadFirstPhotosPage();
    if (!mounted) return;
    setState(() => loading = false);

    // Complete indexing after Home is already usable.
    unawaited(_finishBackgroundIndex());
  }

  Future<void> _loadFirstPhotosPage() async {
    try {
      final paths = await PhotoManager.getAssetPathList(type: RequestType.image, onlyAll: false, hasAll: true);
      final usable = <AssetPathEntity>[];
      final deleted = <AssetPathEntity>[];
      for (final p in paths) {
        final n = p.name.toLowerCase();
        if (n.contains('recently deleted') || n.contains('trash') || n.contains('recycle bin') || n == 'bin' || n.contains('recently removed')) {
          deleted.add(p);
        } else {
          usable.add(p);
        }
      }
      deviceAlbums = usable;
      deviceDeletedAlbums = deleted;
      final all = usable.where((p) => p.isAll).toList();
      if (all.isNotEmpty) {
        photos = await all.first.getAssetListPaged(page: 0, size: 80);
      } else if (usable.isNotEmpty) {
        final first = await usable.first.getAssetListPaged(page: 0, size: 80);
        photos = first;
      } else {
        photos = [];
      }
    } catch (_) {
      photos = [];
    }
  }

  Future<void> _finishBackgroundIndex() async {
    if (backgroundSyncing) return;
    backgroundSyncing = true;
    try {
      // Full image indexing happens after the first frame and never blocks startup.
      await _refreshPhotos();
      if (mounted) setState(() {});
    } catch (_) {}
    backgroundSyncing = false;
  }

  Future<void> _refreshVideos() async {
    if (videosLoaded) return;
    try {
      final paths = await PhotoManager.getAssetPathList(type: RequestType.video, onlyAll: false, hasAll: true);
      deviceVideoAlbums = paths;
      final all = paths.where((p) => p.isAll).toList();
      final sources = all.isEmpty ? paths.take(3).toList() : all;
      final out = <AssetEntity>[];
      final seen = <String>{};
      for (final p in sources) {
        var page = 0;
        while (true) {
          final batch = await p.getAssetListPaged(page: page, size: 200);
          if (batch.isEmpty) break;
          for (final a in batch) {
            if (seen.add(a.id)) out.add(a);
          }
          if (batch.length < 200) break;
          page++;
        }
      }
      out.sort((a,b) => b.createDateTime.compareTo(a.createDateTime));
      videos = out;
      videosLoaded = true;
    } catch (_) {
      videos = [];
      deviceVideoAlbums = [];
    }
    if (mounted) setState(() {});
  }

  Future<void> _refreshPhotos() async {
    final allPaths = await PhotoManager.getAssetPathList(type: RequestType.image, onlyAll: false, hasAll: true);
    final usable = <AssetPathEntity>[];
    final deleted = <AssetPathEntity>[];
    for (final p in allPaths) {
      final n = p.name.toLowerCase();
      if (n.contains('recently deleted') || n.contains('trash') || n.contains('recycle bin') || n == 'bin' || n.contains('recently removed')) {
        deleted.add(p);
      } else {
        usable.add(p);
      }
    }
    deviceAlbums = usable;
    deviceDeletedAlbums = deleted;
    final allAlbum = usable.where((p) => p.isAll).toList();
    if (allAlbum.isNotEmpty) {
      final all = <AssetEntity>[];
      var page = 0;
      const pageSize = 200;
      while (true) {
        final batch = await allAlbum.first.getAssetListPaged(page: page, size: pageSize);
        if (batch.isEmpty) break;
        all.addAll(batch);
        if (batch.length < pageSize) break;
        page++;
      }
      photos = all;
    } else if (usable.isNotEmpty) {
      final all = <AssetEntity>[];
      for (final p in usable) {
        var page = 0;
        while (true) {
          final batch = await p.getAssetListPaged(page: page, size: 200);
          if (batch.isEmpty) break;
          all.addAll(batch);
          if (batch.length < 200) break;
          page++;
        }
      }
      final seen = <String>{};
      photos = all.where((a) => seen.add(a.id)).toList();
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
    await p.setString('photoTags', jsonEncode(photoTags.map((k,v)=>MapEntry(k,v.toList()))));
    await p.setInt('galleryFilter', galleryFilter);
    await p.setInt('grid', grid);
    await p.setInt('albumGrid', albumGrid);
    await p.setInt('exploreGrid', exploreGrid);
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
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: albumGrid, crossAxisSpacing: 5, mainAxisSpacing: 5),
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
    if (photos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No photos are available to scan.')),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Scanning file sizes and verifying exact duplicate content…'),
        duration: Duration(seconds: 4),
      ),
    );

    // File size is a cheap first pass: only files with equal lengths need hashing.
    final bySize = <int, List<AssetEntity>>{};
    var unavailable = 0;
    for (final asset in photos) {
      try {
        final file = await asset.file;
        if (file == null || !await file.exists()) {
          unavailable++;
          continue;
        }
        final size = await file.length();
        bySize.putIfAbsent(size, () => <AssetEntity>[]).add(asset);
      } catch (_) {
        unavailable++;
      }
    }

    // SHA-256 is streamed from disk, so full photo/video files are not loaded into memory.
    final groups = <String, List<AssetEntity>>{};
    for (final entry in bySize.entries) {
      if (entry.value.length < 2) continue;
      for (final asset in entry.value) {
        try {
          final file = await asset.file;
          if (file == null || !await file.exists()) continue;
          final digest = await sha256.bind(file.openRead()).first;
          final key = '${entry.key}:$digest';
          groups.putIfAbsent(key, () => <AssetEntity>[]).add(asset);
        } catch (_) {
          unavailable++;
        }
      }
    }

    final duplicates = groups.values.where((group) => group.length > 1).toList();
    final duplicateCopies =
        duplicates.fold<int>(0, (total, group) => total + group.length - 1);
    if (!mounted) return;

    final summary = duplicates.isEmpty
        ? 'No exact duplicate files were found. Nothing was changed or deleted.'
        : '$duplicateCopies exact duplicate cop${duplicateCopies == 1 ? 'y' : 'ies'} found across '
            '${duplicates.length} groups. These files have matching sizes and SHA-256 content. '
            'Review them in your gallery before deleting anything.';
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Exact duplicate scan'),
        content: Text(
          '$summary\n\nFiles checked: ${photos.length - unavailable} of ${photos.length}'
          '${unavailable == 0 ? '' : '\nFiles unavailable: $unavailable'}',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
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

  Future<void> _deleteSinglePhoto(AssetEntity a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete photo?'),
        content: const Text('This photo will be moved to the phone gallery trash/recently deleted area when supported by Android.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    ) ?? false;
    if (!ok) return;
    try {
      final deleted = await PhotoManager.editor.deleteWithIds([a.id]);
      if (!mounted) return;
      if (deleted.contains(a.id)) {
        setState(() {
          favorites.remove(a.id);
          hiddenIds.remove(a.id);
          names.remove(a.id);
          captions.remove(a.id);
          memoryAlbums.forEach((_, v) => v.remove(a.id));
        });
        await _save();
        await _refreshPhotos();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Photo deleted.')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not delete photo: ' + e.toString())));
    }
  }

  Future<void> _showPhotoActions(AssetEntity a, List<AssetEntity> list) async {
    final liked = favorites.contains(a.id);
    final hidden = hiddenIds.contains(a.id);
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 14),
              child: Row(children: [
                ClipRRect(borderRadius: BorderRadius.circular(12), child: SizedBox(width: 64, height: 64, child: Thumb(a))),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    (names[a.id] ?? a.title ?? 'Photo').trim().isEmpty ? 'Photo' : (names[a.id] ?? a.title ?? 'Photo'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    a.createDateTime.day.toString() + ' ' + _monthName(a.createDateTime.month) + ' ' + a.createDateTime.year.toString(),
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ])),
              ]),
            ),
            ListTile(leading: const Icon(Icons.open_in_full_rounded), title: const Text('Open photo'), onTap: () { Navigator.pop(context); _openPhoto(a, list); }),
            ListTile(
              leading: Icon(liked ? Icons.favorite : Icons.favorite_border),
              title: Text(liked ? 'Remove from favorites' : 'Add to favorites'),
              onTap: () async {
                Navigator.pop(context);
                setState(() { liked ? favorites.remove(a.id) : favorites.add(a.id); });
                await _save();
              },
            ),
            ListTile(leading: const Icon(Icons.tune_rounded), title: const Text('Edit photo'), onTap: () { Navigator.pop(context); _openPhotoEditor(a); }),
            ListTile(leading: const Icon(Icons.sell_outlined), title: const Text('Tags'), subtitle: Text((photoTags[a.id] ?? {}).join(' • ')), onTap: () { Navigator.pop(context); _showTagEditor(a); }),
            ListTile(leading: const Icon(Icons.share_rounded), title: const Text('Share photo'), onTap: () { Navigator.pop(context); _share([a], 'Shared from Little Memories'); }),
            ListTile(
              leading: Icon(hidden ? Icons.visibility_rounded : Icons.visibility_off_rounded),
              title: Text(hidden ? 'Unhide photo' : 'Hide photo'),
              onTap: () async {
                Navigator.pop(context);
                setState(() { hidden ? hiddenIds.remove(a.id) : hiddenIds.add(a.id); });
                await _save();
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(hidden ? 'Photo restored from Hidden.' : 'Photo moved to Hidden.')));
              },
            ),
            ListTile(leading: const Icon(Icons.delete_outline_rounded), title: const Text('Delete photo'), onTap: () { Navigator.pop(context); _deleteSinglePhoto(a); }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _showTagEditor(AssetEntity a) async {
    final c = TextEditingController(text: (photoTags[a.id] ?? {}).join(', '));
    final value = await showDialog<String>(context: context, builder: (_) => AlertDialog(
      title: const Text('Tag this photo'),
      content: TextField(controller: c, autofocus: true, maxLines: 3, decoration: const InputDecoration(labelText: 'Tags', hintText: 'family, birthday, travel, baby', helperText: 'Separate tags with commas')),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Save tags'))],
    ));
    c.dispose(); if (value == null) return;
    final tags = value.split(',').map((e)=>e.trim().toLowerCase()).where((e)=>e.isNotEmpty).toSet();
    setState(() { tags.isEmpty ? photoTags.remove(a.id) : photoTags[a.id] = tags; }); await _save();
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
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 4),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('All Photos', style: TextStyle(fontSize: 27, fontWeight: FontWeight.w900, letterSpacing: -.7)),
            Text(photos.length.toString() + ' photos on this phone', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.w600)),
          ])),
          IconButton(tooltip: 'Favorite photos', onPressed: () => setState(() { tab = 2; showAllPhotos = false; }), icon: Icon(favorites.isEmpty ? Icons.favorite_border_rounded : Icons.favorite_rounded)),
          IconButton(tooltip: 'Select photos', onPressed: () => setState(() => selectionMode = true), icon: const Icon(Icons.checklist_rounded)),
          PopupMenuButton<int>(
            tooltip: 'Grid density',
            initialValue: grid.clamp(2, 8),
            onSelected: (v) async { setState(() => grid = v); await _save(); },
            itemBuilder: (_) => [2,3,4,5,6,7,8].map((v) => PopupMenuItem(
              value: v,
              child: Row(children: [
                Icon(v == grid ? Icons.check_rounded : Icons.grid_4x4_rounded, size: 19),
                const SizedBox(width: 10),
                Text(v.toString() + ' columns'),
              ]),
            )).toList(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(14)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.grid_4x4_rounded, size: 20),
                const SizedBox(width: 5),
                Text(grid.toString() + '×', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
              ]),
            ),
          ),
          IconButton(tooltip: 'Refresh', onPressed: _refreshPhotos, icon: const Icon(Icons.refresh_rounded)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
        child: Row(children: [
          FilterChip(label: const Text('Newest'), selected: galleryNewestFirst, onSelected: (_) => setState(() => galleryNewestFirst = true)),
          const SizedBox(width: 7),
          FilterChip(label: const Text('Oldest'), selected: !galleryNewestFirst, onSelected: (_) => setState(() => galleryNewestFirst = false)),

        ]),
      ),
      Expanded(child: _gallery()),
    ]);
  }

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
    final cs = Theme.of(context).colorScheme;
    final custom = memoryAlbums.entries.toList();
    return CustomScrollView(slivers: [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 110),
        sliver: SliverList(delegate: SliverChildListDelegate([
          Row(children:[
            const Expanded(child:Text('Albums',style:TextStyle(fontSize:31,fontWeight:FontWeight.w900,letterSpacing:-.8))),
            PopupMenuButton<int>(tooltip:'Album grid size',initialValue:albumGrid.clamp(2,8),onSelected:(v)async{setState(()=>albumGrid=v);await _save();},itemBuilder:(_)=>[2,3,4,5,6,7,8].map((v)=>PopupMenuItem(value:v,child:Text(v.toString()+' columns'))).toList(),child:Container(padding:const EdgeInsets.symmetric(horizontal:10,vertical:8),decoration:BoxDecoration(color:cs.surfaceContainerHighest,borderRadius:BorderRadius.circular(14)),child:Text(albumGrid.toString()+'×',style:const TextStyle(fontWeight:FontWeight.w800)))),
            IconButton(onPressed:()async{await _refreshPhotos();await _refreshVideos();},tooltip:'Refresh folders',icon:const Icon(Icons.refresh_rounded)),
          ]),
          Text(deviceAlbums.length.toString() + ' folders from your phone', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
          const SizedBox(height: 18),

          Row(children:[Expanded(child:_specialAlbumCard(icon:Icons.photo_library_rounded,title:'All Photos',subtitle:photos.length.toString()+' photos',onTap:()=>setState(()=>tab=0))),const SizedBox(width:10),Expanded(child:_specialAlbumCard(icon:Icons.video_library_rounded,title:'Videos',subtitle:videos.length.toString()+' videos',onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>VideoAlbumPage(assets:videos,grid:albumGrid)))))]),
          const SizedBox(height: 10),
          Row(children:[
            Expanded(child:_specialAlbumCard(icon:Icons.lock_rounded,title:'Hidden',subtitle:hiddenIds.length.toString()+' private',onTap:_showHiddenMemories)),
            const SizedBox(width:10),
            Expanded(child:_specialAlbumCard(icon:Icons.description_rounded,title:'Documents',subtitle:'PDF, Word, Excel, PPT, text & more',onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const DocumentsPage())))),
          ]),
          const SizedBox(height:10),
          _specialAlbumCard(
            icon: Icons.delete_sweep_rounded,
            title: 'Recently Deleted',
            subtitle: deviceDeletedAlbums.isEmpty ? 'Not exposed by Android' : 'System trash • open to view',
            onTap: () {
              if (deviceDeletedAlbums.isEmpty) {
                _showDeletedInfo();
              } else {
                Navigator.push(context, MaterialPageRoute(builder: (_) => DeviceAlbumPage(
                  paths: deviceDeletedAlbums,
                  title: 'Recently Deleted',
                  grid: albumGrid,
                  hiddenIds: const {},
                  onEdit: _openPhotoEditor,
                  onShare: (a) => _share([a], 'Shared from Little Memories'),
                  onToggleFavorite: (a) async {},
                  onToggleHidden: (a) async {},
                )));
              }
            },
          ),

          if (custom.isNotEmpty) ...[
            const SizedBox(height: 28),
            const Text('Little Memories collections', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
            const SizedBox(height: 10),
            Wrap(spacing: 12, runSpacing: 12, children: custom.map((e) {
              AssetEntity? cover;
              for (final id in e.value) { final a = _find(id); if (a != null) { cover = a; break; } }
              final list = e.value.map(_find).whereType<AssetEntity>().toList();
              return _smallAlbumCard(title: e.key, subtitle: list.length.toString() + ' photos', asset: cover, onTap: list.isEmpty ? null : () => _openPhoto(list.first, list));
            }).toList()),
          ],

          const SizedBox(height: 30),
          Row(children: [
            const Expanded(child: Text('Phone folders', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900))),
            Text('Live from device', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 10),
          if (deviceAlbums.where((p) => !p.isAll).isEmpty)
            Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(20)), child: const Text('No separate photo folders were exposed by the phone.'))
          else
            Wrap(spacing: 12, runSpacing: 12, children: deviceAlbums.where((p) => !p.isAll).map((p) => _deviceAlbumCard(p)).toList()),

          const SizedBox(height: 30),
          Row(children: [
            const Expanded(child: Text('Smart albums', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900))),
            Text('By month', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11)),
          ]),
          const SizedBox(height: 10),
          _albumPreviewCards(),

          const SizedBox(height: 30),
          Row(children: [
            const Expanded(child: Text('Library tools', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900))),
            Text('Clean & organize', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: FilledButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DuplicatePhotosPage(photos: photos))), icon: const Icon(Icons.copy_all_outlined), label: const Text('Duplicates'))),
            const SizedBox(width: 10),
            Expanded(child: FilledButton.tonalIcon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BlurryPhotosPage(photos: photos))), icon: const Icon(Icons.blur_on), label: const Text('Blurry'))),
          ]),
        ])),
      ),
    ]);
  }

  Widget _specialAlbumCard({required IconData icon, required String title, required String subtitle, required VoidCallback onTap}) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(22), child: Container(
      height: 104, padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [cs.primaryContainer, cs.surface]),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(children: [
        Container(width: 44, height: 44, decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(15)), child: Icon(icon, color: cs.onPrimary)),
        const SizedBox(width: 11),
        Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
          const SizedBox(height: 3),
          Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10)),
        ])),
      ]),
    ));
  }

  Widget _deviceAlbumCard(AssetPathEntity path) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<List<AssetEntity>>(
      future: path.getAssetListPaged(page: 0, size: 1),
      builder: (_, s) {
        final cover = s.data?.isNotEmpty == true ? s.data!.first : null;
        return FutureBuilder<int>(
          future: path.assetCountAsync,
          builder: (_, countState) {
            final count = countState.data;
            return SizedBox(width: ((MediaQuery.of(context).size.width - 48) / 2).clamp(145.0, 220.0), height: 170, child: Card(clipBehavior: Clip.antiAlias, child: InkWell(
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DeviceAlbumPage(
                paths: [path],
                title: path.name,
                grid: albumGrid,
                hiddenIds: hiddenIds,
                onEdit: _openPhotoEditor,
                onShare: (a) => _share([a], 'Shared from Little Memories'),
                onToggleFavorite: (a) async {
                  if (!mounted) return;
                  setState(() {
                    if (favorites.contains(a.id)) { favorites.remove(a.id); } else { favorites.add(a.id); }
                  });
                  await _save();
                },
                onToggleHidden: (a) async {
                  if (!mounted) return;
                  setState(() {
                    if (hiddenIds.contains(a.id)) { hiddenIds.remove(a.id); } else { hiddenIds.add(a.id); }
                  });
                  await _save();
                },
              ))),
              child: Stack(fit: StackFit.expand, children: [
                cover == null ? Container(color: cs.surfaceContainerHighest, child: Icon(Icons.folder_rounded, size: 48, color: cs.primary)) : Thumb(cover),
                DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withValues(alpha: .84)]))),
                Positioned(left: 12, right: 12, bottom: 11, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(path.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 2),
                  Text(count == null ? 'Loading photos…' : count.toString() + ' photos', style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w700)),
                ])),
              ]),
            )));
          },
        );
      },
    );
  }

  Future<void> _showDeletedInfo() async {
    await showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text('Recently Deleted'),
      content: const Text('Android only exposes a system trash/recently-deleted folder to apps on some devices. This phone is not exposing one through the photo-library API, so Little Memories cannot safely show or restore those files.'),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
    ));
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
     if (galleryFilter == 5) source = source.where((a) => (photoTags[a.id] ?? {}).isNotEmpty).toList();
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
          onLongPress: () => selectionMode ? _toggleSelection(a) : _showPhotoActions(a, source),
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
            PopupMenuButton<int>(tooltip: 'Grid size', initialValue: grid, onSelected: (v) async { setState(() => grid = v); await _save(); }, itemBuilder: (_) => [2,3,4,5,6,7,8].map((v) => PopupMenuItem(value: v, child: Text('$v columns'))).toList(), child: const Icon(Icons.grid_view_rounded)),
          ])),
          SizedBox(height: 42, child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12), scrollDirection: Axis.horizontal,
            children: [
              for (final f in const [0, 1, 2, 3, 4, 5])
                Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(
                  label: Text(['All', 'Favorites', 'Named', 'Captions', 'In stories', 'Tagged'][f]),
                  selected: galleryFilter == f,
                  onSelected: (_) async { setState(() => galleryFilter = f); await _save(); },
                )),
            ],
          )),
          Expanded(child: _gallery()),
        ])
      : _dashboard();
    final body = tab == 0 ? galleryBody : tab == 1 ? _albumsTab() : tab == 2 ? PhotoSearchPage(photos: photos, videos: videos, names: names, captions: captions, tags: photoTags, favorites: favorites, hiddenIds: hiddenIds, grid: exploreGrid, onGrid: (v) async { setState(() => exploreGrid = v); await _save(); }, onOpen: (a, list) { if (a.type == AssetType.video) { Navigator.push(context, MaterialPageRoute(builder: (_) => VideoViewer(asset: a))); } else { _openPhoto(a, list); } }, onEdit: _openPhotoEditor, onShare: (a) => _share([a], 'Shared from Little Memories'), onToggleFavorite: (a) async { setState(() { favorites.contains(a.id) ? favorites.remove(a.id) : favorites.add(a.id); }); await _save(); }, onTags: _showTagEditor) : tab == 3 ? PhotoStatsPage(photos: photos, videos: videos, favorites: favorites, hiddenIds: hiddenIds, tags: photoTags, albums: deviceAlbums, names: names, captions: captions) : SettingsPage(
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
      body: SafeArea(
        top: tab == 0,
        bottom: false,
        child: body,
      ),
      floatingActionButton: tab == 0 && !selectionMode ? FloatingActionButton(
        tooltip: 'Memory tools',
        onPressed: () => showModalBottomSheet(
          context: context,
          builder: (_) => SafeArea(child: Wrap(children: [
            const ListTile(title: Text('Create your next memory collection', style: TextStyle(fontWeight: FontWeight.w900))),
            ListTile(leading: const Icon(Icons.checklist_rounded), title: const Text('Select photos'), onTap: () { Navigator.pop(context); setState(() => selectionMode = true); }),
            ListTile(leading: const Icon(Icons.insights_rounded), title: const Text('Memory statistics'), onTap: () { Navigator.pop(context); _memoryStatistics(); }),
            ListTile(leading: const Icon(Icons.palette_outlined), title: const Text('Color Palette Search'), subtitle: const Text('Find photos with a similar color mood'), onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => ColorPaletteSearchPage(photos: photos))); }),
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
        selectedIndex: tab,
        onDestinationSelected: (v) {
          setState(() { tab = v; if (v == 0) showAllPhotos = false; });
          // Videos are indexed only when the Albums workspace is actually opened.
          if (v == 1 || v == 2) unawaited(_refreshVideos());
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.collections_bookmark_outlined), selectedIcon: Icon(Icons.collections_bookmark), label: 'Albums'),
          NavigationDestination(icon: Icon(Icons.search_rounded), selectedIcon: Icon(Icons.search_rounded), label: 'Explore'),
          NavigationDestination(icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights_rounded), label: 'Stats'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}



class PhotoSearchPage extends StatefulWidget {
  final List<AssetEntity> photos, videos;
  final Map<String,String> names, captions;
  final Map<String,Set<String>> tags;
  final Set<String> favorites, hiddenIds;
  final int grid;
  final Future<void> Function(int) onGrid;
  final void Function(AssetEntity,List<AssetEntity>) onOpen;
  final Future<void> Function(AssetEntity) onEdit, onShare, onToggleFavorite, onTags;

  const PhotoSearchPage({
    super.key, required this.photos, required this.videos, required this.names,
    required this.captions, required this.tags, required this.favorites,
    required this.hiddenIds, required this.grid, required this.onGrid,
    required this.onOpen, required this.onEdit, required this.onShare,
    required this.onToggleFavorite, required this.onTags,
  });

  @override State<PhotoSearchPage> createState() => _PhotoSearchPageState();
}

class _PhotoSearchPageState extends State<PhotoSearchPage> {
  late TextEditingController c;
  String q = '';
  bool favOnly = false;
  bool advanced = false;
  int filter = 0;
  int mediaFilter = 0;
  int sortMode = 0;
  late int localGrid;
  final List<String> history = [];

  @override void initState() {
    super.initState();
    c = TextEditingController();
    localGrid = widget.grid;
  }

  @override void dispose() {
    c.dispose();
    super.dispose();
  }

  String _month(int m) => const [
    'january','february','march','april','may','june',
    'july','august','september','october','november','december'
  ][m - 1];

  List<AssetEntity> get results {
    final all = <AssetEntity>[];
    final seen = <String>{};
    for (final a in [...widget.photos, ...widget.videos]) {
      if (seen.add(a.id) && !widget.hiddenIds.contains(a.id)) all.add(a);
    }

    final now = DateTime.now();
    final x = q.trim().toLowerCase();
    final tokens = x.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();

    final wantsFavorite = favOnly || tokens.any((t) => t == 'favorite' || t == 'favorites' || t == 'loved');
    final wantsTagged = filter == 1 || tokens.any((t) => t == 'tagged' || t == 'tags');
    final wantsVideo = mediaFilter == 2 || tokens.any((t) => t == 'video' || t == 'videos');
    final wantsPhoto = mediaFilter == 1 || tokens.any((t) => t == 'photo' || t == 'photos');
    final wantsLandscape = filter == 3 || tokens.contains('landscape');
    final wantsPortrait = filter == 4 || tokens.contains('portrait');

    if (wantsFavorite) all.removeWhere((a) => !widget.favorites.contains(a.id));
    if (wantsTagged) all.removeWhere((a) => (widget.tags[a.id] ?? {}).isEmpty);
    if (filter == 2 || tokens.contains('thisyear') || tokens.contains('this-year')) {
      all.removeWhere((a) => a.createDateTime.year != now.year);
    }
    if (tokens.contains('lastyear') || tokens.contains('last-year')) {
      all.removeWhere((a) => a.createDateTime.year != now.year - 1);
    }
    if (tokens.contains('today')) {
      all.removeWhere((a) => a.createDateTime.year != now.year ||
          a.createDateTime.month != now.month || a.createDateTime.day != now.day);
    }
    if (wantsVideo) all.removeWhere((a) => a.type != AssetType.video);
    if (wantsPhoto) all.removeWhere((a) => a.type == AssetType.video);
    if (wantsLandscape) all.removeWhere((a) => a.width <= a.height);
    if (wantsPortrait) all.removeWhere((a) => a.height <= a.width);
    if (tokens.contains('square')) all.removeWhere((a) => a.width != a.height);
    if (tokens.contains('high resolution') || tokens.contains('high-resolution') || tokens.contains('highres')) {
      all.removeWhere((a) => a.width * a.height < 12000000);
    }

    if (x.isNotEmpty) {
      all.removeWhere((a) {
        final hay = [
          widget.names[a.id] ?? '',
          widget.captions[a.id] ?? '',
          a.title ?? '',
          (widget.tags[a.id] ?? {}).join(' '),
          a.relativePath ?? '',
          a.createDateTime.year.toString(),
          a.createDateTime.month.toString(),
          _month(a.createDateTime.month),
          a.type == AssetType.video ? 'video' : 'photo',
        ].join(' ').toLowerCase();
        return !(hay.contains(x) || tokens.every(hay.contains));
      });
    }

    int score(AssetEntity a) {
      if (x.isEmpty) return 0;
      final hay = [
        widget.names[a.id] ?? '',
        widget.captions[a.id] ?? '',
        a.title ?? '',
        (widget.tags[a.id] ?? {}).join(' '),
        a.relativePath ?? '',
      ].join(' ').toLowerCase();
      var score = hay.contains(x) ? 20 : 0;
      for (final t in tokens) {
        if (hay.contains(t)) score += 3;
      }
      if (widget.favorites.contains(a.id)) score++;
      if ((widget.tags[a.id] ?? {}).isNotEmpty) score++;
      if (widget.names[a.id]?.trim().isNotEmpty == true) score++;
      return score;
    }

    all.sort((a, b) {
      if (sortMode == 1) return b.createDateTime.compareTo(a.createDateTime);
      if (sortMode == 2) return a.createDateTime.compareTo(b.createDateTime);
      if (sortMode == 3) {
        final ap = a.width * a.height;
        final bp = b.width * b.height;
        return bp.compareTo(ap);
      }
      final s = score(b).compareTo(score(a));
      return s != 0 ? s : b.createDateTime.compareTo(a.createDateTime);
    });
    return all;
  }

  String _ai() {
    final x = q.trim().toLowerCase();
    if (x.isEmpty) {
      return 'Ask for favorites, videos, tags, people names, folders, dates, years, landscape, portrait or high-resolution memories.';
    }
    final understood = <String>[];
    if (x.contains('favorite') || x.contains('loved')) understood.add('favorites');
    if (x.contains('video')) understood.add('videos');
    if (x.contains('tag')) understood.add('tags');
    if (x.contains('landscape')) understood.add('landscape');
    if (x.contains('portrait')) understood.add('portrait');
    if (x.contains('today') || x.contains('year') || RegExp(r'\b20\d{2}\b').hasMatch(x)) understood.add('dates');
    if (x.contains('high') || x.contains('resolution')) understood.add('quality');
    return understood.isEmpty
        ? 'Searching names, captions, tags, folders and dates.'
        : 'Smart interpretation: ' + understood.join(' • ');
  }

  void _runQuick(String value) {
    c.text = value;
    setState(() => q = value);
  }

  Future<void> _actions(AssetEntity a, List<AssetEntity> list) {
    return showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Wrap(children: [
          ListTile(
            leading: const Icon(Icons.open_in_full_rounded),
            title: const Text('Open memory'),
            onTap: () { Navigator.pop(context); widget.onOpen(a, list); },
          ),
          ListTile(
            leading: Icon(widget.favorites.contains(a.id) ? Icons.favorite : Icons.favorite_border),
            title: Text(widget.favorites.contains(a.id) ? 'Remove favorite' : 'Add favorite'),
            onTap: () { Navigator.pop(context); widget.onToggleFavorite(a); },
          ),
          ListTile(
            leading: const Icon(Icons.sell_outlined),
            title: const Text('Tags'),
            onTap: () { Navigator.pop(context); widget.onTags(a); },
          ),
          ListTile(
            leading: const Icon(Icons.tune_rounded),
            title: const Text('Edit'),
            onTap: () { Navigator.pop(context); widget.onEdit(a); },
          ),
          ListTile(
            leading: const Icon(Icons.share_rounded),
            title: const Text('Share'),
            onTap: () { Navigator.pop(context); widget.onShare(a); },
          ),
        ]),
      ),
    );
  }

  @override Widget build(BuildContext context) {
    final list = results;
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 5),
        child: Row(children: [
          const Expanded(child: Text('AI Explore', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900))),
          IconButton(
            tooltip: 'Favorites only',
            onPressed: () => setState(() => favOnly = !favOnly),
            icon: Icon(favOnly ? Icons.favorite_rounded : Icons.favorite_border_rounded),
          ),
          IconButton(
            tooltip: 'Smart filters',
            onPressed: () => setState(() => advanced = !advanced),
            icon: Icon(advanced ? Icons.tune_rounded : Icons.tune_outlined),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'best') setState(() => sortMode = 0);
              if (v == 'new') setState(() => sortMode = 1);
              if (v == 'old') setState(() => sortMode = 2);
              if (v == 'large') setState(() => sortMode = 3);
              if (v.startsWith('g')) {
                final n = int.parse(v.substring(1));
                setState(() => localGrid = n);
                widget.onGrid(n);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'best', child: Text('AI relevance')),
              const PopupMenuItem(value: 'new', child: Text('Newest first')),
              const PopupMenuItem(value: 'old', child: Text('Oldest first')),
              const PopupMenuItem(value: 'large', child: Text('Highest resolution')),
              const PopupMenuDivider(),
              for (final v in [2,3,4,5,6,7,8])
                PopupMenuItem(value: 'g' + v.toString(), child: Text(v.toString() + ' columns')),
            ],
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 7),
        child: TextField(
          controller: c,
          onChanged: (v) => setState(() => q = v),
          onSubmitted: (v) {
            final x = v.trim();
            if (x.isNotEmpty && !history.contains(x)) {
              setState(() {
                history.insert(0, x);
                if (history.length > 6) history.removeLast();
              });
            }
          },
          decoration: InputDecoration(
            hintText: 'Ask: favorite birthday videos 2025',
            prefixIcon: const Icon(Icons.auto_awesome_rounded),
            suffixIcon: q.isEmpty ? null : IconButton(
              onPressed: () { c.clear(); setState(() => q = ''); },
              icon: const Icon(Icons.clear_rounded),
            ),
            filled: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
          ),
        ),
      ),
      Card(
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 7),
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.psychology_alt_outlined),
          title: const Text('AI memory understanding', style: TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text(_ai()),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(list.length.toString(), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
              const Text('matches', style: TextStyle(fontSize: 10)),
            ],
          ),
        ),
      ),
      if (advanced)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 7),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            FilterChip(label: const Text('All'), selected: mediaFilter == 0, onSelected: (_) => setState(() => mediaFilter = 0)),
            FilterChip(label: const Text('Photos'), selected: mediaFilter == 1, onSelected: (_) => setState(() => mediaFilter = 1)),
            FilterChip(label: const Text('Videos'), selected: mediaFilter == 2, onSelected: (_) => setState(() => mediaFilter = 2)),
            FilterChip(label: const Text('Tagged'), selected: filter == 1, onSelected: (_) => setState(() => filter = filter == 1 ? 0 : 1)),
            FilterChip(label: const Text('This year'), selected: filter == 2, onSelected: (_) => setState(() => filter = filter == 2 ? 0 : 2)),
            FilterChip(label: const Text('Landscape'), selected: filter == 3, onSelected: (_) => setState(() => filter = filter == 3 ? 0 : 3)),
            FilterChip(label: const Text('Portrait'), selected: filter == 4, onSelected: (_) => setState(() => filter = filter == 4 ? 0 : 4)),
          ]),
        ),
      Card(
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 7),
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.auto_awesome),
          title: const Text('Quick AI searches', style: TextStyle(fontWeight: FontWeight.w800)),
          subtitle: const Text('Favorites • videos • tagged • dates • folders • dimensions'),
        ),
      ),
      if (q.isEmpty)
        SizedBox(
          height: 72,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            children: [
              for (final x in const [
                'Favorite memories','Favorite videos','Videos this year','Tagged memories',
                'Untagged photos','Landscape this year','Portrait photos','Photos today',
                'Photos before 2025','Photos after 2024'
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 7),
                  child: ActionChip(
                    avatar: const Icon(Icons.auto_awesome, size: 15),
                    label: Text(x),
                    onPressed: () => _runQuick(x),
                  ),
                ),
            ],
          ),
        ),
      if (history.isNotEmpty && q.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 5),
          child: Wrap(
            spacing: 5,
            children: history.take(5).map((x) => InputChip(
              label: Text(x),
              onPressed: () => _runQuick(x),
              onDeleted: () => setState(() => history.remove(x)),
            )).toList(),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
        child: Row(children: [
          Text(list.length.toString() + ' results', style: TextStyle(fontWeight: FontWeight.w800, color: cs.onSurfaceVariant)),
          const Spacer(),
          Text(
            sortMode == 0 ? 'AI ranked' : sortMode == 1 ? 'Newest' : sortMode == 2 ? 'Oldest' : 'Resolution',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ]),
      ),
      Expanded(
        child: list.isEmpty
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.search_off_rounded, size: 58),
                const SizedBox(height: 10),
                const Text('No memories matched', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                const Text('Try a year, folder, tag, favorite, video or date', textAlign: TextAlign.center),
              ]))
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(7, 2, 7, 24),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: localGrid.clamp(2, 8),
                  crossAxisSpacing: 5,
                  mainAxisSpacing: 5,
                ),
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final a = list[i];
                  final tags = (widget.tags[a.id] ?? {}).take(2).join(' • ');
                  return GestureDetector(
                    onTap: () => widget.onOpen(a, list),
                    onLongPress: () => _actions(a, list),
                    child: Stack(fit: StackFit.expand, children: [
                      ClipRRect(borderRadius: BorderRadius.circular(8), child: Thumb(a)),
                      if (a.type == AssetType.video)
                        const Positioned(
                          left: 6, bottom: 6,
                          child: CircleAvatar(
                            radius: 13,
                            backgroundColor: Colors.black54,
                            child: Icon(Icons.play_arrow_rounded, color: Colors.white),
                          ),
                        ),
                      if (widget.favorites.contains(a.id))
                        const Positioned(right: 5, top: 5, child: Icon(Icons.favorite_rounded, color: Colors.white)),
                      if (tags.isNotEmpty)
                        Positioned(
                          left: 5, top: 5, right: 28,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(7)),
                            child: Text(tags, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w700)),
                          ),
                        ),
                      Positioned(
                        left: 5, right: 5, bottom: 5,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(7)),
                          child: Text(
                            a.type == AssetType.video
                                ? 'VIDEO'
                                : ((a.relativePath ?? '').split('/').where((x) => x.isNotEmpty).isEmpty
                                    ? 'Photo'
                                    : (a.relativePath ?? '').split('/').where((x) => x.isNotEmpty).last),
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ]),
                  );
                },
              ),
      ),
    ]);
  }
}

class PhotoStatsPage extends StatefulWidget{final List<AssetEntity> photos,videos;final Set<String> favorites,hiddenIds;final Map<String,Set<String>> tags;final List<AssetPathEntity> albums;final Map<String,String> names,captions;const PhotoStatsPage({super.key,required this.photos,required this.videos,required this.favorites,required this.hiddenIds,required this.tags,required this.albums,required this.names,required this.captions});@override State<PhotoStatsPage> createState()=>_PhotoStatsPageState();}
class _PhotoStatsPageState extends State<PhotoStatsPage>{int bytes=0,measured=0;bool measuring=true;@override void initState(){super.initState();_measure();}Future<void> _measure()async{var b=0,n=0;for(final a in widget.photos){try{final f=await a.file;if(f!=null&&await f.exists()){b+=await f.length();n++;if(mounted&&n%10==0)setState((){bytes=b;measured=n;});}}catch(_){}}if(mounted)setState((){bytes=b;measured=n;measuring=false;});}String _size(int b)=>b>=1073741824?(b/1073741824).toStringAsFixed(2)+' GB':b>=1048576?(b/1048576).toStringAsFixed(1)+' MB':(b/1024).toStringAsFixed(0)+' KB';@override Widget build(BuildContext context){final cs=Theme.of(context).colorScheme;final total=max(1,widget.photos.length);final years=<int>{};final tc=<String,int>{};final folders=<String,int>{};int land=0,port=0,square=0;double px=0;for(final a in widget.photos){years.add(a.createDateTime.year);if(a.width>a.height)land++;else if(a.height>a.width)port++;else square++;px+=a.width*a.height;final folder=(a.relativePath??'Unknown').split('/').where((e)=>e.isNotEmpty).lastOrNull??'Unknown';folders[folder]=(folders[folder]??0)+1;for(final t in widget.tags[a.id]??{})tc[t]=(tc[t]??0)+1;}final tags=tc.entries.toList()..sort((a,b)=>b.value.compareTo(a.value));final topFolders=folders.entries.toList()..sort((a,b)=>b.value.compareTo(a.value));final named=widget.photos.where((a)=>(widget.names[a.id]??'').trim().isNotEmpty).length;final cap=widget.photos.where((a)=>(widget.captions[a.id]??'').trim().isNotEmpty).length;final tagCoverage=(widget.tags.length/total*100).round();final favoriteRate=(widget.favorites.length/total*100).round();final score=((tagCoverage*.35)+(favoriteRate*.15)+(named/total*25)+(cap/total*15)+(years.length.clamp(0,10)/10*10)).round().clamp(0,100);final rec=<String>[];if(tagCoverage<25)rec.add('Tag more memories to make AI Explore more precise.');if(named<total*.2)rec.add('Name important memories for better discovery.');if(cap<total*.15)rec.add('Add captions to preserve context for future stories.');if(widget.favorites.isEmpty)rec.add('Favorite your best memories to create instant highlights.');if(rec.isEmpty)rec.add('Your metadata is healthy. Try AI Explore for smart discovery.');return RefreshIndicator(onRefresh:_measure,child:ListView(padding:const EdgeInsets.fromLTRB(14,14,14,110),children:[Row(children:[const Expanded(child:Text('Photo Intelligence',style:TextStyle(fontSize:29,fontWeight:FontWeight.w900))),Chip(avatar:const Icon(Icons.auto_awesome,size:16),label:const Text('AI'))]),Text('Understand, organize and rediscover your library',style:TextStyle(color:cs.onSurfaceVariant)),const SizedBox(height:18),GridView.count(crossAxisCount:2,shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),crossAxisSpacing:10,mainAxisSpacing:10,childAspectRatio:1.55,children:[_tile(context,Icons.photo_library_rounded,widget.photos.length.toString(),'Photos'),_tile(context,Icons.video_library_rounded,widget.videos.length.toString(),'Videos'),_tile(context,Icons.favorite_rounded,widget.favorites.length.toString(),'Favorites'),_tile(context,Icons.lock_rounded,widget.hiddenIds.length.toString(),'Private'),_tile(context,Icons.sell_outlined,widget.tags.length.toString(),'Tagged'),_tile(context,Icons.folder_rounded,widget.albums.where((a)=>!a.isAll).length.toString(),'Folders')]),const SizedBox(height:12),Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Row(children:[const Icon(Icons.psychology_alt_outlined),const SizedBox(width:8),const Text('AI Library Health',style:TextStyle(fontSize:19,fontWeight:FontWeight.w900)),const Spacer(),Text(score.toString()+'/100',style:const TextStyle(fontWeight:FontWeight.w900))]),const SizedBox(height:10),LinearProgressIndicator(value:score.toDouble()/100,minHeight:8,borderRadius:BorderRadius.circular(8)),const SizedBox(height:10),Text(score>=80?'Your library is beautifully organized.':score>=55?'Strong foundation — more metadata will unlock smarter discovery.':'Your memories are rich; tags, names and captions will make them easier to rediscover.'),const SizedBox(height:10),Wrap(spacing:7,children:[Chip(label:Text(tagCoverage.toString()+'% tagged')),Chip(label:Text(favoriteRate.toString()+'% loved')),Chip(label:Text(widget.videos.length.toString()+' videos'))])]))),const SizedBox(height:12),Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('AI recommendations',style:TextStyle(fontSize:18,fontWeight:FontWeight.w900)),const SizedBox(height:8),...rec.map((x)=>ListTile(contentPadding:EdgeInsets.zero,leading:const Icon(Icons.auto_awesome),title:Text(x)))]))),const SizedBox(height:12),Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('AI story ideas',style:TextStyle(fontSize:18,fontWeight:FontWeight.w900)),const SizedBox(height:8),_idea('Favorite memories','A highlight story from your loved photos.'),_idea('Family video diary',widget.videos.isEmpty?'Add videos to build a family video diary.':widget.videos.length.toString()+' videos are ready.'),_idea('Untagged treasure hunt',rec.first)]))),const SizedBox(height:12),Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Library overview',style:TextStyle(fontSize:18,fontWeight:FontWeight.w900)),const SizedBox(height:8),Text('Named photos: '+named.toString()),Text('Captions: '+cap.toString()),Text('Date span: '+(years.isEmpty?'—':years.reduce(min).toString()+' → '+years.reduce(max).toString())),Text('Orientation: '+land.toString()+' landscape • '+port.toString()+' portrait • '+square.toString()+' square'),Text('Estimated pixels: '+(px/1000000).toStringAsFixed(0)+' MP'),Text('Folders: '+widget.albums.where((a)=>!a.isAll).length.toString())]))),const SizedBox(height:12),Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Most used tags',style:TextStyle(fontSize:18,fontWeight:FontWeight.w900)),const SizedBox(height:8),tags.isEmpty?const Text('No tags yet. Long-press any photo to add them.'):Wrap(spacing:7,runSpacing:7,children:tags.take(15).map((e)=>Chip(label:Text(e.key+' • '+e.value.toString()))).toList())]))),const SizedBox(height:12),Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Top phone folders',style:TextStyle(fontSize:18,fontWeight:FontWeight.w900)),const SizedBox(height:8),...topFolders.take(8).map((e)=>ListTile(contentPadding:EdgeInsets.zero,leading:const Icon(Icons.folder_outlined),title:Text(e.key),trailing:Text(e.value.toString())))]))),const SizedBox(height:12),Card(child:ListTile(leading:const Icon(Icons.storage_rounded),title:Text(measuring?'Calculating photo storage…':'Photo storage'),subtitle:Text(measuring?measured.toString()+' files measured':_size(bytes)),onTap:_measure))]));}Widget _idea(String t,String s)=>ListTile(contentPadding:EdgeInsets.zero,leading:const Icon(Icons.auto_awesome),title:Text(t,style:const TextStyle(fontWeight:FontWeight.w800)),subtitle:Text(s));Widget _tile(BuildContext c,IconData i,String v,String l){final cs=Theme.of(c).colorScheme;return Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Icon(i,color:cs.primary),const Spacer(),Text(v,style:const TextStyle(fontSize:21,fontWeight:FontWeight.w900)),Text(l,style:TextStyle(fontSize:11,color:cs.onSurfaceVariant))])));}}
class DeviceAlbumPage extends StatefulWidget {
  final List<AssetPathEntity> paths;
  final String title;
  final int grid;
  final Set<String> hiddenIds;
  final Future<void> Function(AssetEntity) onEdit;
  final Future<void> Function(AssetEntity) onShare;
  final Future<void> Function(AssetEntity) onToggleFavorite;
  final Future<void> Function(AssetEntity) onToggleHidden;
  const DeviceAlbumPage({
    super.key,
    required this.paths,
    required this.title,
    required this.grid,
    required this.hiddenIds,
    required this.onEdit,
    required this.onShare,
    required this.onToggleFavorite,
    required this.onToggleHidden,
  });
  @override State<DeviceAlbumPage> createState() => _DeviceAlbumPageState();
}

class _DeviceAlbumPageState extends State<DeviceAlbumPage> {
  List<AssetEntity> assets = [];
  bool loading = true;

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final out = <AssetEntity>[];
    final seen = <String>{};
    for (final path in widget.paths) {
      var page = 0;
      while (true) {
        final batch = await path.getAssetListPaged(page: page, size: 200);
        if (batch.isEmpty) break;
        for (final a in batch) {
          if (seen.add(a.id)) out.add(a);
        }
        if (batch.length < 200) break;
        page++;
      }
    }
    out.sort((a,b) => b.createDateTime.compareTo(a.createDateTime));
    if (mounted) setState(() { assets = out; loading = false; });
  }

  @override Widget build(BuildContext context) {
    final visible = assets.where((a) => !widget.hiddenIds.contains(a.id)).toList();
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: [
        Padding(padding: const EdgeInsets.only(right: 16), child: Center(child: Text(visible.length.toString()))),
      ]),
      body: loading
        ? const Center(child: CircularProgressIndicator())
        : visible.isEmpty
          ? const Center(child: Text('No photos in this folder.'))
          : GridView.builder(
              padding: const EdgeInsets.all(5),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: widget.grid.clamp(2, 8),
                crossAxisSpacing: 4, mainAxisSpacing: 4,
              ),
              itemCount: visible.length,
              itemBuilder: (_, i) => GestureDetector(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CinematicViewer(
                  asset: visible[i],
                  all: visible,
                  onEdit: widget.onEdit,
                  onShare: widget.onShare,
                  onToggleFavorite: widget.onToggleFavorite,
                ))),
                onLongPress: () => showModalBottomSheet(
                  context: context,
                  showDragHandle: true,
                  builder: (_) => SafeArea(child: Wrap(children: [
                    ListTile(leading: const Icon(Icons.open_in_full_rounded), title: const Text('Open photo'), onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => CinematicViewer(
                        asset: visible[i], all: visible, onEdit: widget.onEdit, onShare: widget.onShare,
                        onToggleFavorite: widget.onToggleFavorite,
                      )));
                    }),
                    ListTile(leading: const Icon(Icons.tune_rounded), title: const Text('Edit photo'), onTap: () { Navigator.pop(context); widget.onEdit(visible[i]); }),
                    ListTile(leading: const Icon(Icons.share_rounded), title: const Text('Share photo'), onTap: () { Navigator.pop(context); widget.onShare(visible[i]); }),
                    ListTile(leading: const Icon(Icons.visibility_off_rounded), title: const Text('Hide photo'), onTap: () { Navigator.pop(context); widget.onToggleHidden(visible[i]); }),
                  ])),
                ),
                child: ClipRRect(borderRadius: BorderRadius.circular(6), child: Thumb(visible[i])),
              ),
            ),
    );
  }
}

class VideoAlbumPage extends StatelessWidget {
  final List<AssetEntity> assets;
  final int grid;
  const VideoAlbumPage({super.key, required this.assets, required this.grid});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('All Videos'),
        actions: [Padding(padding: const EdgeInsets.only(right: 16), child: Center(child: Text(assets.length.toString())))],
      ),
      body: assets.isEmpty
          ? const Center(child: Text('No videos found on this phone.'))
          : GridView.builder(
              padding: const EdgeInsets.all(6),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: grid.clamp(2, 8),
                crossAxisSpacing: 5,
                mainAxisSpacing: 5,
              ),
              itemCount: assets.length,
              itemBuilder: (_, i) {
                final a = assets[i];
                final duration = a.videoDuration.inMinutes.toString().padLeft(2, '0') +
                    ':' +
                    (a.videoDuration.inSeconds % 60).toString().padLeft(2, '0');
                return GestureDetector(
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => VideoViewer(asset: a))),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Thumb(a),
                        const Center(
                          child: CircleAvatar(
                            backgroundColor: Colors.black54,
                            child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28),
                          ),
                        ),
                        Positioned(
                          left: 7,
                          bottom: 7,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                            child: Text(duration, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class VideoViewer extends StatefulWidget {
  final AssetEntity asset;
  const VideoViewer({super.key, required this.asset});
  @override State<VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<VideoViewer> {
  VideoPlayerController? controller;
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final file = await widget.asset.file;
      if (file == null) {
        if (mounted) setState(() { loading = false; error = 'Video file is unavailable.'; });
        return;
      }
      final player = VideoPlayerController.file(file);
      await player.initialize();
      if (mounted) {
        setState(() { controller = player; loading = false; });
      } else {
        await player.dispose();
      }
    } catch (e) {
      if (mounted) setState(() { loading = false; error = e.toString(); });
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  String _time(Duration d) {
    return d.inMinutes.toString() + ':' + (d.inSeconds % 60).toString().padLeft(2, '0');
  }

  @override
  Widget build(BuildContext context) {
    final player = controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.asset.title ?? 'Video'),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(child: Text(error!, style: const TextStyle(color: Colors.white)))
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AspectRatio(aspectRatio: player!.value.aspectRatio, child: VideoPlayer(player)),
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          IconButton(
                            color: Colors.white,
                            icon: Icon(player.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, size: 42),
                            onPressed: () {
                              setState(() {
                                if (player.value.isPlaying) {
                                  player.pause();
                                } else {
                                  player.play();
                                }
                              });
                            },
                          ),
                          Expanded(child: VideoProgressIndicator(player, allowScrubbing: true, padding: const EdgeInsets.symmetric(horizontal: 8))),
                          Text(_time(player.value.position), style: const TextStyle(color: Colors.white, fontSize: 11)),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}

class DocumentFileItem {
  final String path;
  final String name;
  final String extension;
  final int size;
  final DateTime modified;
  const DocumentFileItem({required this.path, required this.name, required this.extension, required this.size, required this.modified});
}

class DocumentsPage extends StatefulWidget {
  const DocumentsPage({super.key});
  @override State<DocumentsPage> createState() => _DocumentsPageState();
}

class _DocumentsPageState extends State<DocumentsPage> {
  final controller = TextEditingController();
  List<DocumentFileItem> docs = [];
  bool loading = true;
  String query = '';
  static const extensions = {'pdf','doc','docx','xls','xlsx','ppt','pptx','txt','csv','rtf','odt','ods','odp','md','json','xml','epub'};

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    if (!Platform.isAndroid) {
      if (mounted) setState(() => loading = false);
      return;
    }
    var granted = (await Permission.manageExternalStorage.status).isGranted;
    if (!granted) {
      await Permission.manageExternalStorage.request();
      granted = (await Permission.manageExternalStorage.status).isGranted;
    }
    if (!granted) {
      if (mounted) setState(() => loading = false);
      return;
    }

    final found = <DocumentFileItem>[];
    final queue = <Directory>[Directory('/storage/emulated/0')];
    final seen = <String>{};

    while (queue.isNotEmpty && found.length < 10000) {
      final dir = queue.removeLast();
      try {
        if (!seen.add(dir.path)) continue;
        await for (final entity in dir.list(followLinks: false)) {
          final name = entity.path.split('/').last;
          if (entity is Directory) {
            if (name == 'Android' || name.startsWith('.')) continue;
            queue.add(entity);
          } else if (entity is File) {
            final dot = name.lastIndexOf('.');
            if (dot <= 0) continue;
            final ext = name.substring(dot + 1).toLowerCase();
            if (!extensions.contains(ext)) continue;
            try {
              final stat = await entity.stat();
              found.add(DocumentFileItem(path: entity.path, name: name, extension: ext, size: stat.size, modified: stat.modified));
            } catch (_) {}
          }
        }
      } catch (_) {}
    }

    found.sort((a, b) => b.modified.compareTo(a.modified));
    if (mounted) setState(() { docs = found; loading = false; });
  }

  List<DocumentFileItem> get filtered {
    final x = query.trim().toLowerCase();
    if (x.isEmpty) return docs;
    return docs.where((d) => d.name.toLowerCase().contains(x) || d.extension.contains(x) || d.path.toLowerCase().contains(x)).toList();
  }

  String _size(int n) {
    if (n >= 1073741824) return (n / 1073741824).toStringAsFixed(1) + ' GB';
    if (n >= 1048576) return (n / 1048576).toStringAsFixed(1) + ' MB';
    if (n >= 1024) return (n / 1024).toStringAsFixed(0) + ' KB';
    return n.toString() + ' B';
  }

  IconData _icon(String e) {
    if (e == 'pdf') return Icons.picture_as_pdf_rounded;
    if ({'doc','docx','odt'}.contains(e)) return Icons.article_rounded;
    if ({'xls','xlsx','ods','csv'}.contains(e)) return Icons.table_chart_rounded;
    if ({'ppt','pptx','odp'}.contains(e)) return Icons.slideshow_rounded;
    return Icons.description_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final list = filtered;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Documents'),
        actions: [
          IconButton(onPressed: _scan, tooltip: 'Rescan', icon: const Icon(Icons.refresh_rounded)),
          Padding(padding: const EdgeInsets.only(right: 16), child: Center(child: Text(list.length.toString()))),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: TextField(
                    controller: controller,
                    onChanged: (v) => setState(() => query = v),
                    decoration: InputDecoration(
                      hintText: 'Search documents, folders or type…',
                      prefixIcon: const Icon(Icons.search_rounded),
                      filled: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(list.length.toString() + ' documents • ' + docs.length.toString() + ' indexed', style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ),
                ),
                Expanded(
                  child: list.isEmpty
                      ? const Center(child: Padding(padding: EdgeInsets.all(28), child: Text('No accessible documents. Enable “Allow access to manage all files” in Android settings so Little Memories can scan shared storage.', textAlign: TextAlign.center)))
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(10, 0, 10, 30),
                          itemCount: list.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 6),
                          itemBuilder: (_, i) {
                            final d = list[i];
                            return Card(
                              child: ListTile(
                                onTap: () => OpenFile.open(d.path),
                                leading: CircleAvatar(child: Icon(_icon(d.extension))),
                                title: Text(d.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                                subtitle: Text(d.extension.toUpperCase() + ' • ' + _size(d.size) + ' • ' + d.path.replaceFirst('/storage/emulated/0/', '')),
                                trailing: const Icon(Icons.open_in_new_rounded),
                              ),
                            );
                          },
                        ),
                ),
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
    } else if(style==6){
      for(double x=0;x<size.width;x+=72) for(double y=0;y<size.height;y+=72) canvas.drawCircle(Offset(x+20,y+20),10,p);
    } else if(style==7){
      for(double x=20;x<size.width;x+=80) { canvas.drawCircle(Offset(x,42),20,p); canvas.drawLine(Offset(x-24,70),Offset(x+24,70),p); }
    } else if(style==8){
      for(double x=-size.height;x<size.width;x+=70) canvas.drawLine(Offset(x,0),Offset(x+size.height,size.height),p);
    } else if(style==9){
      for(double y=18;y<size.height;y+=42) canvas.drawLine(Offset(0,y),Offset(size.width,y),p);
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
    _future = widget.asset.thumbnailDataWithSize(const ThumbnailSize(320, 320));
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

class ColorPaletteSearchPage extends StatefulWidget {
  final List<AssetEntity> photos;
  const ColorPaletteSearchPage({super.key, required this.photos});

  @override
  State<ColorPaletteSearchPage> createState() => _ColorPaletteSearchPageState();
}

class _ColorPaletteSearchPageState extends State<ColorPaletteSearchPage> {
  AssetEntity? reference;
  List<Color> referencePalette = [];
  List<MapEntry<AssetEntity, double>> matches = [];
  bool busy = false;
  int scanned = 0;

  Future<List<Color>> _paletteFor(AssetEntity asset) async {
    final bytes = await asset.thumbnailDataWithSize(const ThumbnailSize(112, 112));
    if (bytes == null) return [];
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return [];
    final counts = <int, int>{};
    for (var y = 0; y < decoded.height; y += 3) {
      for (var x = 0; x < decoded.width; x += 3) {
        final p = decoded.getPixel(x, y);
        final key = ((p.r.toInt() >> 4) << 8) |
            ((p.g.toInt() >> 4) << 4) |
            (p.b.toInt() >> 4);
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    final keys = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return keys.take(3).map((key) => Color.fromARGB(
      255,
      ((key >> 8) & 15) * 17,
      ((key >> 4) & 15) * 17,
      (key & 15) * 17,
    )).toList();
  }

  double _colorDistance(Color a, Color b) {
    final dr = a.red - b.red;
    final dg = a.green - b.green;
    final db = a.blue - b.blue;
    return math.sqrt((dr * dr + dg * dg + db * db).toDouble()) / 441.7;
  }

  double _paletteDistance(List<Color> a, List<Color> b) {
    if (a.isEmpty || b.isEmpty) return 1;
    double nearestTotal = 0;
    for (final color in a) {
      var nearest = 1.0;
      for (final candidate in b) {
        nearest = math.min(nearest, _colorDistance(color, candidate));
      }
      nearestTotal += nearest;
    }
    return nearestTotal / a.length;
  }

  String _hex(Color color) =>
      '#' + color.red.toRadixString(16).padLeft(2, '0') +
      color.green.toRadixString(16).padLeft(2, '0') +
      color.blue.toRadixString(16).padLeft(2, '0').toUpperCase();

  Future<void> _chooseReference(AssetEntity asset) async {
    if (busy) return;
    setState(() {
      reference = asset;
      referencePalette = [];
      matches = [];
      busy = true;
      scanned = 0;
    });
    try {
      final palette = await _paletteFor(asset);
      if (!mounted) return;
      setState(() => referencePalette = palette);
      final scored = <MapEntry<AssetEntity, double>>[];
      for (final photo in widget.photos) {
        if (!mounted) return;
        try {
          final candidate = await _paletteFor(photo);
          if (candidate.isNotEmpty) {
            scored.add(MapEntry(photo, _paletteDistance(palette, candidate)));
          }
        } catch (_) {
          // Ignore photos whose thumbnails cannot be read.
        }
        scanned++;
        if (scanned % 12 == 0 && mounted) {
          setState(() => matches = List.of(scored)..sort((a, b) => a.value.compareTo(b.value)));
        }
      }
      scored.sort((a, b) => a.value.compareTo(b.value));
      if (mounted) setState(() => matches = scored);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = referencePalette;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Color Palette Search'),
        actions: [
          if (reference != null)
            IconButton(
              tooltip: 'Choose another reference',
              onPressed: busy ? null : () => setState(() {
                reference = null;
                referencePalette = [];
                matches = [];
                scanned = 0;
              }),
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: widget.photos.isEmpty
          ? const Center(child: Text('No photos are available to search.'))
          : reference == null
              ? Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Choose a photo to find others with a similar color palette. Processing stays on this device.',
                        textAlign: TextAlign.center),
                    ),
                    Expanded(
                      child: GridView.builder(
                        padding: const EdgeInsets.all(8),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
                        itemCount: widget.photos.length,
                        itemBuilder: (_, index) => GestureDetector(
                          onTap: () => _chooseReference(widget.photos[index]),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Thumb(widget.photos[index]),
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    if (busy) LinearProgressIndicator(value: widget.photos.isEmpty ? null : scanned / widget.photos.length),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                      child: Row(
                        children: [
                          SizedBox(width: 76, height: 76, child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Thumb(reference!),
                          )),
                          const SizedBox(width: 12),
                          Expanded(child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(busy ? 'Comparing color palettes…' : matches.length.toString() + ' similar photos',
                                style: const TextStyle(fontWeight: FontWeight.w800)),
                              const SizedBox(height: 8),
                              Wrap(spacing: 6, runSpacing: 6, children: palette.map((color) =>
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: color,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: Theme.of(context).dividerColor),
                                  ),
                                  child: Text(_hex(color), style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: color.computeLuminance() > .45 ? Colors.black : Colors.white,
                                  )),
                                )).toList()),
                            ],
                          )),
                        ],
                      ),
                    ),
                    if (!busy && matches.isEmpty)
                      const Padding(padding: EdgeInsets.all(20), child: Text('No comparable photo palettes were found.')),
                    Expanded(
                      child: GridView.builder(
                        padding: const EdgeInsets.all(8),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
                        itemCount: matches.length,
                        itemBuilder: (_, index) {
                          final entry = matches[index];
                          return Stack(fit: StackFit.expand, children: [
                            ClipRRect(borderRadius: BorderRadius.circular(12), child: Thumb(entry.key)),
                            Positioned(left: 4, right: 4, bottom: 4, child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: .62),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(((1 - entry.value) * 100).round().toString() + '% palette match',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                            )),
                          ]);
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
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
  final List<AssetEntity> photos;
  const BlurryPhotosPage({super.key, required this.photos});
  @override State<BlurryPhotosPage> createState() => _BlurryPhotosPageState();
}
class _BlurryPhotosPageState extends State<BlurryPhotosPage> {
  bool scanning = true;
  bool cancelRequested = false;
  int scanned = 0;
  List<AssetEntity> blurry = [];

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    final out = <AssetEntity>[];
    final total = widget.photos.length;
    for (var index = 0; index < total; index++) {
      if (cancelRequested) break;
      final asset = widget.photos[index];
      try {
        final bytes = await asset.thumbnailDataWithSize(const ThumbnailSize(160, 160));
        if (bytes != null) {
          final decoded = img.decodeImage(bytes);
          if (decoded != null) {
            double totalEdge = 0, squaredEdge = 0;
            var samples = 0;
            for (var y = 1; y < decoded.height - 1; y += 2) {
              for (var x = 1; x < decoded.width - 1; x += 2) {
                final pixel = decoded.getPixel(x, y);
                final luminance = .299 * pixel.r + .587 * pixel.g + .114 * pixel.b;
                final right = decoded.getPixel(x + 1, y);
                final rightLuminance = .299 * right.r + .587 * right.g + .114 * right.b;
                final below = decoded.getPixel(x, y + 1);
                final belowLuminance = .299 * below.r + .587 * below.g + .114 * below.b;
                final edge = (luminance - rightLuminance).abs() + (luminance - belowLuminance).abs();
                totalEdge += edge;
                squaredEdge += edge * edge;
                samples++;
              }
            }
            if (samples > 0) {
              final average = totalEdge / samples;
              final variance = (squaredEdge / samples) - (average * average);
              if (average < 11.5 && variance < 70) out.add(asset);
            }
          }
        }
      } catch (_) {
        // Skip unreadable thumbnails and continue.
      }
      scanned = index + 1;
      if (mounted && (scanned % 8 == 0 || scanned == total)) {
        setState(() => blurry = List<AssetEntity>.of(out));
      }
    }
    if (!mounted) return;
    setState(() {
      blurry = List<AssetEntity>.of(out);
      scanning = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.photos.length;
    final progress = total == 0 ? 0.0 : (scanned / total).clamp(0.0, 1.0).toDouble();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Blurry Photos'),
        actions: [
          if (scanning)
            IconButton(
              tooltip: cancelRequested ? 'Stopping scan' : 'Stop scan',
              onPressed: cancelRequested ? null : () => setState(() => cancelRequested = true),
              icon: const Icon(Icons.stop_circle_outlined),
            ),
        ],
      ),
      body: scanning
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Analyzing photo sharpness on device…', textAlign: TextAlign.center),
                    const SizedBox(height: 18),
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 10),
                    Text('$scanned of $total photos checked', textAlign: TextAlign.center),
                    if (blurry.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text('${blurry.length} likely blurry so far', textAlign: TextAlign.center),
                    ],
                    if (cancelRequested) ...[
                      const SizedBox(height: 8),
                      const Text('Stopping after the current photo…', textAlign: TextAlign.center),
                    ],
                  ],
                ),
              ),
            )
          : blurry.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      total == 0
                          ? 'No photos to scan.'
                          : cancelRequested
                              ? 'Scan stopped after $scanned of $total photos. No likely blurry photos found so far.'
                              : 'No likely blurry photos found in $scanned photos.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          cancelRequested
                              ? 'Scan stopped • $scanned of $total photos checked • ${blurry.length} likely blurry'
                              : 'Scanned $scanned photos • ${blurry.length} likely blurry',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ),
                    Expanded(
                      child: GridView.builder(
                        padding: const EdgeInsets.all(10),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 6,
                          mainAxisSpacing: 6,
                        ),
                        itemCount: blurry.length,
                        itemBuilder: (_, index) => Stack(
                          fit: StackFit.expand,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: Thumb(blurry[index]),
                            ),
                            const Positioned(left: 6, top: 6, child: Chip(label: Text('Blurry'))),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
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
    Card(child: ListTile(title: const Text('Gallery grid size'), subtitle: Slider(value: grid.clamp(2,8).toDouble(), min: 2, max: 8, divisions: 6, label: grid.toString() + ' columns', onChanged: (v) => onGrid(v.round())), trailing: Text(grid.toString() + '×'))),
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
