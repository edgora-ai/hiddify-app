import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/profile/details/profile_details_notifier.dart';
import 'package:hiddify/features/profile/details/profile_details_page.dart';
import 'package:hiddify/features/profile/details/profile_details_state.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _DetailsNotifier extends ProfileDetailsNotifier {
  _DetailsNotifier(this.profile, {this.loading = false});

  final ProfileEntity profile;
  final bool loading;

  @override
  Future<ProfileDetailsState> build(String id) async => ProfileDetailsState(
    loadingState: loading ? const AsyncLoading<void>() : const AsyncData<void>(null),
    profile: profile,
    configContent: '',
    isDetailsChanged: false,
  );
}

void main() {
  const id = 'synthetic-profile';
  final label = TranslationsEn().pages.profileDetails.form.preserveDomainForFallbackProxy;

  ProfileEntity profile(ProfileType type, {bool? preserveDomain}) {
    final override = UserOverride(
      name: 'Custom name',
      updateInterval: 12,
      extraSecurity: 'warp',
      preserveDomainForFallbackProxy: preserveDomain,
    );
    return type == ProfileType.remote
        ? ProfileEntity.remote(
            id: id,
            active: true,
            name: 'Synthetic remote',
            url: 'https://subscription.example.invalid/test.json',
            lastUpdate: DateTime.utc(2026),
            userOverride: override,
          )
        : ProfileEntity.local(
            id: id,
            active: true,
            name: 'Synthetic local',
            lastUpdate: DateTime.utc(2026),
            userOverride: override,
          );
  }

  Future<ProviderContainer> mount(WidgetTester tester, ProfileEntity profile, {bool loading = false}) async {
    final container = ProviderContainer(
      overrides: [
        translationsProvider.overrideWith((ref) => TranslationsEn()),
        profileDetailsNotifierProvider(id).overrideWith(() => _DetailsNotifier(profile, loading: loading)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(translationsProvider.future);
    await container.read(profileDetailsNotifierProvider(id).future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ProfileDetailsPage(id: id)),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Finder toggle() => find.ancestor(of: find.text(label), matching: find.byType(SwitchListTile));

  for (final type in ProfileType.values) {
    testWidgets('$type opt-in starts off and requires a user toggle', (tester) async {
      final original = profile(type);
      final container = await mount(tester, original);
      expect(tester.widget<SwitchListTile>(toggle()).value, isFalse);
      expect(container.read(profileDetailsNotifierProvider(id)).requireValue.isDetailsChanged, isFalse);

      await tester.ensureVisible(toggle());
      await tester.tap(toggle());
      await tester.pumpAndSettle();
      final enabled = container.read(profileDetailsNotifierProvider(id)).requireValue;
      expect(enabled.profile.userOverride, original.userOverride!.copyWith(preserveDomainForFallbackProxy: true));
      expect(enabled.isDetailsChanged, isTrue);
      expect(tester.widget<SwitchListTile>(toggle()).value, isTrue);

      await tester.tap(toggle());
      await tester.pumpAndSettle();
      final disabled = container.read(profileDetailsNotifierProvider(id)).requireValue;
      expect(disabled.profile.userOverride, original.userOverride!.copyWith(preserveDomainForFallbackProxy: false));
      expect(tester.widget<SwitchListTile>(toggle()).value, isFalse);
    });
  }

  testWidgets('a previously saved true opt-in is shown on', (tester) async {
    await mount(tester, profile(ProfileType.remote, preserveDomain: true));
    expect(tester.widget<SwitchListTile>(toggle()).value, isTrue);
  });

  testWidgets('the switch is disabled while profile changes are being saved', (tester) async {
    await mount(tester, profile(ProfileType.local), loading: true);
    expect(tester.widget<SwitchListTile>(toggle()).onChanged, isNull);
  });
}
