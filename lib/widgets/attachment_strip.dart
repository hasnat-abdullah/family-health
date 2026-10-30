import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../data/models.dart';
import '../data/storage.dart';
import '../services/file_io.dart';

/// Horizontal row of original-file thumbnails. Tap to open full screen.
class AttachmentStrip extends StatelessWidget {
  const AttachmentStrip({super.key, required this.attachments, this.onRemove});
  final List<Attachment> attachments;
  final void Function(Attachment)? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (attachments.isEmpty) {
      return Container(
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text('No original attached', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    return SizedBox(
      height: 120,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final a = attachments[i];
          return Stack(children: [
            Material(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AttachmentViewer(attachment: a))),
                child: SizedBox(
                  width: 92,
                  height: 120,
                  child: a.isPdf
                      ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(Icons.picture_as_pdf_rounded, size: 36, color: theme.colorScheme.primary),
                          const SizedBox(height: 6),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Text(a.originalName, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: theme.textTheme.labelSmall),
                          ),
                        ])
                      : _DecryptedImage(attachment: a, thumbnail: true),
                ),
              ),
            ),
            if (onRemove != null)
              Positioned(
                top: 2,
                right: 2,
                child: IconButton.filledTonal(
                  tooltip: 'Remove',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => onRemove!(a),
                ),
              ),
          ]);
        },
      ),
    );
  }
}

class AttachmentViewer extends StatelessWidget {
  const AttachmentViewer({super.key, required this.attachment});
  final Attachment attachment;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(attachment.originalName, overflow: TextOverflow.ellipsis),
        actions: [
          Builder(
            builder: (context) => IconButton(
              tooltip: 'Share / save original',
              icon: const Icon(Icons.ios_share_rounded),
              onPressed: () => FileIO.shareAttachment(context, attachment),
            ),
          ),
        ],
      ),
      body: attachment.isPdf
          ? FutureBuilder<Uint8List>(
              future: FileStore.instance.read(attachment),
              builder: (context, snap) => snap.hasData
                  ? PdfViewer.data(snap.data!, sourceName: attachment.id)
                  : snap.hasError
                  ? const Center(child: Text('This file could not be opened.'))
                  : const Center(child: CircularProgressIndicator()),
            )
          : InteractiveViewer(
              maxScale: 6,
              child: Center(child: _DecryptedImage(attachment: attachment)),
            ),
    );
  }
}

/// Decrypts a stored photo into memory and shows it.
class _DecryptedImage extends StatefulWidget {
  const _DecryptedImage({required this.attachment, this.thumbnail = false});
  final Attachment attachment;
  final bool thumbnail;

  @override
  State<_DecryptedImage> createState() => _DecryptedImageState();
}

class _DecryptedImageState extends State<_DecryptedImage> {
  late final Future<Uint8List> _bytes = FileStore.instance.read(widget.attachment);

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _bytes,
    builder: (context, snap) {
      if (snap.hasError) return const Center(child: Icon(Icons.broken_image_outlined));
      if (!snap.hasData) return const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
      return Image.memory(
        snap.data!,
        fit: widget.thumbnail ? BoxFit.cover : BoxFit.contain,
        cacheWidth: widget.thumbnail ? 300 : null,
        gaplessPlayback: true,
        semanticLabel: widget.attachment.originalName,
        errorBuilder: (_, _, _) => const Center(child: Icon(Icons.broken_image_outlined)),
      );
    },
  );
}
