import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';


enum AuthStatus { loading, signedOut, guest, signedIn }

/// Thrown when the account is blacklisted (disabled in Firebase).
class AccountDisabledException implements Exception {}

/// An error with a message that can be shown to the person as it is.
class AuthFailure implements Exception {
  final String message;
  const AuthFailure(this.message);
  @override
  String toString() => message;
}

class UserProfile {
  final String firstName;
  final String lastName;
  final String countryIso;
  final String dial;
  final String phone;
  final String email;
  final String? photoUrl;

  const UserProfile({
    required this.firstName,
    required this.lastName,
    required this.countryIso,
    required this.dial,
    required this.phone,
    required this.email,
    this.photoUrl,
  });

  bool get complete =>
      firstName.trim().isNotEmpty &&
      lastName.trim().isNotEmpty &&
      phone.trim().isNotEmpty;

  String get fullName => '$firstName $lastName'.trim();

  String get initials {
    final f = firstName.trim();
    final l = lastName.trim();
    final s = '${f.isEmpty ? '' : f[0]}${l.isEmpty ? '' : l[0]}'.toUpperCase();
    if (s.isNotEmpty) return s;
    return email.isEmpty ? '?' : email[0].toUpperCase();
  }

  String get phoneDisplay => phone.isEmpty ? '' : '+$dial $phone';

  UserProfile copyWith({
    String? firstName,
    String? lastName,
    String? countryIso,
    String? dial,
    String? phone,
    String? email,
    String? photoUrl,
  }) => UserProfile(
    firstName: firstName ?? this.firstName,
    lastName: lastName ?? this.lastName,
    countryIso: countryIso ?? this.countryIso,
    dial: dial ?? this.dial,
    phone: phone ?? this.phone,
    email: email ?? this.email,
    photoUrl: photoUrl ?? this.photoUrl,
  );

  /// What is saved in Firestore (users/{uid}) and in the local cache.
  Map<String, dynamic> toMap() => {
    'firstName': firstName,
    'lastName': lastName,
    'countryIso': countryIso,
    'phoneCode': dial,
    'phone': phone,
    'email': email,
    'photoUrl': photoUrl,
  };

  factory UserProfile.fromMap(Map<String, dynamic> m) => UserProfile(
    firstName: (m['firstName'] as String?) ?? '',
    lastName: (m['lastName'] as String?) ?? '',
    countryIso: (m['countryIso'] as String?) ?? 'LT',
    dial: (m['phoneCode'] as String?) ?? '370',
    phone: (m['phone'] as String?) ?? '',
    email: (m['email'] as String?) ?? '',
    photoUrl: m['photoUrl'] as String?,
  );
}

/// Who is using the app: a signed-in account, a guest, or nobody yet.
///
/// Works offline: a person who signed in before stays signed in without
/// internet, and the profile is kept in a local copy. Whenever there is
/// internet the account is checked, and if it was disabled (blacklisted) the
/// person is signed out and told why.
class AuthStore extends ChangeNotifier {
  static const _kGuest = 'pt_guest';
  static const _kGuestId = 'pt_guest_id';
  static const _kGuestBlocked = 'pt_guest_blocked';
  static const _kProfile = 'pt_profile';
  static const _kDirty = 'pt_profile_dirty';
  static const _kCloud = 'pt_cloud_saving';
  static const _kAutoDl = 'pt_auto_download_cloud';
  static const _kGoogleRt = 'pt_google_rt';

  final bool firebaseOk;
  AuthStore({this.firebaseOk = true});

  SharedPreferences? _prefs;
  AuthStatus _status = AuthStatus.loading;
  UserProfile? _profile;
  bool _cloudSaving = true;
  bool _autoDownload = false;
  bool _blockedNotice = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _docSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _guestSub;
  Timer? _guestTimer;
  bool _guestRegistered = false;
  bool _guestSyncing = false;

  /// The ID of this guest. It is made once, kept on this phone, and is
  /// the same every time "Continue as guest" is used, so it can be blacklisted.
  String? get guestId => _prefs?.getString(_kGuestId);

  AuthStatus get status => _status;
  UserProfile? get profile => _profile;
  bool get cloudSaving => _cloudSaving;

  /// Download the songs that are in the cloud but not on this phone when
  /// the app starts. Off by default.
  bool get autoDownloadCloud => _autoDownload;

