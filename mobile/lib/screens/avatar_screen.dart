import 'package:flutter/material.dart';

import '../models/avatar.dart';
import '../models/cable_exercise.dart';
import '../services/avatar_store.dart';
import '../theme/app_theme.dart';
import '../widgets/anatomy_viewer.dart';

/// Build your own figure: muscle mass, body fat, skin tone, shorts and how
/// much of the muscles shows through. The preview updates live; Save makes it
/// the figure in every 3D view.
class AvatarScreen extends StatefulWidget {
  const AvatarScreen({super.key});

  @override
  State<AvatarScreen> createState() => _AvatarScreenState();
}

class _AvatarScreenState extends State<AvatarScreen> {
  final AnatomyViewerController _viewer = AnatomyViewerController();
  late Avatar _avatar;
  late final Avatar _saved;
  bool _ready = false;
  String _view = 'front';

  static final CableExercise _pose = cableExerciseByName('Cable Bicep Curl')!;
  static const Map<String, String> _orbits = {
    'front': '0deg 86deg 3.2m',
    'side': '90deg 86deg 3.2m',
    'back': '180deg 86deg 3.2m',
  };

  @override
  void initState() {
    super.initState();
    _saved = AvatarStore.instance.avatar.value;
    _avatar = _saved;
  }

  void _set(Avatar a) {
    setState(() => _avatar = a);
    _viewer.setAvatar(a);
  }

  void _onStatus(double _, bool ready) {
    if (ready && !_ready) {
      setState(() => _ready = true);
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
    final dirty = _avatar != _saved;
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
              onPressed: () => _set(Avatar.standard),
              child: const Text('Reset',
                  style: TextStyle(color: AppTheme.textSecondary)),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(children: [
            Expanded(
              flex: 6,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Stack(children: [
                    Positioned.fill(
                      child: AnatomyViewer(
                        exercise: _pose,
                        controller: _viewer,
                        onStatus: _onStatus,
                        initialOrbit: _orbits['front'],
                        initialTarget: '0m 1.05m 0m',
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
                                _viewer.setOrbit(_orbits[v]!);
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
              ),
            ),
            Expanded(
              flex: 5,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
                children: [
                  _slider('Muscle mass', 'Slim', 'Built', _avatar.muscle,
                      (v) => _set(_avatar.copyWith(muscle: v))),
                  _slider('Body fat', 'Lean', 'Soft', _avatar.fat,
                      (v) => _set(_avatar.copyWith(fat: v))),
                  _slider('Muscles through the skin', 'Hidden', 'Visible',
                      _avatar.seeThrough,
                      (v) => _set(_avatar.copyWith(seeThrough: v))),
                  const SizedBox(height: 6),
                  _swatches('Skin tone', Avatar.skinTones, _avatar.skinTone,
                      (i) => _set(_avatar.copyWith(skinTone: i))),
                  const SizedBox(height: 14),
                  _swatches('Shorts', Avatar.shortsColors, _avatar.shorts,
                      (i) => _set(_avatar.copyWith(shorts: i))),
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

  Widget _label(String text) => Text(text.toUpperCase(),
      style: const TextStyle(
          color: AppTheme.textSecondary,
          fontSize: 11,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w700));

  Widget _slider(String label, String low, String high, double value,
      ValueChanged<double> onChanged) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label(label),
      Row(children: [
        SizedBox(
          width: 52,
          child: Text(low,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
        ),
        Expanded(
          child: Slider(
            value: value,
            onChanged: onChanged,
            activeColor: AppTheme.neonGreen,
            inactiveColor: AppTheme.cardBgLight,
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(high,
              textAlign: TextAlign.right,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
        ),
      ]),
    ]);
  }

  Widget _swatches(String label, List<AvatarSwatch> options, int selected,
      ValueChanged<int> onTap) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label('$label · ${options[selected].name}'),
      const SizedBox(height: 10),
      Wrap(spacing: 12, runSpacing: 10, children: [
        for (var i = 0; i < options.length; i++)
          GestureDetector(
            onTap: () => onTap(i),
            child: Container(
              width: 38,
              height: 38,
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
    ]);
  }
}
