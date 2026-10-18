import 'package:flutter/material.dart' show IconData;
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/details/profile_details_notifier.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/node/model/node_editor_state.dart';
import 'package:hiddify/features/proxy/node/notifier/node_editor_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../profile/data/profile_commit_test_support.dart';

/// Record the actual UI operation without replacing its implementation. Widget
/// tests must start and await File/SQLite work in the same runAsync zone.
class ObservedNodeEditorNotifier extends NodeEditorNotifier {
  Future<NodeSaveResult>? lastSave;
  Future<NodeEditorState>? lastReload;

  @override
  Future<NodeSaveResult> save(TranslationsEn t) {
    final operation = super.save(t);
    lastSave = operation;
    return operation;
  }

  @override
  void reload() {
    super.reload();
    lastReload = future;
  }
}

class ObservedProfileDetailsNotifier extends ProfileDetailsNotifier {
  Future<bool>? lastSave;

  @override
  Future<bool> save() {
    final operation = super.save();
    lastSave = operation;
    return operation;
  }
}

/// Fault injection verifies that an unexpected D1 is never acknowledged as D0.
class InjectingNodeEditorNotifier extends ObservedNodeEditorNotifier {
  void injectDraft(Map<String, dynamic> draft) {
    state = AsyncData(state.requireValue.copyWith(draft: draft));
  }
}

class NoActiveProfile extends ActiveProfile {
  @override
  Stream<ProfileEntity?> build() => Stream.value(null);
}

class TestDialogs extends DialogNotifier {
  final errors = <({String type, String? message})>[];
  int confirmations = 0;
  bool confirmDiscard = true;

  @override
  void build() {}

  @override
  Future<void> showCustomAlertFromErr(({String type, String? message}) error) async {
    errors.add(error);
  }

  @override
  Future<bool> showConfirmation({
    required String title,
    required String message,
    IconData? icon,
    String? positiveBtnTxt,
  }) async {
    confirmations++;
    return confirmDiscard;
  }
}

class TestNotifications extends InAppNotificationController {
  final successes = <String>[];

  @override
  void showSuccessToast(String message, {ToastAction? action}) {
    successes.add(message);
  }
}

ProviderContainer editorContainer(
  TestProfileRepository repository, {
  TestDialogs? dialogs,
  TestNotifications? notifications,
  List<Override> overrides = const [],
}) => ProviderContainer(
  overrides: [
    profileRepositoryProvider.overrideWith((ref) => repository),
    translationsProvider.overrideWith((ref) => TranslationsEn()),
    activeProfileProvider.overrideWith(NoActiveProfile.new),
    dialogNotifierProvider.overrideWith(() => dialogs ?? TestDialogs()),
    inAppNotificationControllerProvider.overrideWith((ref) => notifications ?? TestNotifications()),
    ...overrides,
  ],
);