  /// True once the person is past the login screens and in the app itself.
  bool get inApp =>
      _status == AuthStatus.guest ||
      (_status == AuthStatus.signedIn && (_profile?.complete ?? true));
  bool get isGuest => _status == AuthStatus.guest;
  bool get isSignedIn => _status == AuthStatus.signedIn;
  String? get uid => firebaseOk ? FirebaseAuth.instance.currentUser?.uid : null;

  /// True when the account signs in with an email and a password (so it has a
  /// password that can be changed).
  bool get hasPassword =>
      firebaseOk &&
      (FirebaseAuth.instance.currentUser?.providerData.any(
            (p) => p.providerId == 'password',
          ) ??
          false);

  /// Set once when an account got disabled; the login screen shows the prompt
  /// and calls [takeBlockedNotice] so it only shows once.
  bool takeBlockedNotice() {
    final b = _blockedNotice;
    _blockedNotice = false;
    return b;
  }

  bool get hasBlockedNotice => _blockedNotice;

  FirebaseAuth get _auth => FirebaseAuth.instance;
  DocumentReference<Map<String, dynamic>> _userDoc(String uid) =>
      FirebaseFirestore.instance.collection('users').doc(uid);

  // ---------------------------------------------------------------------
  // Start up
  // ---------------------------------------------------------------------

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _cloudSaving = _prefs!.getBool(_kCloud) ?? true;
    _autoDownload = _prefs!.getBool(_kAutoDl) ?? false;
    if (!firebaseOk) {
      _status = AuthStatus.signedOut;
      notifyListeners();
      return;
    }
    try {
      final user = _auth.currentUser;
      if (user != null && !user.isAnonymous) {
        _profile = _readCache(user.uid) ?? _profileFromUser(user);
        _status = AuthStatus.signedIn;
        unawaited(_verifyAccount(user));
      } else if (user != null || (_prefs!.getBool(_kGuest) ?? false)) {
        _ensureGuestId();
        await _prefs!.setBool(_kGuest, true);
        _status = AuthStatus.guest;
        _startGuestSync();
      } else {
        _status = AuthStatus.signedOut;
      }
    } catch (e) {
      debugPrint('[PalmTunes] Auth start failed -> $e');
      _status = AuthStatus.signedOut;
    }
    notifyListeners();
  }

  /// With internet: makes sure the account still exists and is not disabled.
  /// Without internet this quietly does nothing and the person stays in.
  Future<void> _verifyAccount(User user) async {
    try {
      await user.reload().timeout(const Duration(seconds: 12));
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-disabled') {
        await _block();
        return;
      }
      if (e.code == 'user-not-found' || e.code == 'user-token-expired') {
        await signOut();
        return;
      }
    } catch (_) {}
    final current = _auth.currentUser;
    if (current == null || _status != AuthStatus.signedIn) return;
    _listenToProfile(current.uid);
    unawaited(_refreshGooglePhoto());
  }

  /// A Google account's picture can change at any time: ask Google for the
  /// current one and update the profile (and Firestore) when it differs.
  Future<void> _refreshGooglePhoto() async {
    final user = _auth.currentUser;
    final p = _profile;
    if (user == null || p == null) return;
    final isGoogle = user.providerData.any((i) => i.providerId == 'google.com');
    if (!isGoogle) return;
    final photo = user.photoURL;
    if (photo == null || photo.isEmpty || photo == p.photoUrl) return;
    if (_auth.currentUser?.uid != user.uid) return;
    _setProfile(user.uid, p.copyWith(photoUrl: photo));
    unawaited(
      _userDoc(user.uid)
          .set({'photoUrl': photo}, SetOptions(merge: true))
          .catchError((_) {}),
    );
  }

  void _listenToProfile(String uid) {
    _docSub?.cancel();
    _docSub = _userDoc(uid).snapshots(includeMetadataChanges: true).listen(
      (snap) {
        final data = snap.data();
        if (data == null) {
          if (!snap.metadata.isFromCache) {
            final user = _auth.currentUser;
            if (user != null) unawaited(_createProfileDoc(user));
          }
          return;
        }
        if (data['disabled'] == true) {
          unawaited(_block());
          return;
        }
        if (_prefs?.getBool(_kDirty) ?? false) {
          if (!snap.metadata.isFromCache) unawaited(_pushDirtyProfile(uid));
          return;
        }
        _setProfile(uid, _withUserFallbacks(UserProfile.fromMap(data)));
      },
      onError: (Object e) => debugPrint('[PalmTunes] Profile listener -> $e'),
    );
  }

  Future<void> _block() async {
    _stopGuestSync();
    _docSub?.cancel();
    _docSub = null;
    try {
      await _auth.signOut();
    } catch (_) {}
    await _prefs?.remove(_kProfile);
    await _prefs?.remove(_kDirty);
    await _prefs?.remove(_kGoogleRt);
    _profile = null;
    _status = AuthStatus.signedOut;
    _blockedNotice = true;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Signing in
  // ---------------------------------------------------------------------

  Future<void> signInWithEmail(String email, String password) async {
    try {
      final cred = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      await _finishSignIn(cred.user!);
    } on AccountDisabledException {
      rethrow;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-disabled') throw AccountDisabledException();
      throw AuthFailure(_friendly(e));
    } on SocketException {
      throw const AuthFailure('No internet connection. Check it and try again.');
    }
  }

  Future<void> signInWithGoogle() async {
    try {
      final provider = GoogleAuthProvider()
        ..addScope('email')
        ..addScope('profile')
        ..setCustomParameters({'prompt': 'select_account'});
      final cred = await _auth.signInWithProvider(provider);
      final user = cred.user;
      if (user == null) throw const AuthFailure('Google sign-in failed.');
      await _finishSignIn(user);
      unawaited(_refreshGooglePhoto());
    } on AccountDisabledException {
      rethrow;
    } on AuthFailure {
      rethrow;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-disabled') throw AccountDisabledException();
      if (e.code == 'canceled' ||
          e.code == 'cancelled' ||
          e.code == 'web-context-canceled' ||
          e.code == 'web-context-cancelled' ||
          e.code == 'popup-closed-by-user' ||
          e.code == 'cancelled-popup-request') {
        throw const AuthFailure('Google sign-in was cancelled.');
      }
      throw AuthFailure(_friendly(e));
    } on SocketException {
      throw const AuthFailure('No internet connection. Check it and try again.');
    }
  }

  Future<void> signUp({
    required String firstName,
    required String lastName,
    required String countryIso,
    required String dial,
    required String phone,
    required String email,
    required String password,
  }) async {
    try {
      final cred = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final user = cred.user!;
      final profile = UserProfile(
        firstName: firstName.trim(),
        lastName: lastName.trim(),
        countryIso: countryIso,
        dial: dial,
        phone: phone,
        email: email.trim(),
      );
      try {
        await user.updateDisplayName(profile.fullName);
      } catch (_) {}
      _setProfile(user.uid, profile);
      await _writeProfile(user.uid, profile, creating: true);
      await _prefs?.remove(_kGuest);
      _stopGuestSync();
      _status = AuthStatus.signedIn;
      notifyListeners();
      _listenToProfile(user.uid);
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_friendly(e));
    } on SocketException {
      throw const AuthFailure('No internet connection. Check it and try again.');
    }
  }

  /// Runs after Firebase accepted the sign-in: checks the blacklist flag on
  /// the account and loads (or creates) the profile.
  Future<void> _finishSignIn(User user) async {
    Map<String, dynamic>? data;
    try {
      final snap = await _userDoc(user.uid)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 15));
      data = snap.data();
    } catch (e) {
      debugPrint('[PalmTunes] Could not read the profile at sign-in -> $e');
    }
    if (data?['disabled'] == true) {
      try {
        await _auth.signOut();
      } catch (_) {}
      throw AccountDisabledException();
    }
    await _prefs?.remove(_kGuest);
    _stopGuestSync();
    if (data == null) {
      await _createProfileDoc(user);
    } else {
      final profile = _withUserFallbacks(UserProfile.fromMap(data), user);
      _setProfile(user.uid, profile);
      final photo = user.photoURL;
      if (photo != null && photo != data['photoUrl']) {
        unawaited(
          _userDoc(user.uid)
              .set({'photoUrl': photo}, SetOptions(merge: true))
              .catchError((_) {}),
        );
      }
    }
    _status = AuthStatus.signedIn;
    notifyListeners();
    _listenToProfile(user.uid);
  }

  /// Continue without an account. The guest gets an ID that is made once on
  /// this phone (so it works offline) and is registered in Firebase as
  /// soon as there is internet. It is the same ID every time, so a guest that
  /// was blacklisted stays blocked.
  Future<void> continueAsGuest() async {
    if (firebaseOk) {
      final id = _ensureGuestId();
      if (_prefs?.getBool(_kGuestBlocked) ?? false) {
        // Blocked before: only let in again if Firebase says it is allowed.
        final disabled = await _guestIsDisabled(id);
        if (disabled != false) throw AccountDisabledException();
        await _prefs?.remove(_kGuestBlocked);
      }
    }
    await _prefs?.setBool(_kGuest, true);
    _status = AuthStatus.guest;
    notifyListeners();
    if (firebaseOk) _startGuestSync();
  }

  String _ensureGuestId() {
    var id = _prefs?.getString(_kGuestId);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      _prefs?.setString(_kGuestId, id);
    }
    return id;
  }

  DocumentReference<Map<String, dynamic>> _guestDoc(String id) =>
      FirebaseFirestore.instance.collection('guests').doc(id);

  Future<void> _ensureAnonymous() async {
    if (_auth.currentUser == null) {
      await _auth.signInAnonymously().timeout(const Duration(seconds: 12));
    }
  }

  /// True/false from Firebase, or null when it could not be checked.
  Future<bool?> _guestIsDisabled(String id) async {
    try {
      await _ensureAnonymous();
      final snap = await _guestDoc(id)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 12));
      return snap.data()?['disabled'] == true;
    } catch (_) {
      return null;
    }
  }

  void _startGuestSync() {
    if (!firebaseOk) return;
    _guestTimer?.cancel();
    _guestRegistered = false;
    unawaited(_syncGuest());
    // Offline at first? Try again until it works.
    _guestTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_guestRegistered) unawaited(_syncGuest());
    });
  }

  void _stopGuestSync() {
    _guestTimer?.cancel();
    _guestTimer = null;
    _guestSub?.cancel();
    _guestSub = null;
    _guestRegistered = false;
  }

  /// With internet: creates the anonymous Firebase user (once), registers this
  /// guest in the "guests" collection and watches it for a blacklist.
  Future<void> _syncGuest() async {
    if (_guestSyncing || _status != AuthStatus.guest) return;
    final id = guestId;
    if (id == null) return;
    _guestSyncing = true;
    try {
      await _ensureAnonymous();
      final ref = _guestDoc(id);
      final snap = await ref
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 15));
      final data = snap.data();
      if (data?['disabled'] == true) {
        await _blockGuest();
        return;
      }
      final info = {
        'deviceId': id,
        'anonUid': _auth.currentUser?.uid,
        'device': Platform.localHostname,
        'lastSeen': FieldValue.serverTimestamp(),
      };
      if (data == null) {
        await ref
            .set({...info, 'disabled': false, 'createdAt': FieldValue.serverTimestamp()})
            .timeout(const Duration(seconds: 15));
      } else {
        await ref.update(info).timeout(const Duration(seconds: 15));
      }
      _guestRegistered = true;
      _guestSub?.cancel();
      _guestSub = ref.snapshots().listen((s) {
        if (s.data()?['disabled'] == true) unawaited(_blockGuest());
      }, onError: (Object e) => debugPrint('[PalmTunes] Guest listener -> $e'));
    } catch (e) {
      debugPrint('[PalmTunes] Guest not registered yet (offline?) -> $e');
    } finally {
      _guestSyncing = false;
    }
  }

  Future<void> _blockGuest() async {
    _stopGuestSync();
    try {
      await _auth.signOut();
    } catch (_) {}
    await _prefs?.remove(_kGuest);
    await _prefs?.setBool(_kGuestBlocked, true);
    _status = AuthStatus.signedOut;
    _blockedNotice = true;
    notifyListeners();
  }

  Future<void> signOut() async {
    _stopGuestSync();
    _docSub?.cancel();
    _docSub = null;
    try {
      if (firebaseOk) await _auth.signOut();
    } catch (_) {}
    await _prefs?.remove(_kGuest);
    await _prefs?.remove(_kProfile);
    await _prefs?.remove(_kDirty);
    await _prefs?.remove(_kGoogleRt);
    _profile = null;
    _status = AuthStatus.signedOut;
    notifyListeners();
  }

  Future<void> sendPasswordReset(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_friendly(e));
    } on SocketException {
      throw const AuthFailure('No internet connection. Check it and try again.');
    }
  }

  // ---------------------------------------------------------------------
  // Profile
  // ---------------------------------------------------------------------

  /// Saves the profile typed in the "complete your profile" screen.
  Future<void> saveProfile(UserProfile profile) async {
    final user = _auth.currentUser;
    if (user == null) return;
    _setProfile(user.uid, profile);
    notifyListeners();
    try {
      await user.updateDisplayName(profile.fullName);
    } catch (_) {}
    await _writeProfile(user.uid, profile, creating: false);
  }

  Future<void> _createProfileDoc(User user) async {
    final seed = _readCache(user.uid) ?? _profileFromUser(user);
    _setProfile(user.uid, seed);
    await _writeProfile(user.uid, seed, creating: true);
  }

  /// Writes the profile. If that fails (no internet) it is remembered and sent
  /// the next time the profile is read from the server.
  Future<void> _writeProfile(
    String uid,
    UserProfile profile, {
    required bool creating,
  }) async {
    try {
      await _userDoc(uid)
          .set({
            ...profile.toMap(),
            if (creating) 'disabled': false,
            if (creating) 'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true))
          .timeout(const Duration(seconds: 15));
      await _prefs?.remove(_kDirty);
    } catch (e) {
      debugPrint('[PalmTunes] Profile will be saved later -> $e');
      await _prefs?.setBool(_kDirty, true);
    }
  }

  Future<void> _pushDirtyProfile(String uid) async {
    final p = _profile;
    if (p == null) return;
    await _writeProfile(uid, p, creating: false);
  }

  UserProfile _profileFromUser(User user) {
    final parts = (user.displayName ?? '').trim().split(RegExp(r'\s+'));
    final first = parts.isEmpty ? '' : parts.first;
    final last = parts.length > 1 ? parts.sublist(1).join(' ') : '';
    return UserProfile(
      firstName: first,
      lastName: last,
      countryIso: 'LT',
      dial: '370',
      phone: '',
      email: user.email ?? '',
      photoUrl: user.photoURL,
    );
  }

  UserProfile _withUserFallbacks(UserProfile p, [User? user]) {
    final u = user ?? _auth.currentUser;
    return p.copyWith(
      email: p.email.isEmpty ? (u?.email ?? '') : p.email,
      photoUrl: p.photoUrl ?? u?.photoURL,
    );
  }

  void _setProfile(String uid, UserProfile profile) {
    _profile = profile;
    _prefs?.setString(
      _kProfile,
      jsonEncode({'uid': uid, 'profile': profile.toMap()}),
    );
    notifyListeners();
  }

  UserProfile? _readCache(String uid) {
    final raw = _prefs?.getString(_kProfile);
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (m['uid'] != uid) return null;
      return UserProfile.fromMap(Map<String, dynamic>.from(m['profile'] as Map));
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // Password and settings
  // ---------------------------------------------------------------------

  Future<void> changePassword({
    required String current,
    required String next,
  }) async {
    final user = _auth.currentUser;
    final email = user?.email;
    if (user == null || email == null) {
      throw const AuthFailure('This account does not use a password.');
    }
    try {
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: email, password: current),
      );
      await user.updatePassword(next);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'wrong-password' ||
          e.code == 'invalid-credential' ||
          e.code == 'invalid-login-credentials') {
        throw const AuthFailure('The current password is incorrect.');
      }
      throw AuthFailure(_friendly(e));
    } on SocketException {
      throw const AuthFailure('No internet connection. Check it and try again.');
    }
  }

  Future<void> setCloudSaving(bool value) async {
    if (_cloudSaving == value) return;
    _cloudSaving = value;
    await _prefs?.setBool(_kCloud, value);
    notifyListeners();
  }

  Future<void> setAutoDownloadCloud(bool value) async {
    if (_autoDownload == value) return;
    _autoDownload = value;
    await _prefs?.setBool(_kAutoDl, value);
    notifyListeners();
  }

  String _friendly(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return 'That email address does not look right.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
      case 'invalid-login-credentials':
        return 'The email or password is incorrect.';
      case 'email-already-in-use':
        return 'An account with this email already exists. Try signing in.';
      case 'weak-password':
        return 'That password is too weak. Use at least 6 characters.';
      case 'network-request-failed':
        return 'No internet connection. Check it and try again.';
      case 'too-many-requests':
        return 'Too many attempts. Wait a moment and try again.';
      case 'requires-recent-login':
        return 'Please log out, log in again and then retry.';
      case 'operation-not-allowed':
        return 'This sign-in method is not turned on in Firebase yet.';
      case 'account-exists-with-different-credential':
        return 'This email is already used with another sign-in method.';
      default:
        return e.message ?? 'Something went wrong (${e.code}).';
    }
  }

  @override
  void dispose() {
    _docSub?.cancel();
    _stopGuestSync();
    super.dispose();
  }
}