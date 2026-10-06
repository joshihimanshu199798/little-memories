import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const LittleMemoriesApp());

class LittleMemoriesApp extends StatelessWidget {
  const LittleMemoriesApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Little Memories',
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFFE58A9A)),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final List<String> photos = [];
  final Set<String> favorites = {};
  String child = 'My Little Star';
  bool dark = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      photos.addAll(p.getStringList('photos') ?? []);
      favorites.addAll(p.getStringList('favorites') ?? []);
      child = p.getString('child') ?? 'My Little Star';
      dark = p.getBool('dark') ?? false;
    });
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('photos', photos);
    await p.setStringList('favorites', favorites.toList());
    await p.setString('child', child);
    await p.setBool('dark', dark);
  }

  Future<void> addPhotos() async {
    final files = await ImagePicker().pickMultiImage(imageQuality: 92);
    if (files.isEmpty) return;
    setState(() => photos.insertAll(0, files.map((e) => e.path)));
    await save();
  }

  Future<void> editChild() async {
    final c = TextEditingController(text: child);
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Child profile'),
        content: TextField(controller: c, decoration: const InputDecoration(labelText: 'Child name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              setState(() => child = c.text.trim().isEmpty ? 'My Little Star' : c.text.trim());
              save();
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void openPhoto(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Viewer(
          photos: photos,
          initial: index,
          onDelete: (path) async {
            setState(() {
              photos.remove(path);
              favorites.remove(path);
            });
            await save();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = (dark ? ThemeData.dark(useMaterial3: true) : ThemeData.light(useMaterial3: true))
        .colorScheme
        .copyWith(primary: const Color(0xFFE58A9A));
    return Theme(
      data: ThemeData(useMaterial3: true, colorScheme: scheme, brightness: dark ? Brightness.dark : Brightness.light),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Little Memories', style: TextStyle(fontWeight: FontWeight.bold)),
          actions: [
            IconButton(onPressed: editChild, icon: const Icon(Icons.person_outline)),
            IconButton(
              onPressed: () {
                setState(() => dark = !dark);
                save();
              },
              icon: Icon(dark ? Icons.light_mode : Icons.dark_mode),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: addPhotos,
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: const Text('Add photos'),
        ),
        body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Your little memories', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Text('A private place for $child ❤️'),
                    const SizedBox(height: 16),
                    Card(
                      child: ListTile(
                        leading: const CircleAvatar(radius: 28, child: Icon(Icons.child_care)),
                        title: Text(child, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text('${photos.length} photos'),
                        trailing: IconButton(onPressed: editChild, icon: const Icon(Icons.edit_outlined)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('Memories', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
            if (photos.isEmpty)
              SliverToBoxAdapter(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      children: [
                        const Icon(Icons.photo_library_outlined, size: 72),
                        const SizedBox(height: 12),
                        const Text('Your gallery is ready', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        const Text('Add your child’s first photos.', textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton.icon(onPressed: addPhotos, icon: const Icon(Icons.add), label: const Text('Add photos')),
                      ],
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                sliver: SliverGrid(
                  delegate: SliverChildBuilderDelegate((context, i) {
                    final path = photos[i];
                    final fav = favorites.contains(path);
                    return GestureDetector(
                      onTap: () => openPhoto(i),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipRRect(borderRadius: BorderRadius.circular(14), child: Image.file(File(path), fit: BoxFit.cover)),
                          Positioned(
                            top: 5,
                            right: 5,
                            child: CircleAvatar(
                              radius: 16,
                              backgroundColor: Colors.black45,
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                iconSize: 18,
                                onPressed: () {
                                  setState(() => fav ? favorites.remove(path) : favorites.add(path));
                                  save();
                                },
                                icon: Icon(fav ? Icons.favorite : Icons.favorite_border, color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }, childCount: photos.length),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 7, mainAxisSpacing: 7),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
    );
  }
}

class Viewer extends StatefulWidget {
  final List<String> photos;
  final int initial;
  final Future<void> Function(String) onDelete;
  const Viewer({super.key, required this.photos, required this.initial, required this.onDelete});
  @override
  State<Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<Viewer> {
  late final PageController controller = PageController(initialPage: widget.initial);
  late int index = widget.initial;
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text('${index + 1} / ${widget.photos.length}'),
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final path = widget.photos[index];
                await widget.onDelete(path);
                if (!mounted) return;
                if (widget.photos.isEmpty) {
                  Navigator.pop(context);
                } else {
                  setState(() => index = index.clamp(0, widget.photos.length - 1));
                }
              },
            ),
          ],
        ),
        body: PageView.builder(
          controller: controller,
          itemCount: widget.photos.length,
          onPageChanged: (i) => setState(() => index = i),
          itemBuilder: (_, i) => InteractiveViewer(
            minScale: 0.7,
            maxScale: 4,
            child: Center(child: Image.file(File(widget.photos[i]), fit: BoxFit.contain)),
          ),
        ),
      );
}
