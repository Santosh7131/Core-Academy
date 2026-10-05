import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'api.dart';
import 'changes.dart';

/// Push notifications through Firebase: new tests and reminders for students, the daily summary
/// for the teacher. The server sends them; the app only hands it this phone's Firebase token.
/// A build made without android/app/google-services.json cannot start Firebase, and then all of
/// this does nothing.
class Push {
  static Future<bool>? _started;
  static String? _registeredFor;
  static StreamSubscription<String>? _refresh;
  static StreamSubscription<RemoteMessage>? _open;

  /// Starts Firebase without holding up the first frame.
  static void start() {
    _started ??= Firebase.initializeApp().then((_) => true, onError: (_) => false);
  }

  /// Called whenever the session changes, with the login token (null when logged out). The
  /// phone registers once per login and once per app start; the server ties it to the login,
  /// so logging out stops the notifications without anything to do here.
  static Future<void> forSession(String? loginToken) async {
    if (loginToken == null) {
      _registeredFor = null;
      return;
    }
    if (loginToken == _registeredFor || !await (_started ?? Future.value(false))) return;
    _registeredFor = loginToken;
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(); // Android 13 and later ask the user once
      final token = await messaging.getToken();
      if (token != null) await api.post('/devices', {'token': token});
      _refresh ??= messaging.onTokenRefresh.listen((t) {
        if (api.token != null) api.post('/devices', {'token': t}).ignore();
      });
      // Android shows the notification by itself only while the app is in the background. With
      // the app open the message comes here instead, and the screens load again, so a new test is
      // on the student's home screen straight away.
      _open ??= FirebaseMessaging.onMessage.listen((_) => changes.reportAreas({Area.student, Area.tests}));
    } catch (_) {
      _registeredFor = null; // offline, or no Google Play services: try again next start
    }
  }
}
