import 'package:flutter/material.dart' show IconData;
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/node/notifier/node_editor_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../profile/data/profile_commit_test_support.dart';

/// Fault injection verifies that an unexpected D1 is never acknowledged as D0.
class InjectingNodeEditorNotifier extends NodeEditorNotifier {
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
