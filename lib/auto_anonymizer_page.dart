import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:little_memories/auto_anonymizer_utils.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

/// A preview-first, on-device face masking flow.
///
/// The source asset is never edited or deleted. Export actions always create a
/// separate copy, and nothing is saved or shared until the user taps a button.
class AutoAnonymizerPage extends StatefulWidget {
  final AssetEntity asset;
  final Future<void> Function()? onSaved;

  const AutoAnonymizerPage({
    super.key,
    required this.asset,
    this.onSaved,
  });

  @override
  State<AutoAnonymizerPage> createState() => _AutoAnonymizerPageState();
}

class _AutoAnonymizerPageState extends State<AutoAnonymizerPage> {
  Uint8List? _maskedBytes;
  int _faceCount = 0;
  bool _processing = true;
  bool _busy = false;
  bool _noFaces = false;
  String? _error;
  String _outputExtension = 'jpg';

  @override
  void initState() {
    super.initState();
    _preparePreview();
  }

  Future<void> _preparePreview() async {
    if (mounted) {
      setState(() {
        _processing = true;
        _maskedBytes = null;
        _faceCount = 0;
        _noFaces = false;
        _error = null;
      });
    }

    try {
      final file = await widget.asset.file;
      if (file == null || !await file.exists()) {
        throw StateError('The original photo is not available as a local file.');
      }

      // Avoid decoding exceptionally large files into several in-memory copies.
      if (await file.length() > 40 * 1024 * 1024) {
        throw StateError('This photo is larger than the 40 MB safety limit.');
      }

      final detector = FaceDetector(
        options: FaceDetectorOptions(
          performanceMode: FaceDetectorMode.accurate,
          enableLandmarks: false,
          enableContours: false,
          enableClassification: false,
          enableTracking: false,
          minFaceSize: 0.08,
        ),
      );

      late final List<Face> faces;
      try {
        faces = await detector.processImage(InputImage.fromFilePath(file.path));
      } finally {
        await detector.close();
      }

      if (faces.isEmpty) {
        if (!mounted) return;
        setState(() {
          _noFaces = true;
          _processing = false;
        });
        return;
      }

      final sourceBytes = await file.readAsBytes();
      final decoded = img.decodeImage(sourceBytes);
      if (decoded == null) {
        throw FormatException('The photo format could not be decoded.');
      }

      // Normalize EXIF rotation before applying the detector's image-space boxes.
      final upright = img.bakeOrientation(decoded);
      applyFacePrivacyMasks(
        upright,
        faces.map((face) => face.boundingBox).toList(),
      );

      final originalExtension = file.path.split('.').last.toLowerCase();
      final saveAsPng = originalExtension == 'png';
      final encoded = saveAsPng
          ? img.encodePng(upright)
          : img.encodeJpg(upright, quality: 95);

      if (!mounted) return;
      setState(() {
        _maskedBytes = Uint8List.fromList(encoded);
        _faceCount = faces.length;
        _outputExtension = saveAsPng ? 'png' : 'jpg';
        _processing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error =
            'The photo could not be processed on this device. The original is unchanged. Try a locally available JPEG or PNG photo.';
        _processing = false;
      });
    }
  }

  Future<AssetEntity> _saveMaskedCopy() async {
    final bytes = _maskedBytes;
    if (bytes == null || _faceCount == 0) {
      throw StateError('There is no verified masked preview to export.');
    }

    final stamp = DateTime.now().millisecondsSinceEpoch;
    final saved = await PhotoManager.editor.saveImage(
      bytes,
      filename: 'LittleMemories_FaceMasked_$stamp.$_outputExtension',
      title: 'Face-masked copy',
      relativePath: 'Pictures/Little Memories',
    );
    if (saved == null) {
      throw StateError('The phone gallery did not confirm the save.');
    }

    final onSaved = widget.onSaved;
    if (onSaved != null) {
      try {
        await onSaved();
      } catch (_) {
        // A refresh failure must not misreport a successful gallery save.
      }
    }
    return saved;
  }

  Future<void> _saveCopy() async {
    if (_busy || _maskedBytes == null || _faceCount == 0) return;
    setState(() => _busy = true);
    try {
      await _saveMaskedCopy();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Face-masked copy saved. The original photo is unchanged.'),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save the masked copy. The original is unchanged.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAndShareCopy() async {
    if (_busy || _maskedBytes == null || _faceCount == 0) return;
    setState(() => _busy = true);
    AssetEntity? saved;
    try {
      saved = await _saveMaskedCopy();
      final file = await saved.file;
      if (file == null || !await file.exists()) {
        throw StateError('The saved copy could not be opened for sharing.');
      }
      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'Face-masked copy created on this device with Little Memories.',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A separate face-masked copy was saved.')),
        );
      }
    } catch (_) {
      if (mounted) {
        final message = saved == null
            ? 'Could not save the masked copy. The original is unchanged.'
            : 'The masked copy was saved, but sharing did not complete.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final canExport = !_processing &&
        !_busy &&
        _maskedBytes != null &&
        _faceCount > 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Auto-Anonymizer'),
        actions: [
          IconButton(
            tooltip: 'Scan again',
            onPressed: _processing || _busy ? null : _preparePreview,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _processing
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 14),
                  Text('Detecting faces on this device…'),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(
                          canExport
                              ? Icons.privacy_tip_rounded
                              : Icons.info_outline_rounded,
                          size: 30,
                          color: canExport ? colors.primary : colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                canExport
                                    ? '$_faceCount ${_faceCount == 1 ? 'face' : 'faces'} detected'
                                    : 'Preview unavailable',
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w800,
                                    ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                canExport
                                    ? 'Black masks cover detected face regions.'
                                    : 'No file will be exported unless a face-masked preview is ready.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    height: 360,
                    width: double.infinity,
                    color: colors.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: _maskedBytes == null
                        ? Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _error == null
                                      ? Icons.face_retouching_off_rounded
                                      : Icons.warning_amber_rounded,
                                  size: 48,
                                  color: colors.onSurfaceVariant,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  _error ??
                                      (_noFaces
                                          ? 'No faces were detected. Nothing was saved or shared. Try another photo; detection can miss faces.'
                                          : 'A masked preview could not be created.'),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          )
                        : Image.memory(
                            _maskedBytes!,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(color: colors.error),
                  ),
                Text(
                  'Review the masked preview carefully. Face detection can miss faces or mask them imperfectly. The original photo is never overwritten or deleted.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: canExport ? _saveCopy : null,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_alt_rounded),
                  label: const Text('Save masked copy'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: canExport ? _saveAndShareCopy : null,
                  icon: const Icon(Icons.ios_share_rounded),
                  label: const Text('Save and share masked copy'),
                ),
              ],
            ),
    );
  }
}
