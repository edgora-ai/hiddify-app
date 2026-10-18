import 'dart:io';

import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/connection/data/connection_data_providers.dart';
import 'package:hiddify/features/connection/data/connection_repository.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/model/startup_connection.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/hiddifycore/init_signal.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

part 'connection_notifier.g.dart';

@Riverpod(keepAlive: true)
class ConnectionNotifier extends _$ConnectionNotifier with AppLogger {
  @override
  Stream<ConnectionStatus> build() async* {
    if (Platform.isIOS) {
      await _connectionRepo.setup().mapLeft((l) {
        loggy.error("error setting up connection repository", l);
      }).run();
    }

    listenSelf((previous, next) async {
      if (next.asData?.value is! Connecting) _connectingBoundaryRevision++;
      if (previous == next) return;
      if (previous case AsyncData(:final value) when !value.isConnected) {
        if (next case AsyncData(value: final Connected _)) {
          if (Platform.isAndroid && !ref.read(Preferences.storeReviewedByUser)) {
            if (await InAppReview.instance.isAvailable()) {
              InAppReview.instance.requestReview();
              ref.read(Preferences.storeReviewedByUser.notifier).update(true);
            }
          }
        }
      }
    });

    ref.listen(activeProfileProvider.select((value) => value.asData?.value), (previous, next) async {
      _observedActiveProfileId = next?.id;
      if (previous == null) return;
      final shouldReconnect = next == null || previous.id != next.id;
      if (shouldReconnect) {
        await reconnect(next);
      }
    }, fireImmediately: true);
    ref.watch(coreRestartSignalProvider);

    yield* _connectionRepo.watchConnectionStatus().doOnData((event) {
      if (event case Disconnected(connectionFailure: final _?) when PlatformUtils.isDesktop) {
        Future.microtask(() => ref.read(Preferences.startedByUser.notifier).update(false));
      }
      // One call for every status buried failures at info, next to the ordinary
      // comings and goings. A failure carries the core's own panic text, which
      // is the last thing that should need hunting for.
      final status = "connection status: ${event.format()}";
      if (event case Disconnected(connectionFailure: final _?)) {
        loggy.error(status);
      } else {
        loggy.info(status);
      }
    });
  }

  ConnectionRepository get _connectionRepo => ref.read(connectionRepositoryProvider);

  Future<void> mayConnect() async {
    if (state case AsyncData(:final value)) {
      if (value case Disconnected()) return _connect();
    }
  }

  /// Restores the tunnel on desktop start when the user had it running before quitting,
  /// so a session started manually survives a reboot or an autostart login.
  Future<void> restoreConnectionOnStartup() async {
    final startedByUser = ref.read(Preferences.startedByUser);
    final activeProfile = await ref.read(activeProfileProvider.future);
    final shouldRestore = shouldRestoreConnectionOnStartup(
      isDesktop: PlatformUtils.isDesktop,
      startedByUser: startedByUser,
      hasActiveProfile: activeProfile != null,
    );
    if (!shouldRestore) {
      loggy.debug("no previous connection to restore");
      return;
    }
    loggy.info("restoring previous connection on startup");
    await ref.read(Preferences.startedByUser.notifier).update(true);
    await _connect();
  }

  // Invalidates a pending profile-bound action when the user changes intent.
  int _connectionIntentRevision = 0;
  int _connectingBoundaryRevision = 0;
  int _pendingUnboundOperations = 0;
  bool _startedByUserIntent = false;
  String? _observedActiveProfileId;
  ({String profileId, int revision})? _pendingRetryStart;

  Future<void> _withConnectionIntent(Future<void> Function() operation) async {
    _connectionIntentRevision++;
    _pendingUnboundOperations++;
    try {
      await operation();
    } finally {
      _pendingUnboundOperations--;
    }
  }

