import 'dart:convert';

import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/details/profile_details_state.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'profile_details_notifier.g.dart';

@riverpod
class ProfileDetailsNotifier extends _$ProfileDetailsNotifier with AppLogger {
  ProfileRepository get _profilesRepo => ref.read(profileRepositoryProvider).requireValue;

  String? _rawContentSnapshot;
  String? _displayContentSnapshot;
  UserOverride? _originalUserOverride;

  @override
  Future<ProfileDetailsState> build(String id) async {
    final prof = (await _profilesRepo.getById(id).run()).match((l) => throw l, (prof) {
      // _originalProfile = prof;
      if (prof == null) {
        loggy.warning('profile with id: [$id] does not exist');
        throw const ProfileNotFoundFailure();
      }
      return prof;
    });
    // JSON edits own the complete raw document, not an outbounds-only projection.
    // Keep the existing generated editor for non-JSON subscriptions, but its
    // untouched display is never a replacement config on an override-only save.
    final rawContent = (await _profilesRepo.getRawConfig(id).run()).match((l) => throw l, (content) => content);
    var profContent = rawContent;
    try {
      jsonDecode(rawContent);
    } on FormatException {
      profContent = (await _profilesRepo.generateConfig(id).run()).match((failure) {
        loggy.warning('could not generate profile editor config', failure);
        return rawContent;
      }, (content) => content);
    }
    _rawContentSnapshot = rawContent;
    _displayContentSnapshot = profContent;
    _originalUserOverride = prof.userOverride;
    return ProfileDetailsState(
      loadingState: const AsyncData(null),
      profile: prof,
      configContent: profContent,
      isDetailsChanged: false,
    );
  }

  Future<T?> doAsync<T>(Future<T> Function() operation) async {
    if (state case AsyncData(value: final ProfileDetailsState data)) {
      state = AsyncData(data.copyWith(loadingState: const AsyncLoading()));
      try {
        return await operation();
      } finally {
        if (state case AsyncData(value: final current)) {
          state = AsyncData(current.copyWith(loadingState: const AsyncData(null)));
        }
      }
    }
    return null;
  }

  void setUserOverride(UserOverride userOverride) {
    if (state case AsyncData(value: final ProfileDetailsState data)) {
      if (data.isLoading) return;
      state = AsyncData(
        data.copyWith(profile: data.profile.copyWith(userOverride: userOverride), isDetailsChanged: true),
      );
    }
  }

  void setContent(String configContent) {
    if (state case AsyncData(value: final ProfileDetailsState data)) {
      if (data.isLoading) return;
      state = AsyncData(data.copyWith(configContent: configContent, isDetailsChanged: true));
    }
  }

  Future<bool> save() async {
    bool success = false;
    if (state case AsyncData(:final value)) {
      if (value.loadingState case AsyncLoading()) return false;

      success =
          await doAsync<bool>(() async {
            final t = await ref.read(translationsProvider.future);
            final contentChanged = value.configContent != _displayContentSnapshot;
            final result = await _profilesRepo
                .commitDetails(
                  value.profile,
                  expectedUserOverride: _originalUserOverride,
                  content: contentChanged ? value.configContent : null,
                  expectedRawContent: contentChanged ? _rawContentSnapshot : null,
                )
                .run();
            return result.match(
              (failure) async {
                final conflict = failure is ProfileUnexpectedFailure && failure.error is ProfileCommitConflict;
                await ref
                    .read(dialogNotifierProvider.notifier)
                    .showCustomAlertFromErr(
                      conflict
                          ? (type: t.errors.nodes.configChanged, message: null)
                          : t.presentError(
                              failure,
                              action: t.pages.profiles.msg.update.failureNamed(name: value.profile.name),
                            ),
                    );
                return false;
              },
              (_) {
                // Only the submitted values become the next comparison base.
                _originalUserOverride = value.profile.userOverride;
                if (contentChanged) {
                  _rawContentSnapshot = value.configContent;
                  _displayContentSnapshot = value.configContent;
                }
                state = AsyncData(value.copyWith(isDetailsChanged: false));
                ref.read(inAppNotificationControllerProvider).showSuccessToast(t.pages.profiles.msg.update.success);
                return true;
              },
            );
          }) ??
          false;
    }
    return success;
  }
}
