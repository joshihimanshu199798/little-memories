import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

class _ArchiveRecord {
  final String id, name, hash, objectFile, codec, assetId;
  final int originalSize, archiveSize;
  final DateTime createdAt;
  const _ArchiveRecord({required this.id,required this.name,required this.hash,required this.objectFile,
    required this.codec,required this.assetId,required this.originalSize,required this.archiveSize,required this.createdAt});
  factory _ArchiveRecord.fromJson(Map<String,dynamic> j)=>_ArchiveRecord(
    id:j['id'],name:j['name'],hash:j['hash'],objectFile:j['objectFile'],codec:j['codec'],
    assetId:j['assetId']??'',originalSize:j['originalSize'],archiveSize:j['archiveSize'],createdAt:DateTime.parse(j['createdAt']));
  Map<String,dynamic> toJson()=>{'id':id,'name':name,'hash':hash,'objectFile':objectFile,'codec':codec,
    'assetId':assetId,'originalSize':originalSize,'archiveSize':archiveSize,'createdAt':createdAt.toUtc().toIso8601String()};
}
/// Local encrypted vault. Source photos are never deleted or modified here.
class _PhotoShrinkVault {
  static const _secure=FlutterSecureStorage();
  static const _keyName='photoshrink_master_key_v1';
  static final _aes=AesGcm.with256bits();
  Future<Directory> _vault() async {
    final d=await getApplicationDocumentsDirectory();
    final v=Directory('${d.path}/PhotoShrinkRestore/vault'); await v.create(recursive:true); return v;
  }
  Future<Directory> _restored() async {
    final d=await getApplicationDocumentsDirectory();
    final v=Directory('${d.path}/PhotoShrinkRestore/restored'); await v.create(recursive:true); return v;
  }
  Future<List<int>> _key() async {
    final saved=await _secure.read(key:_keyName);
    if(saved!=null){final b=base64Decode(saved);if(b.length==32)return b;throw StateError('Saved archive key is invalid.');}
    final r=Random.secure(); final b=List<int>.generate(32,(_)=>r.nextInt(256));
    await _secure.write(key:_keyName,value:base64Encode(b));return b;
  }
  Future<File> _manifest() async=>File('${(await _vault()).path}/manifest.json');
  Future<List<_ArchiveRecord>> list() async {
    final f=await _manifest();if(!await f.exists())return <_ArchiveRecord>[];
    final d=jsonDecode(await f.readAsString()) as Map<String,dynamic>;
    final items=(d['items'] as List<dynamic>? ?? const <dynamic>[]).map((e)=>_ArchiveRecord.fromJson(Map<String,dynamic>.from(e as Map))).toList();
    items.sort((a,b)=>b.createdAt.compareTo(a.createdAt));return items;
  }
  Future<void> _saveManifest(List<_ArchiveRecord> items) async {
    final f=await _manifest();final tmp=File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode({'format':'PhotoShrinkRestore','version':1,'items':items.map((e)=>e.toJson()).toList()}),flush:true);
    await tmp.rename(f.path);
  }
  Future<_ArchiveRecord> archive(AssetEntity asset) async {
    final file=await asset.file;if(file==null||!await file.exists())throw StateError('Photo file is unavailable.');
    final original=await file.readAsBytes();if(original.isEmpty)throw StateError('Photo file is empty.');
    final hash=sha256.convert(original).toString();final zipped=gzip.encode(original);
    final codec=zipped.length<original.length?'gzip':'none';final payload=codec=='gzip'?zipped:original;
    final nonce=await _aes.newNonce();final box=await _aes.encrypt(payload,secretKey:SecretKey(await _key()),nonce:nonce);
    final id=List<String>.generate(32,(_)=>Random.secure().nextInt(16).toRadixString(16)).join();
    final name=_safeName(file.path.split(RegExp(r'[/\\]')).last);
    final header=utf8.encode(jsonEncode({'format':'PSR1','version':1,'id':id,'name':name,'originalSize':original.length,
      'hash':hash,'codec':codec,'nonce':base64Encode(nonce),'mac':base64Encode(box.mac.bytes),'createdAt':DateTime.now().toUtc().toIso8601String()}));
    final len=ByteData(4)..setUint32(0,header.length,Endian.big);
    final bytes=(BytesBuilder(copy:false)..add(utf8.encode('PSR1'))..add(len.buffer.asUint8List())..add(header)..add(box.cipherText)).takeBytes();
    final vault=await _vault();final objectName='${id}.psr';final object=File('${vault.path}/$objectName');final tmp=File('${object.path}.tmp');
    await tmp.writeAsBytes(bytes,flush:true);await tmp.rename(object.path);
    final verified=await _decode(await object.readAsBytes());
    if(sha256.convert(verified).toString()!=hash||verified.length!=original.length){await object.delete();throw StateError('Archive verification failed; original photo is untouched.');}
    final record=_ArchiveRecord(id:id,name:name,hash:hash,objectFile:objectName,codec:codec,assetId:asset.id,
      originalSize:original.length,archiveSize:bytes.length,createdAt:DateTime.now());
    final records=await list()..add(record);await _saveManifest(records);return record;
  }
  Future<Uint8List> _decode(Uint8List bytes) async {
    if(bytes.length<8||utf8.decode(bytes.sublist(0,4),allowMalformed:true)!='PSR1')throw const FormatException('Unknown or damaged PSR archive.');
    final n=ByteData.sublistView(bytes,4,8).getUint32(0,Endian.big);final end=8+n;
    if(n==0||end>bytes.length)throw const FormatException('Archive header is incomplete.');
    final h=Map<String,dynamic>.from(jsonDecode(utf8.decode(bytes.sublist(8,end))) as Map);
    if(h['format']!='PSR1'||h['version']!=1)throw const FormatException('Unsupported archive version.');
    final plain=await _aes.decrypt(SecretBox(bytes.sublist(end),nonce:base64Decode(h['nonce']),mac:Mac(base64Decode(h['mac']))),secretKey:SecretKey(await _key()));
    final original=Uint8List.fromList(h['codec']=='gzip'?gzip.decode(plain):plain);
    if(original.length!=h['originalSize']||sha256.convert(original).toString()!=h['hash'])throw const FormatException('Original file integrity verification failed.');
    return original;
  }
  Future<String> restore(_ArchiveRecord r) async {
    final file=File('${(await _vault()).path}/${r.objectFile}');if(!await file.exists())throw StateError('Archive object is missing.');
    final bytes=await _decode(await file.readAsBytes());if(sha256.convert(bytes).toString()!=r.hash)throw StateError('Restored hash does not match.');
    final d=await _restored();final name=_safeName(r.name);var out=File('${d.path}/$name');
    final dot=name.lastIndexOf('.');final stem=dot>0?name.substring(0,dot):name;final ext=dot>0?name.substring(dot):'';var i=1;
    while(await out.exists()){out=File('${d.path}/$stem (restored $i)$ext');i++;}
    await out.writeAsBytes(bytes,flush:true);
    if(sha256.convert(await out.readAsBytes()).toString()!=r.hash){await out.delete();throw StateError('Written restore failed verification.');}
    return out.path;
  }
  String _safeName(String name){final s=name.replaceAll(RegExp(r'[/\\\x00-\x1F]'),'_').trim();return s.isEmpty||s=='.'||s=='..'?'restored-photo':s;}
}
class PhotoShrinkRestorePage extends StatefulWidget {
  const PhotoShrinkRestorePage({super.key});
  @override State<PhotoShrinkRestorePage> createState()=>_PhotoShrinkRestorePageState();
}
class _PhotoShrinkRestorePageState extends State<PhotoShrinkRestorePage> {
  final _vault=_PhotoShrinkVault();final Set<String> _selected={};
  List<AssetEntity> _photos=[];List<_ArchiveRecord> _archives=[];bool _loading=true,_working=false;int _progress=0;String? _error;
  @override void initState(){super.initState();_load();}
  Future<void> _load() async {
    setState((){_loading=true;_error=null;});
    try{final p=await PhotoManager.requestPermissionExtend();if(!p.isAuth&&!p.hasAccess)throw StateError('Allow photo access to select photos.');
      final paths=await PhotoManager.getAssetPathList(type:RequestType.image,hasAll:true);
      final photos=paths.isEmpty?<AssetEntity>[]:await paths.first.getAssetListPaged(page:0,size:500);final archives=await _vault.list();
      if(!mounted)return;setState((){_photos=photos;_archives=archives;_loading=false;});
    }catch(e){if(mounted)setState((){_error=e.toString();_loading=false;});}
  }
  Future<void> _archiveSelected() async {
    final chosen=_photos.where((p)=>_selected.contains(p.id)).toList();if(chosen.isEmpty||_working)return;
    setState((){_working=true;_progress=0;_error=null;});var ok=0;final failures=<String>[];
    for(final p in chosen){try{await _vault.archive(p);ok++;}catch(e){failures.add('${p.title??p.id}: $e');}
      if(!mounted)return;setState(()=>_progress++);}
    final records=await _vault.list();if(!mounted)return;
    setState((){_archives=records;_selected.clear();_working=false;if(failures.isNotEmpty)_error='${failures.length} item(s) failed. ${failures.first}';});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$ok of ${chosen.length} photos archived and verified. Originals were not deleted.')));
  }
  Future<void> _restore(_ArchiveRecord r) async {
    if(_working)return;setState((){_working=true;_error=null;});
    try{final path=await _vault.restore(r);if(!mounted)return;setState(()=>_working=false);
      await Share.shareXFiles([XFile(path)],text:'Restored original photo: ${r.name}');
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Original restored and verified. Use Share to export it to your gallery or another folder.')));
    }catch(e){if(mounted)setState((){_working=false;_error='Restore failed: $e';});}
  }
  String _size(int n){if(n<1024)return '$n B';if(n<1048576)return '${(n/1024).toStringAsFixed(1)} KB';if(n<1073741824)return '${(n/1048576).toStringAsFixed(2)} MB';return '${(n/1073741824).toStringAsFixed(2)} GB';}
  @override Widget build(BuildContext context){
    final cs=Theme.of(context).colorScheme;final original=_archives.fold<int>(0,(n,r)=>n+r.originalSize);final archive=_archives.fold<int>(0,(n,r)=>n+r.archiveSize);final delta=original-archive;
    return Scaffold(appBar:AppBar(title:const Text('PhotoShrink Restore'),actions:[IconButton(tooltip:'Refresh',onPressed:_loading||_working?null:_load,icon:const Icon(Icons.refresh))]),
      body:_loading?const Center(child:CircularProgressIndicator()):RefreshIndicator(onRefresh:_load,child:ListView(padding:const EdgeInsets.all(16),children:[
        Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Row(children:[Icon(Icons.shield_outlined,size:28),SizedBox(width:10),Expanded(child:Text('Exact recovery vault',style:TextStyle(fontSize:21,fontWeight:FontWeight.w900)))]),
          const SizedBox(height:8),const Text('Encrypt and verify original photo bytes. This first version never deletes or overwrites source photos.'),
          const SizedBox(height:12),Wrap(spacing:8,runSpacing:8,children:[Chip(label:Text('${_archives.length} archived')),Chip(label:Text('${_size(original)} originals')),Chip(label:Text('${_size(archive)} archive data'))]),
          Text(delta>=0?'Potential local reduction if originals were removed: ${_size(delta)}. No originals have been removed.':'Archive overhead: ${_size(-delta)}. Lossless compression may not shrink JPEG or HEIC files.',style:TextStyle(fontSize:12,color:cs.onSurfaceVariant)),
        ]))),
        if(_error!=null)Padding(padding:const EdgeInsets.only(bottom:10),child:Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:cs.errorContainer,borderRadius:BorderRadius.circular(12)),child:Text(_error!,style:TextStyle(color:cs.onErrorContainer)))),
        const SizedBox(height:12),Row(children:[const Expanded(child:Text('Choose photos',style:TextStyle(fontSize:19,fontWeight:FontWeight.w900))),Text('${_selected.length} selected')]),
        const SizedBox(height:6),const Text('Select photos to create a private encrypted archive. Originals remain in the gallery.',style:TextStyle(fontSize:12)),const SizedBox(height:12),
        if(_photos.isEmpty)const Padding(padding:EdgeInsets.all(24),child:Center(child:Text('No accessible photos found.')))
        else GridView.builder(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),itemCount:_photos.length,gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:3,crossAxisSpacing:8,mainAxisSpacing:8),
          itemBuilder:(context,i){final p=_photos[i];final yes=_selected.contains(p.id);return GestureDetector(onTap:_working?null:()=>setState(()=>yes?_selected.remove(p.id):_selected.add(p.id)),
            child:Stack(fit:StackFit.expand,children:[ClipRRect(borderRadius:BorderRadius.circular(12),child:AssetEntityImage(p,isOriginal:false,thumbnailSize:const ThumbnailSize(240,240),fit:BoxFit.cover)),
              if(yes)Container(decoration:BoxDecoration(color:cs.primary.withValues(alpha:.22),borderRadius:BorderRadius.circular(12),border:Border.all(color:cs.primary,width:3))),
              Positioned(top:6,right:6,child:CircleAvatar(radius:13,backgroundColor:yes?cs.primary:Colors.black54,child:Icon(yes?Icons.check:Icons.add,color:Colors.white,size:17)))]));}),
        const SizedBox(height:12),FilledButton.icon(onPressed:_working||_selected.isEmpty?null:_archiveSelected,
          icon:_working?const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.lock_outline),
          label:Text(_working?'Processing $_progress…':'Archive and verify selected')),
        const SizedBox(height:26),const Text('Archived originals',style:TextStyle(fontSize:19,fontWeight:FontWeight.w900)),const SizedBox(height:8),
        if(_archives.isEmpty)const Card(child:Padding(padding:EdgeInsets.all(16),child:Text('No archives yet. Choose photos above to create your first verified archive.')))
        else ..._archives.map((r){final saved=r.originalSize-r.archiveSize;return Card(child:ListTile(leading:const CircleAvatar(child:Icon(Icons.lock_outline)),
          title:Text(r.name,maxLines:1,overflow:TextOverflow.ellipsis),subtitle:Text('${_size(r.originalSize)} original · ${_size(r.archiveSize)} archive · ${r.codec} · ${saved>=0?'${_size(saved)} smaller':'${_size(-saved)} overhead'}'),
          trailing:IconButton(tooltip:'Restore and export',onPressed:_working?null:()=>_restore(r),icon:const Icon(Icons.restore))));}),
        const SizedBox(height:16),const Text('Cloud backup and verified deletion are not enabled yet. App uninstall or device loss can remove this local archive and its key.',style:TextStyle(fontSize:12)),
      ])));
  }
}
