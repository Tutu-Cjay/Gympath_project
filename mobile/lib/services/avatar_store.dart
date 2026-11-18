import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/avatar.dart';

/// The user's avatar, saved on the phone. Every 3D view listens to [avatar].
class AvatarStore {
  AvatarStore._();
  static final AvatarStore instance = AvatarStore._();

  static const String _key = 'gympath_avatar_v1';

  final ValueNotifier<Avatar> avatar = ValueNotifier<Avatar>(Avatar.standard);

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        avatar.value = Avatar.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {
      // Unreadable settings: keep the standard avatar.
    }
  }

  Future<void> save(Avatar a) async {
    avatar.value = a;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(a.toJson()));
  }
}