  Future<void> toggleConnection() async {
    final pendingStart = _pendingRetryStart;
    if (pendingStart != null &&
        pendingStart.revision == _connectionIntentRevision &&
        (pendingStart.profileId == _observedActiveProfileId ||
            (_observedActiveProfileId == null && ref.read(activeProfileProvider).isLoading)) &&
        (state is AsyncError<ConnectionStatus> || state.asData?.value is Disconnected)) {
      // The gate already accepted this same Start. A duplicate must not cancel
      // it by changing intent before its own _connect would be ignored.
      loggy.debug('same-profile Start already accepted, ignoring duplicate');
      return;
    }
    await _withConnectionIntent(() async {
      final haptic = ref.read(hapticServiceProvider.notifier);
      if (state case AsyncError()) {
        _startedByUserIntent = true;
        await haptic.lightImpact();
        await _connect();
      } else if (state case AsyncData(:final value)) {
        switch (value) {
          case Disconnected():
            _startedByUserIntent = true;
            await haptic.lightImpact();
            await ref.read(Preferences.startedByUser.notifier).update(true);
            await _connect();
          case Connected():
            _startedByUserIntent = false;
            // default:
            await haptic.mediumImpact();
            await ref.read(Preferences.startedByUser.notifier).update(false);
            await _disconnect();
          default:
            loggy.warning("switching status, debounce");
        }
      }
    });
  }

  Future<void> reconnect(ProfileEntity? profile) => _withConnectionIntent(() async {
    if (state case AsyncData(:final value) when value == const Connected()) {
      _startedByUserIntent = profile != null;
      if (profile == null) {
        loggy.info("no active profile, disconnecting");
        return _disconnect();
      }
      loggy.info("active profile changed, reconnecting");
      await ref.read(Preferences.startedByUser.notifier).update(true);
      await _connectionRepo.reconnect(profile, ref.read(Preferences.disableMemoryLimit)).mapLeft((err) async {
        loggy.warning("error reconnecting", err);
        state = AsyncError(err, StackTrace.current);
        await ref
            .read(dialogNotifierProvider.notifier)
            .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
      }).run();
    }
  });

  /// Explicit editor apply/retry, bound to one saved profile. True means that
  /// this operation sent a successful repository request, not network reachability.
  Future<bool> retryForProfile(String expectedProfileId) {
    final intentRevision = _connectionIntentRevision;
    return _singleStart.run<bool>(() async {
      if (_pendingUnboundOperations != 0) return false;
      // A duplicate Start can arrive during the first active-profile read too.
      if (state is AsyncError<ConnectionStatus> || state.asData?.value is Disconnected) {
        _pendingRetryStart = (profileId: expectedProfileId, revision: intentRevision);
      }
      try {
        await ref.read(activeProfileProvider.future);
        if (intentRevision != _connectionIntentRevision || _pendingUnboundOperations != 0) return false;
        var active = ref.read(activeProfileProvider).asData?.value;
        if (active?.id != expectedProfileId) return false;
        final initial = state;
        final canStart = initial is AsyncError<ConnectionStatus> || initial.asData?.value is Disconnected;
        final canReload = initial.asData?.value is Connected;
        if (!canStart && !canReload) return false;

        _pendingRetryStart = canStart ? (profileId: expectedProfileId, revision: intentRevision) : null;
        // Preferences also performs async IO. A selection change, manual stop or
        // status transition during that wait must win over this pending retry.
        final startedByUser = ref.read(Preferences.startedByUser.notifier);
        _startedByUserIntent = true;
        await startedByUser.update(true);
        // A late preference write must not reinstate Start after a manual Stop.
        // Reconcile only this flag to the latest explicit intent, never replay a
        // connection request. Further user actions during IO still take priority.
        var preferenceRevision = intentRevision;
        while (preferenceRevision != _connectionIntentRevision) {
          preferenceRevision = _connectionIntentRevision;
          await startedByUser.update(_startedByUserIntent);
        }
        if (intentRevision != _connectionIntentRevision || _pendingUnboundOperations != 0 || state != initial) {
          return false;
        }
        active = ref.read(activeProfileProvider).asData?.value;
        if (active == null || active.id != expectedProfileId) return false;

        final dialogs = ref.read(dialogNotifierProvider.notifier);
        final t = ref.read(translationsProvider).requireValue;
        final disableMemoryLimit = ref.read(Preferences.disableMemoryLimit);
        // The core can republish Connecting for this Start. Any intervening
        // non-Connecting state ends ownership, even if Connecting follows it.
        final starting = canStart ? AsyncData<ConnectionStatus>(const Connecting()) : null;
        if (starting != null) state = starting;
        final ownedStarting = canStart ? _connectingBoundaryRevision : null;
        try {
          // Do not call another public SingleCall entry while holding this gate.
          final result =
              await (canStart
                      ? _connectionRepo.connect(active, disableMemoryLimit)
                      : _connectionRepo.reconnect(active, disableMemoryLimit))
                  .run();
          // The active-profile listener increments this revision too. Avoid ref
          // reads after core IO: a failed start can invalidate this notifier.
          if (intentRevision != _connectionIntentRevision) return false;
          return result.match((error) async {
            state = AsyncError(error, StackTrace.current);
            await dialogs.showCustomAlertFromErr(error.present(t));
            return false;
          }, (_) async => true);
        } catch (error, stackTrace) {
          if (ownedStarting != null &&
              intentRevision == _connectionIntentRevision &&
              _observedActiveProfileId == expectedProfileId &&
              state.asData?.value is Connecting &&
              _connectingBoundaryRevision == ownedStarting) {
            state = AsyncError(error, stackTrace);
          }
          rethrow;
        }
      } finally {
        _pendingRetryStart = null;
      }
    }, onIgnored: () => false);
  }

