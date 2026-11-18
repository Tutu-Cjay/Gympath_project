import 'package:flutter/material.dart';

import '../models/avatar.dart';
import '../models/cable_exercise.dart';
import '../services/avatar_store.dart';
import '../theme/app_theme.dart';
import '../widgets/anatomy_viewer.dart';

/// Make your avatar: body (male / female) and the head - face shape,
/// skin, eyes, brows, hair, beard and glasses. The preview updates live; Save
/// puts it on the figure in every 3D view. Saved on the phone for now.
class AvatarScreen extends StatefulWidget {
  const AvatarScreen({super.key});

  @override
  State<AvatarScreen> createState() => _AvatarScreenState();
}

class _AvatarScreenState extends State<AvatarScreen> {
  final AnatomyViewerController _viewer = AnatomyViewerController();
  late final ValueNotifier<Avatar> _draft;
  late final Avatar _saved;
  bool _ready = false;
  String _view = 'front';

  static final CableExercise _pose = cableExerciseByName('Cable Bicep Curl')!;
  static const Map<String, String> _orbits = {
    'front': '0deg 87deg 3.2m',
    'side': '65deg 87deg 3.2m',
    'back': '180deg 87deg 3.2m',
  };

  Avatar get _avatar => _draft.value;

  String get _target =>
      _avatar.sex == AvatarSex.male ? '0m 1.55m 0m' : '0m 1.41m 0m';

  @override
  void initState() {
    super.initState();
    _saved = AvatarStore.instance.avatar.value;
    _draft = ValueNotifier(_saved);
  }

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  void _set(Avatar a) {
    setState(() {
      if (a.sex != _avatar.sex) _ready = false;
    });
    _draft.value = a;
  }

  void _onStatus(double _, bool ready) {
    if (ready == _ready) return;
    setState(() => _ready = ready);
    if (ready) {
      _viewer.pause();
      _viewer.seek(0);
      _viewer.setCamera(_orbits[_view]!, _target);
      _viewer.setAvatar(_avatar);
    }
  }

  Future<void> _save() async {
    await AvatarStore.instance.save(_avatar);
    if (mounted) Navigator.pop(context);
  }

  Future<bool> _confirmDiscard() async {
    if (_avatar == _saved) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Discard changes?'),
        content: const Text('Your avatar changes are not saved yet.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep editing')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard')),
        ],
      ),
    );
    return leave == true;
  }

  @override
  Widget build(BuildContext context) {
    final a = _avatar;
    final dirty = a != _saved;
    final male = a.sex == AvatarSex.male;
    return PopScope(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        backgroundColor: AppTheme.darkBg,
        appBar: AppBar(
          title: const Text('Your avatar'),
          actions: [
            TextButton(
              onPressed: () =>
                  _set(male ? Avatar.standard : Avatar.standardFemale),
              child: const Text('Reset',
                  style: TextStyle(color: AppTheme.textSecondary)),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(children: [
            Expanded(flex: 5, child: _preview()),
            Expanded(
              flex: 6,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
                children: [
                  _chips<AvatarSex>('Body', AvatarSex.values, a.sex,
                      (s) => s == AvatarSex.male ? 'Male' : 'Female',
                      (s) => _set(a.withSex(s))),
                  _swatches('Skin', Avatar.skinTones, a.skinTone,
                      (i) => _set(a.copyWith(skinTone: i))),
                  _options('Face shape', Avatar.faceShapes, a.face,
                      (id) => _set(a.copyWith(face: id))),
                  _swatches('Eyes', Avatar.eyeColors, a.eyeColor,
                      (i) => _set(a.copyWith(eyeColor: i))),
                  _options('Brows', Avatar.browStyles, a.brows,
                      (id) => _set(a.copyWith(brows: id))),
                  _options('Hair', Avatar.hairStylesFor(a.sex), a.hair,
                      (id) => _set(a.copyWith(hair: id))),
                  _swatches('Hair colour', Avatar.hairColors, a.hairColor,
                      (i) => _set(a.copyWith(hairColor: i))),
                  if (male)
                    _options('Beard', Avatar.beardStyles, a.beard,
                        (id) => _set(a.copyWith(beard: id))),
                  _options('Glasses', Avatar.glassesStyles, a.glasses,
                      (id) => _set(a.copyWith(glasses: id))),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: dirty ? _save : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.neonGreen,
                    disabledBackgroundColor: AppTheme.cardBgLight,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(dirty ? 'Save avatar' : 'Saved'),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _preview() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Stack(children: [
          Positioned.fill(
            child: AnatomyViewer(
              exercise: _pose,
              controller: _viewer,
              onStatus: _onStatus,
              avatar: _draft,
              initialOrbit: _orbits['front'],
              initialTarget: _target,
              initialFieldOfView: '8deg',
            ),
          ),
          if (!_ready)
            const Positioned.fill(
              child: ColoredBox(
                color: AnatomyViewer.background,
                child: Center(
                  child: CircularProgressIndicator(
                      strokeWidth: 2.5, color: AppTheme.neonGreen),
                ),
              ),
            ),
          Positioned(
            left: 12,
            top: 12,
            child: Row(children: [
              for (final v in _orbits.keys)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _view = v);
                      _viewer.setCamera(_orbits[v]!, _target);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .55),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: _view == v
                                ? AppTheme.neonGreen
                                : Colors.white12),
                      ),
                      child: Text(v.toUpperCase(),
                          style: TextStyle(
                              color: _view == v
                                  ? AppTheme.neonGreen
                                  : Colors.white70,
                              fontSize: 9,
                              letterSpacing: 1,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _section(String label, Widget child) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(),
              style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 9),
          child,
        ]),
      );

  Widget _chip(String label, bool selected, VoidCallback onTap) => ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        selectedColor: AppTheme.neonGreen,
        backgroundColor: AppTheme.cardBg,
        showCheckmark: false,
        labelStyle: TextStyle(
            color: selected ? Colors.black : AppTheme.textSecondary,
            fontWeight: FontWeight.w600),
      );

  Widget _chips<T>(String label, List<T> values, T selected,
          String Function(T) name, ValueChanged<T> onTap) =>
      _section(
        label,
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final v in values) _chip(name(v), v == selected, () => onTap(v)),
        ]),
      );

  Widget _options(String label, List<AvatarOption> options, String selected,
          ValueChanged<String> onTap) =>
      _chips<AvatarOption>(
          label,
          options,
          options.firstWhere((o) => o.id == selected,
              orElse: () => options.first),
          (o) => o.name,
          (o) => onTap(o.id));

  Widget _swatches(String label, List<AvatarSwatch> options, int selected,
      ValueChanged<int> onTap) {
    return _section(
      '$label · ${options[selected].name}',
      Wrap(spacing: 12, runSpacing: 10, children: [
        for (var i = 0; i < options.length; i++)
          GestureDetector(
            onTap: () => onTap(i),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: options[i].color,
                shape: BoxShape.circle,
                border: Border.all(
                    color: i == selected ? AppTheme.neonGreen : Colors.white24,
                    width: i == selected ? 3 : 1),
              ),
              child: i == selected
                  ? const Icon(Icons.check_rounded,
                      size: 18, color: Colors.black54)
                  : null,
            ),
          ),
      ]),
    );
  }
}
