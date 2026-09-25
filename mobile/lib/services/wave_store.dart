import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/movement_wave.dart';

/// Local store of reference movement waves, keyed by exercise. One reference
/// per exercise for now (latest wins). Designed so the same records can later
/// be synced/shared via the backend (Phase 9+).
class WaveStore {
  WaveStore._();
  static final WaveStore instance = WaveStore._();

  static const String _key = 'gympath_waves_v1';

  final Map<String, MovementWave> _byExercise = {};
  SharedPreferences? _prefs;

  /// Bumped whenever a wave is saved/removed so listeners refresh.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_key);
    _byExercise.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        map.forEach((k, v) {
          _byExercise[k] = MovementWave.fromJson(v as Map<String, dynamic>);
        });
      } catch (_) {/* start fresh on corruption */}
    }
    revision.value++;
  }

  MovementWave? forExercise(String exerciseKey) =>
      _byExercise[exerciseKey.toLowerCase()];

  bool hasWave(String exerciseKey) =>
      _byExercise.containsKey(exerciseKey.toLowerCase());

  Future<void> save(MovementWave wave) async {
    _byExercise[wave.exerciseKey.toLowerCase()] = wave;
    revision.value++;
    await _persist();
  }

  Future<void> remove(String exerciseKey) async {
    _byExercise.remove(exerciseKey.toLowerCase());
    revision.value++;
    await _persist();
  }

  Future<void> _persist() async {
    _prefs ??= await SharedPreferences.getInstance();
    final map = _byExercise.map((k, v) => MapEntry(k, v.toJson()));
    await _prefs!.setString(_key, jsonEncode(map));
  }
}
