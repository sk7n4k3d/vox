import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ce qui ne rentre pas dans [AppSettings] : le secret de signature (stocké en
/// secure storage, comme le code PIN) et la liste des rooms Matrix autorisées
/// (une liste, que l'enum AppSettings ne sait pas porter).
class WebhookStore {
  WebhookStore._();
  static final WebhookStore instance = WebhookStore._();

  static const String _secretKey = 'chat.fluffy.webhook_secret';
  static const String _roomsKey = 'chat.fluffy.webhook_rooms';

  Future<String> loadSecret() async {
    try {
      return await const FlutterSecureStorage().read(key: _secretKey) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> saveSecret(String secret) async {
    try {
      if (secret.isEmpty) {
        await const FlutterSecureStorage().delete(key: _secretKey);
      } else {
        await const FlutterSecureStorage().write(key: _secretKey, value: secret);
      }
    } catch (_) {}
  }

  Future<Set<String>> loadRooms() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList(_roomsKey) ?? const <String>[]).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> saveRooms(Set<String> rooms) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_roomsKey, rooms.toList());
    } catch (_) {}
  }
}