  Future<void> abortConnection() => _withConnectionIntent(() async {
    if (state case AsyncData(:final value)) {
      switch (value) {
        case Connected() || Connecting():
          _startedByUserIntent = false;
          loggy.debug("aborting connection");
          await _disconnect();
        default:
      }
    }
  });

  final _singleStart = SingleCall();

  Future<void> _connect() async {
    await _singleStart.run<void>(
      () async {
        await _connectThrottled();
      },
      onIgnored: () {
        loggy.debug("connect called while another connect/disconnect is still running, ignoring");
      },
    );
  }

  Future<void> _connectThrottled() async {
    final activeProfile = await ref.read(activeProfileProvider.future);
    if (activeProfile == null) {
      loggy.info("no active profile, not connecting");
      return;
    }
    // Read before connecting: a failed start sends the core restart signal, which marks this
    // notifier out of date until the next frame, and debug builds refuse any ref call until then.
    final dialogs = ref.read(dialogNotifierProvider.notifier);
    final t = ref.read(translationsProvider).requireValue;
    final startedByUser = ref.read(Preferences.startedByUser.notifier);
    // The core reports Starting only once the config is built, about a second
    // later; the app is connecting from here on.
    state = const AsyncData(Connecting());
    await _connectionRepo.connect(activeProfile, ref.read(Preferences.disableMemoryLimit)).mapLeft((
      ConnectionFailure err,
    ) async {
      loggy.warning("error connecting", err);
      // Before the dialog: a status the core sends while it is open, such as a
      // late Started, must win over this error, not be overwritten by it.
      state = AsyncError(err, StackTrace.current);
      //Go err is not normal object to see the go errors are string and need to be dumped
      await dialogs.showCustomAlertFromErr(err.present(t));
      loggy.warning(err);
      if (err.toString().contains("panic")) {
        await Sentry.captureException(Exception(err.toString()));
      }
      await startedByUser.update(false);
    }).run();
  }

  Future<void> _disconnect() async {
    await _connectionRepo.disconnect().mapLeft((err) {
      loggy.warning("error disconnecting", err);
      ref
          .read(dialogNotifierProvider.notifier)
          .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
      state = AsyncError(err, StackTrace.current);
    }).run();
  }
}

@Riverpod(keepAlive: true)
bool serviceRunning(Ref ref) {
  // ref.watch(coreRestartSignalProvider);
  return ref.watch(connectionNotifierProvider).valueOrNull?.isConnected ?? false;
}

class SingleCall {
  bool _running = false;

  Future<T> run<T>(Future<T> Function() task, {required T Function() onIgnored}) async {
    if (_running) return onIgnored();

    _running = true;
    try {
      return await task();
    } finally {
      _running = false;
    }
  }
}

/// Whether the core is hot reloading; only the connection button shows it.
final hotReloadingProvider = StreamProvider<bool>((ref) => ref.watch(connectionRepositoryProvider).watchHotReloading());
