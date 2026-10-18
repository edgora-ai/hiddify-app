import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/connection/data/connection_data_providers.dart';
import 'package:hiddify/features/connection/data/connection_repository.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/node/model/node_editor_state.dart';
import 'package:hiddify/features/proxy/node/notifier/node_editor_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../profile/data/profile_commit_test_support.dart';
import '../../proxy/node/notifier/node_editor_test_support.dart';

class _ActiveProfile extends ActiveProfile {
  _ActiveProfile(this.initial);
  final Future<ProfileEntity?> initial;

  @override
  Stream<ProfileEntity?> build() async* {
    yield await initial;
  }

  void select(ProfileEntity? profile) => state = AsyncData(profile);
}

class _GatedHaptic extends HapticService {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  bool build() => false;

  @override
  Future<void> mediumImpact() async {
    entered.complete();
    await release.future;
  }
}

class _GatedPreferences implements SharedPreferences {
  _GatedPreferences(this.delegate);
  final SharedPreferences delegate;
  final entered = Completer<void>();
  final release = Completer<void>();
  bool _blocked = false;

  @override
  Future<bool> setBool(String key, bool value) async {
    if (!_blocked && key == 'started_by_user' && value) {
      _blocked = true;
      entered.complete();
      await release.future;
    }
    return delegate.setBool(key, value);
  }

  @override
  Object? get(String key) => delegate.get(key);

