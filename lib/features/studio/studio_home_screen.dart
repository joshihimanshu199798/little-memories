import 'dart:io';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import '../family_memories/family_memories_screen.dart';
import 'film_lab/film_lab_screen.dart';

class StudioHomeScreen extends StatelessWidget {
  final List<AssetEntity> photos;
  final Future<void> Function(AssetEntity) onEditPhoto;
  const StudioHomeScreen({super.key, required this.photos, required this.onEditPhoto});

  Future<void> _pickPhoto(BuildContext context) async {
    if (photos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No accessible photos were found.')));
      return;
    }
    final selected = await showModalBottomSheet<AssetEntity>(
      context: context, isScrollControlled: true, showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * .78,
          child: Column(children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 4, 18, 12),
              child: Align(alignment: Alignment.centerLeft, child: Text('Choose a photo to edit', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900))),
            ),
            Expanded(child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 5, mainAxisSpacing: 5),
              itemCount: photos.length,
              itemBuilder: (_, index) {
                final asset = photos[index];
                return FutureBuilder<File?>(
                  future: asset.file,
                  builder: (_, snapshot) {
                    final file = snapshot.data;
                    return InkWell(
                      onTap: file == null ? null : () => Navigator.pop(sheetContext, asset),
                      child: file == null
                        ? const ColoredBox(color: Color(0x22111111), child: Center(child: Icon(Icons.photo_outlined)))
                        : Image.file(file, fit: BoxFit.cover, gaplessPlayback: true),
                    );
                  },
                );
              },
            )),
          ]),
        ),
      ),
    );
    if (selected != null && context.mounted) await onEditPhoto(selected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recent = photos.take(12).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Studio', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 3),
            Text('Create, restore and relive your photos', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ])),
          CircleAvatar(backgroundColor: theme.colorScheme.primaryContainer, child: Icon(Icons.auto_awesome_rounded, color: theme.colorScheme.onPrimaryContainer)),
        ]),
        const SizedBox(height: 18),
        _sectionTitle(context, 'Quick actions'),
        Row(children: [
          Expanded(child: _featuredAction(context, icon: Icons.tune_rounded, title: 'Edit photo', subtitle: 'Open the existing editor', onTap: () => _pickPhoto(context))),
          const SizedBox(width: 10),
          Expanded(child: _featuredAction(context, icon: Icons.camera_roll_outlined, title: 'Film Lab', subtitle: 'Analog-inspired looks', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FilmLabScreen(photos: photos))))),
        ]),
        const SizedBox(height: 10),
        _featuredAction(
          context, icon: Icons.family_restroom_rounded, title: 'Family Memories',
          subtitle: 'Timeline, On This Day and personal milestones', horizontal: true,
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FamilyMemoriesScreen(photos: photos))),
        ),
        const SizedBox(height: 22),
        _sectionTitle(context, 'Creative tools'),
        _toolGrid(context, const [
          _Tool('Compression Studio', Icons.compress_rounded),
          _Tool('Collage Studio', Icons.grid_view_rounded),
          _Tool('Batch Editor', Icons.layers_rounded),
          _Tool('AI Studio', Icons.auto_awesome_rounded),
          _Tool('Selective Editing', Icons.brush_rounded),
          _Tool('Portrait Retouch', Icons.face_retouching_natural),
          _Tool('RAW Editor', Icons.raw_on_rounded),
          _Tool('Color Lab', Icons.palette_outlined),
        ]),
        const SizedBox(height: 22),
        _sectionTitle(context, 'Recent photos'),
        if (recent.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Text('Your recent photos will appear here when the gallery has access to them.'))
        else
          SizedBox(height: 94, child: ListView.separated(
            scrollDirection: Axis.horizontal, itemCount: recent.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, index) => FutureBuilder<File?>(
              future: recent[index].file,
              builder: (_, snapshot) => ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: snapshot.data == null
                  ? Container(width: 94, color: theme.colorScheme.surfaceContainerHighest)
                  : Image.file(snapshot.data!, width: 94, height: 94, fit: BoxFit.cover),
              ),
            ),
          )),
        const SizedBox(height: 12),
        Text('Modules not yet implemented are shown as planned tools, not active features. Their functionality will be added in later development phases.', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
  );

  Widget _featuredAction(BuildContext context, {
    required IconData icon, required String title, required String subtitle,
    required VoidCallback onTap, bool horizontal = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final iconBox = Container(width: 42, height: 42, decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(13)), child: Icon(icon, color: cs.onPrimaryContainer));
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900)),
      const SizedBox(height: 3),
      Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
    ]);
    return Material(
      color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18), onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: horizontal ? Row(children: [iconBox, const SizedBox(width: 12), Expanded(child: text), const Icon(Icons.chevron_right_rounded)])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [iconBox, const SizedBox(height: 12), text]),
        ),
      ),
    );
  }

  Widget _toolGrid(BuildContext context, List<_Tool> tools) => GridView.builder(
    shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), itemCount: tools.length,
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 9, mainAxisSpacing: 9, childAspectRatio: 1.72),
    itemBuilder: (_, index) {
      final tool = tools[index];
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLow, borderRadius: BorderRadius.circular(16), border: Border.all(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: .45))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(tool.icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 7),
          Text(tool.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
          Text('Planned module', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
      );
    },
  );
}

class _Tool {
  final String title;
  final IconData icon;
  const _Tool(this.title, this.icon);
}
