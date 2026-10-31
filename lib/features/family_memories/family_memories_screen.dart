import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FamilyMemoriesScreen extends StatefulWidget {
  final List<AssetEntity> photos;
  const FamilyMemoriesScreen({super.key, required this.photos});
  @override State<FamilyMemoriesScreen> createState() => _FamilyMemoriesScreenState();
}

class _FamilyMemoriesScreenState extends State<FamilyMemoriesScreen> {
  static const _storageKey = 'simple_gallery_family_milestones_v1';
  List<Map<String, String>> milestones = [];
  bool loading = true;

  @override void initState() { super.initState(); _loadMilestones(); }

  Future<void> _loadMilestones() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    final loaded = <Map<String, String>>[];
    if (raw != null) {
      try {
        for (final item in jsonDecode(raw) as List<dynamic>) {
          if (item is Map) loaded.add(item.map((k, v) => MapEntry(k.toString(), v.toString())));
        }
      } catch (_) {}
    }
    if (mounted) setState(() { milestones = loaded; loading = false; });
  }

  Future<void> _saveMilestones() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(milestones));
  }

  List<AssetEntity> get sortedPhotos => [...widget.photos]..sort((a, b) => b.createDateTime.compareTo(a.createDateTime));

  List<AssetEntity> get onThisDay {
    final now = DateTime.now();
    return sortedPhotos.where((p) => p.createDateTime.month == now.month && p.createDateTime.day == now.day && p.createDateTime.year < now.year).toList();
  }

  Map<String, List<AssetEntity>> get byMonth {
    final result = <String, List<AssetEntity>>{};
    for (final photo in sortedPhotos) {
      final date = photo.createDateTime;
      final key = '${date.year}-${date.month.toString().padLeft(2, '0')}';
      result.putIfAbsent(key, () => []).add(photo);
    }
    return result;
  }

  Future<void> _addMilestone() async {
    final title = TextEditingController();
    DateTime date = DateTime.now();
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add family milestone'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, autofocus: true, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Milestone name', hintText: 'First smile, birthday…')),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                final picked = await showDatePicker(context: context, initialDate: date, firstDate: DateTime(1900), lastDate: DateTime(2100));
                if (picked != null) setDialogState(() => date = picked);
              },
              icon: const Icon(Icons.calendar_today_outlined),
              label: Text('${date.day}/${date.month}/${date.year}'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(onPressed: () {
              final value = title.text.trim();
              if (value.isNotEmpty) Navigator.pop(dialogContext, {'title': value, 'date': date.toIso8601String()});
            }, child: const Text('Save milestone')),
          ],
        ),
      ),
    );
    title.dispose();
    if (result == null) return;
    setState(() => milestones.add(result));
    await _saveMilestones();
  }

  String _monthName(int month) => const ['January','February','March','April','May','June','July','August','September','October','November','December'][month - 1];

  @override Widget build(BuildContext context) {
    final months = byMonth.entries.toList();
    final today = onThisDay;
    return Scaffold(
      appBar: AppBar(title: const Text('Family Memories'), actions: [IconButton(onPressed: _addMilestone, tooltip: 'Add milestone', icon: const Icon(Icons.add_circle_outline_rounded))]),
      body: loading ? const Center(child: CircularProgressIndicator()) : ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(22), gradient: LinearGradient(colors: [Theme.of(context).colorScheme.primaryContainer, Theme.of(context).colorScheme.surfaceContainerHighest])),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.family_restroom_rounded, size: 30),
              const SizedBox(height: 10),
              Text('Your family story', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              const Text('A private timeline made from photos already on this device.'),
            ]),
          ),
          const SizedBox(height: 18),
          _heading('On This Day'),
          if (today.isEmpty) _empty('No earlier photos found for today’s date.')
          else SizedBox(height: 126, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: today.length, separatorBuilder: (_, __) => const SizedBox(width: 8), itemBuilder: (_, i) => _photoCard(today[i], 126))),
          const SizedBox(height: 20),
          Row(children: [Expanded(child: _heading('Family milestones')), TextButton.icon(onPressed: _addMilestone, icon: const Icon(Icons.add, size: 17), label: const Text('Add'))]),
          if (milestones.isEmpty) _empty('Add birthdays, first smiles, family trips and other moments. These entries stay on this device.')
          else ...milestones.map((item) {
            final date = DateTime.tryParse(item['date'] ?? '');
            return Card(child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.favorite_rounded)),
              title: Text(item['title'] ?? 'Milestone', style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(date == null ? 'Date unavailable' : '${date.day} ${_monthName(date.month)} ${date.year}'),
              trailing: IconButton(icon: const Icon(Icons.delete_outline_rounded), tooltip: 'Delete milestone', onPressed: () async { setState(() => milestones.remove(item)); await _saveMilestones(); }),
            ));
          }),
          const SizedBox(height: 20),
          _heading('Your photo timeline'),
          if (months.isEmpty) _empty('Photos will appear here when the gallery has access to them.')
          else ...months.map((entry) {
            final date = entry.value.first.createDateTime;
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${_monthName(date.month)} ${date.year}', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
                const SizedBox(height: 8),
                SizedBox(height: 104, child: ListView.separated(
                  scrollDirection: Axis.horizontal, itemCount: entry.value.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (_, i) => _photoCard(entry.value[i], 104),
                )),
              ]),
            );
          }),
        ],
      ),
    );
  }

  Widget _heading(String title) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)));
  Widget _empty(String message) => Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLow, borderRadius: BorderRadius.circular(16)), child: Text(message));

  Widget _photoCard(AssetEntity asset, double width) => FutureBuilder<File?>(
    future: asset.file,
    builder: (_, snapshot) => ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: snapshot.data == null
        ? Container(width: width, color: Theme.of(context).colorScheme.surfaceContainerHighest, child: const Icon(Icons.photo_outlined))
        : Image.file(snapshot.data!, width: width, height: 104, fit: BoxFit.cover, gaplessPlayback: true),
    ),
  );
}
