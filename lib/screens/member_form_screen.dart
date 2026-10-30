import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/database.dart';
import '../data/models.dart';
import '../data/storage.dart';
import '../services/file_io.dart';
import '../services/image_tools.dart';
import '../theme.dart';
import '../widgets/common.dart';

class MemberFormScreen extends StatefulWidget {
  const MemberFormScreen({super.key, this.member});
  final Member? member;

  @override
  State<MemberFormScreen> createState() => _MemberFormScreenState();
}

class _MemberFormScreenState extends State<MemberFormScreen> {
  static const _relations = ['Self', 'Spouse', 'Son', 'Daughter', 'Father', 'Mother', 'Brother', 'Sister', 'Other'];
  static const _bloodGroups = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];

  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.member?.name);
  late final _notes = TextEditingController(text: widget.member?.notes);
  late String? _relation = widget.member?.relation;
  late DateTime? _birthDate = widget.member?.birthDate;
  late String? _sex = widget.member?.sex;
  late String? _bloodGroup = widget.member?.bloodGroup;
  late int? _color = widget.member?.colorValue;

  /// A newly chosen picture, written to the store only on save.
  Uint8List? _newPhoto;
  bool _removePhoto = false;

  @override
  void initState() {
    super.initState();
    if (_color == null) {
      // Next unused colour, in palette order.
      AppDb.instance.members().then((all) {
        final used = all.map((m) => m.colorValue).toSet();
        final next = memberColors.firstWhere((c) => !used.contains(c.toARGB32()), orElse: () => memberColors[all.length % memberColors.length]);
        if (mounted && _color == null) setState(() => _color = next.toARGB32());
      });
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final m = widget.member ?? Member(name: '', colorValue: 0);
    m
      ..name = _name.text.trim()
      ..relation = _relation
      ..birthDate = _birthDate
      ..sex = _sex
      ..bloodGroup = _bloodGroup
      ..colorValue = _color ?? memberColors.first.toARGB32()
      ..notes = _notes.text.trim().isEmpty ? null : _notes.text.trim();
    final oldPhoto = m.photoFile;
    if (_newPhoto != null) {
      m.photoFile = '${newId()}.jpg';
      await FileStore.instance.writePlain(m.photoFile!, _newPhoto!);
    } else if (_removePhoto) {
      m.photoFile = null;
    }
    await AppDb.instance.saveMember(m);
    if (oldPhoto != null && oldPhoto != m.photoFile) await FileStore.instance.delete(oldPhoto);
    if (mounted) Navigator.pop(context);
  }

  bool get _hasPhoto => _newPhoto != null || (widget.member?.photoFile != null && !_removePhoto);

  Future<void> _changePhoto() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (isMobile) ListTile(leading: const Icon(Icons.photo_camera_rounded), title: const Text('Take a photo'), onTap: () => Navigator.pop(context, 'camera')),
          ListTile(leading: const Icon(Icons.photo_library_rounded), title: const Text('Choose a picture'), onTap: () => Navigator.pop(context, 'pick')),
          if (_hasPhoto) ListTile(leading: const Icon(Icons.delete_outline_rounded), title: const Text('Remove picture'), onTap: () => Navigator.pop(context, 'remove')),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (choice == null) return;
    if (choice == 'remove') {
      setState(() {
        _newPhoto = null;
        _removePhoto = true;
      });
      return;
    }
    final picked = choice == 'camera' ? await FileIO.takePhoto() : await FileIO.pickImage();
    if (picked == null) return;
    try {
      final jpeg = await ImageTools.toJpeg(await picked.file.readAsBytes(), maxSide: 512);
      if (mounted) setState(() => _newPhoto = jpeg);
    } catch (_) {
      if (mounted) showMessage(context, "That picture couldn't be opened. Try a JPG or PNG.");
    } finally {
      await FileIO.discardPlainCopies([picked]);
    }
  }

  Future<void> _pickBirthDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(1990),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
      initialEntryMode: DatePickerEntryMode.calendarOnly,
    );
    if (d != null) setState(() => _birthDate = d);
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 16);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.member == null ? 'New member' : 'Edit profile'),
        actions: [
          Padding(padding: const EdgeInsets.only(right: 12), child: FilledButton(onPressed: _save, child: const Text('Save'))),
        ],
      ),
      body: ContentWidth(
        maxWidth: 560,
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: Semantics(
                  button: true,
                  label: 'Change profile picture',
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _changePhoto,
                    child: Stack(children: [
                      MemberAvatar(
                        Member(
                          name: _name.text.trim().isEmpty ? '?' : _name.text,
                          colorValue: _color ?? memberColors.first.toARGB32(),
                          photoFile: _removePhoto ? null : widget.member?.photoFile,
                        ),
                        radius: 48,
                        preview: _newPhoto,
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: CircleAvatar(
                          radius: 16,
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          child: Icon(Icons.photo_camera_rounded, size: 18, color: Theme.of(context).colorScheme.onPrimary),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
              gap,
              TextFormField(
                controller: _name,
                autofocus: widget.member == null,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name'),
                onChanged: (_) => setState(() {}),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Please enter a name' : null,
              ),
              gap,
              DropdownButtonFormField<String>(
                initialValue: _relations.contains(_relation) ? _relation : null,
                decoration: const InputDecoration(labelText: 'Relation'),
                items: [for (final r in _relations) DropdownMenuItem(value: r, child: Text(r))],
                onChanged: (v) => setState(() => _relation = v),
              ),
              gap,
              InkWell(
                onTap: _pickBirthDate,
                borderRadius: BorderRadius.circular(4),
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Date of birth',
                    suffixIcon: _birthDate == null
                        ? const Icon(Icons.calendar_today_rounded)
                        : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() => _birthDate = null)),
                  ),
                  child: Text(_birthDate == null ? 'Not set' : dateFmt.format(_birthDate!)),
                ),
              ),
              gap,
              Text('Sex (used for default reference ranges)', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              SegmentedButton<String?>(
                segments: const [
                  ButtonSegment(value: 'F', label: Text('Female')),
                  ButtonSegment(value: 'M', label: Text('Male')),
                  ButtonSegment(value: null, label: Text('Not set')),
                ],
                selected: {_sex},
                onSelectionChanged: (s) => setState(() => _sex = s.first),
              ),
              gap,
              DropdownButtonFormField<String>(
                initialValue: _bloodGroup,
                decoration: const InputDecoration(labelText: 'Blood group'),
                items: [for (final b in _bloodGroups) DropdownMenuItem(value: b, child: Text(b))],
                onChanged: (v) => setState(() => _bloodGroup = v),
              ),
              gap,
              Text('Colour', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final c in memberColors)
                    Semantics(
                      button: true,
                      selected: _color == c.toARGB32(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => setState(() => _color = c.toARGB32()),
                        child: CircleAvatar(
                          radius: 20,
                          backgroundColor: c,
                          child: _color == c.toARGB32() ? const Icon(Icons.check, color: Colors.white) : null,
                        ),
                      ),
                    ),
                ],
              ),
              gap,
              TextFormField(
                controller: _notes,
                maxLines: 4,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  hintText: 'Allergies, conditions, regular medicines…',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