  @override
  bool? getBool(String key) => delegate.getBool(key);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ConnectionRepository implements ConnectionRepository {
  ConnectionStatus initial = const Connected();
  final statuses = StreamController<ConnectionStatus>.broadcast(sync: true);
  final requests = <({String operation, String profileId})>[];
  Completer<void>? entered;
  Future<void>? release;
  Future<void> Function()? afterConnected;
  bool failReconnect = false;
  bool emitConnected = true;
  Object? requestException;
  int disconnects = 0;

  @override
  Stream<ConnectionStatus> watchConnectionStatus() async* {
    yield initial;
    yield* statuses.stream;
  }

  TaskEither<ConnectionFailure, Unit> _request(String operation, ProfileEntity profile) => TaskEither(() async {
    requests.add((operation: operation, profileId: profile.id));
    entered?.complete();
    entered = null;
    final gate = release;
    release = null;
    if (gate != null) await gate;
    if (requestException case final error?) throw error;
    if (operation == 'reconnect' && failReconnect) return left(const ConnectionFailure.invalidConfig());
    if (emitConnected) statuses.add(const Connected());
    if (afterConnected != null) await afterConnected!();
    return right(unit);
  });

  @override
  TaskEither<ConnectionFailure, Unit> connect(ProfileEntity activeProfile, bool disableMemoryLimit) =>
      _request('connect', activeProfile);

  @override
  TaskEither<ConnectionFailure, Unit> reconnect(ProfileEntity activeProfile, bool disableMemoryLimit) =>
      _request('reconnect', activeProfile);

  @override
  TaskEither<ConnectionFailure, Unit> disconnect() => TaskEither(() async {
    disconnects++;
    statuses.add(const Disconnected());
    return right(unit);
  });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProfileCommitHarness storage;
  late ProfileEntity profile;
  late _ConnectionRepository connection;
  late _ActiveProfile active;
  late ProviderContainer container;
  late SharedPreferences preferences;

  setUp(() async {
    storage = await ProfileCommitHarness.create();
    profile = await storage.seed();
    SharedPreferences.setMockInitialValues({'haptic_feedback': false});
    preferences = await SharedPreferences.getInstance();
    connection = _ConnectionRepository();
    active = _ActiveProfile(Future.value(profile));
  });

  Future<ConnectionNotifier> open({bool waitForActive = true, _GatedHaptic? haptic}) async {
    container = ProviderContainer(
      overrides: [
        profileRepositoryProvider.overrideWith((ref) => storage.repository()),
        sharedPreferencesProvider.overrideWith((ref) => preferences),
        connectionRepositoryProvider.overrideWith((ref) => connection),
        activeProfileProvider.overrideWith(() => active),
        translationsProvider.overrideWith((ref) => TranslationsEn()),
        dialogNotifierProvider.overrideWith(TestDialogs.new),
        if (haptic != null) hapticServiceProvider.overrideWith(() => haptic),
      ],
    );
    await container.read(sharedPreferencesProvider.future);
    await container.read(translationsProvider.future);
    container.listen(connectionNotifierProvider, (_, _) {});
    await container.read(connectionNotifierProvider.future);
    if (waitForActive) await container.read(activeProfileProvider.future);
    return container.read(connectionNotifierProvider.notifier);
  }

  tearDown(() async {
    container.dispose();
    await connection.statuses.close();
    await storage.dispose();
  });

  test('AsyncError retry sends a new connect request for the same saved profile', () async {
    final notifier = await open();
    connection.failReconnect = true;
    expect(await notifier.retryForProfile(profile.id), isFalse);
    expect(container.read(connectionNotifierProvider), isA<AsyncError<ConnectionStatus>>());
    expect(connection.requests, [(operation: 'reconnect', profileId: profile.id)]);
    connection.failReconnect = false;
    expect(await notifier.retryForProfile(profile.id), isTrue);
    expect(connection.requests, [
      (operation: 'reconnect', profileId: profile.id),
      (operation: 'connect', profileId: profile.id),
    ]);
  });

  test('Disconnected retry connects and Connected retry reloads without toggling off', () async {
    connection.initial = const Disconnected();
    final notifier = await open();
    final observed = Completer<void>();
    container.listen(connectionNotifierProvider, (_, next) {
      if (next.asData?.value is Connected && !observed.isCompleted) observed.complete();
    });
    connection.afterConnected = () => observed.future;
    expect(await notifier.retryForProfile(profile.id), isTrue);
    expect(await notifier.retryForProfile(profile.id), isTrue);
    expect(connection.requests, [
      (operation: 'connect', profileId: profile.id),
      (operation: 'reconnect', profileId: profile.id),
    ]);
    expect(connection.disconnects, 0);
  });

  test('mismatched active profile refuses retry without sending a request', () async {
    final notifier = await open();
    expect(await notifier.retryForProfile('another-profile'), isFalse);
    expect(connection.requests, isEmpty);
    expect(connection.disconnects, 0);
  });

  test('manual stop while retry awaits active profile wins and no reconnect is sent', () async {
    final selection = Completer<ProfileEntity?>();
    active = _ActiveProfile(selection.future);
    final notifier = await open(waitForActive: false);
    final retry = notifier.retryForProfile(profile.id);
    await notifier.abortConnection();
    selection.complete(profile);
    expect(await retry, isFalse);
    expect(connection.requests, isEmpty);
    expect(connection.disconnects, 1);
  });

  test('active profile changes during pending selection cannot redirect retry', () async {
    final selection = Completer<ProfileEntity?>();
    active = _ActiveProfile(selection.future);
    final notifier = await open(waitForActive: false);
    final retry = notifier.retryForProfile(profile.id);
    selection.complete(profile.copyWith(id: 'another-profile'));
    expect(await retry, isFalse);
    expect(connection.requests, isEmpty);
  });

  test('manual stop awaiting haptic prevents an editor retry from overtaking it', () async {
    final haptic = _GatedHaptic();
    final notifier = await open(haptic: haptic);
    final stopping = notifier.toggleConnection();
    await haptic.entered.future;
    expect(await notifier.retryForProfile(profile.id), isFalse);
    expect(connection.requests, isEmpty);
    haptic.release.complete();
    await stopping;
    expect(connection.disconnects, 1);
  });

  test('manual disconnect during preference IO cancels retry before any profile request', () async {
    final gated = _GatedPreferences(preferences);
    preferences = gated;
    final notifier = await open();
    final retry = notifier.retryForProfile(profile.id);
    await gated.entered.future;
    await notifier.toggleConnection();
    gated.release.complete();
    expect(await retry, isFalse);
    expect(connection.requests, isEmpty);
    expect(connection.disconnects, 1);
    expect(container.read(Preferences.startedByUser), isFalse);
    await gated.delegate.reload();
    expect(gated.delegate.getBool('started_by_user'), isFalse);
    expect(gated.delegate.getKeys(), contains('started_by_user'));
  });

  test('active selection is checked again after preference IO', () async {
    final gated = _GatedPreferences(preferences);
    preferences = gated;
    final notifier = await open();
    final retry = notifier.retryForProfile(profile.id);
    await gated.entered.future;
    active.select(null);
    await container.read(activeProfileProvider.future);
    gated.release.complete();
    expect(await retry, isFalse);
    expect(connection.requests, isEmpty);
  });

  test('legacy reconnect in flight prevents a second editor request', () async {
    final notifier = await open();
    final entered = Completer<void>();
    final release = Completer<void>();
    connection.entered = entered;
    connection.release = release.future;
    final legacy = notifier.reconnect(profile);
    await entered.future;
    expect(await notifier.retryForProfile(profile.id), isFalse);
    expect(connection.requests, [(operation: 'reconnect', profileId: profile.id)]);
    release.complete();
    await legacy;
  });

  test('transitioning status cannot report a successful no-op retry', () async {
    connection.initial = const Connecting();
    final notifier = await open();
    expect(await notifier.retryForProfile(profile.id), isFalse);
    expect(connection.requests, isEmpty);
  });

  test('shared SingleCall rejects a duplicate and awaits the actual first request', () async {
    final notifier = await open();
    final entered = Completer<void>();
    final release = Completer<void>();
    connection.entered = entered;
    connection.release = release.future;
    var completed = false;
    final first = notifier.retryForProfile(profile.id).then((value) {
      completed = true;
      return value;
    });
    await entered.future;
    expect(completed, isFalse);
    expect(await notifier.retryForProfile(profile.id), isFalse);
    expect(connection.requests, hasLength(1));
    release.complete();
    expect(await first, isTrue);
    expect(completed, isTrue);
  });

  test('repository throw propagates and releases retry gate', () async {
    final notifier = await open();
    final failure = StateError('synthetic repository failure');
    connection.requestException = failure;
    await expectLater(notifier.retryForProfile(profile.id), throwsA(same(failure)));
    connection.requestException = null;
    expect(await notifier.retryForProfile(profile.id), isTrue);
    expect(connection.requests, [
      (operation: 'reconnect', profileId: profile.id),
      (operation: 'reconnect', profileId: profile.id),
    ]);
  });

  test('manual stop while a retry request is in flight prevents a successful apply result', () async {
    final notifier = await open();
    final entered = Completer<void>();
    final release = Completer<void>();
    connection.entered = entered;
    connection.release = release.future;
    final retry = notifier.retryForProfile(profile.id);
    await entered.future;
    await notifier.toggleConnection();
    release.complete();
    expect(await retry, isFalse);
    expect(connection.requests, [(operation: 'reconnect', profileId: profile.id)]);
    expect(connection.disconnects, 1);
    expect(container.read(Preferences.startedByUser), isFalse);
  });

  test('switching profile during an in-flight retry cannot report applied for the old target', () async {
    final notifier = await open();
    final entered = Completer<void>();
    final release = Completer<void>();
    connection.entered = entered;
    connection.release = release.future;
    final retry = notifier.retryForProfile(profile.id);
    await entered.future;
    // Clearing selection follows the real active-profile listener's stop path.
    active.select(null);
    await container.read(activeProfileProvider.future);
    release.complete();
    expect(await retry, isFalse);
    expect(connection.requests, [(operation: 'reconnect', profileId: profile.id)]);
  });

  test('node retry refuses another target and never treats a request alone as applied', () async {
    await open();
    await container.read(profileRepositoryProvider.future);
    final provider = nodeEditorNotifierProvider(profile.id, 'A');
    container.listen(provider, (_, _) {});
    await container.read(provider.future);
    final editor = container.read(provider.notifier);
    editor.setPath(['server'], 'saved.example.invalid');
    connection.failReconnect = true;
    expect((await editor.save(TranslationsEn())).kind, NodeSaveKind.applyFailed);
    active.select(profile.copyWith(id: 'another-profile'));
    await container.read(activeProfileProvider.future);
    expect((await editor.retryApply(TranslationsEn())).kind, NodeSaveKind.applyFailed);
    expect(connection.requests, [(operation: 'reconnect', profileId: profile.id)]);

    active.select(profile);
    await container.read(activeProfileProvider.future);
    connection.failReconnect = false;
    connection.emitConnected = false;
    expect((await editor.retryApply(TranslationsEn())).kind, NodeSaveKind.applyFailed);
    expect(container.read(provider).requireValue.savePhase, NodeSavePhase.applyFailed);
    expect(connection.requests, [
      (operation: 'reconnect', profileId: profile.id),
      (operation: 'connect', profileId: profile.id),
    ]);
    final expected = originalConfig();
    ((expected['outbounds'] as List).first as Map)['server'] = 'saved.example.invalid';
    await storage.verifyStored(container.read(profileRepositoryProvider).requireValue, expected);
  });

  test('node saves D0, first apply fails, explicit retry sends same-profile connect', () async {
    await open();
    await container.read(profileRepositoryProvider.future);
    final provider = nodeEditorNotifierProvider(profile.id, 'A');
    container.listen(provider, (_, _) {});
    await container.read(provider.future);
    final editor = container.read(provider.notifier);
    editor.setPath(['server'], 'saved.example.invalid');
    connection.failReconnect = true;
    expect((await editor.save(TranslationsEn())).kind, NodeSaveKind.applyFailed);
    expect(container.read(provider).requireValue.savePhase, NodeSavePhase.applyFailed);
    final expected = originalConfig();
    ((expected['outbounds'] as List).first as Map)['server'] = 'saved.example.invalid';
    await storage.verifyStored(container.read(profileRepositoryProvider).requireValue, expected);

    final observed = Completer<void>();
    container.listen(connectionNotifierProvider, (_, next) {
      if (next.asData?.value is Connected && !observed.isCompleted) observed.complete();
    });
    connection.failReconnect = false;
    connection.afterConnected = () => observed.future;
    expect((await editor.retryApply(TranslationsEn())).kind, NodeSaveKind.applied);
    expect(connection.requests, [
      (operation: 'reconnect', profileId: profile.id),
      (operation: 'connect', profileId: profile.id),
    ]);
    await storage.verifyStored(container.read(profileRepositoryProvider).requireValue, expected);
  });
}
