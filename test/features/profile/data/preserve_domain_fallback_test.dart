import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/profile/data/profile_data_mapper.dart';
import 'package:hiddify/features/profile/data/profile_data_source.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/route_rules/notifier/rules_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _optionKey = 'preserve-domain-for-fallback-proxy';
const _storageKey = 'preserveDomainForFallbackProxy';
const _subscriptionUrl = 'https://subscription.example.invalid/test.json';
const _content =
    '# profile-title: Synthetic profile\n'
    '# preserve-domain-for-fallback-proxy: true\n'
    '{"outbounds":[{"type":"socks","tag":"test-proxy","server":"192.0.2.10","server_port":1080}]}';

T _right<L, T>(Either<L, T> value) => value.match((failure) => throw TestFailure('$failure'), (result) => result);

RemoteProfileEntity _remote({
  String id = 'remote-test',
  UserOverride? userOverride,
  Map<String, dynamic> headers = const {},
}) => RemoteProfileEntity(
  id: id,
  active: true,
  name: 'Synthetic profile',
  url: _subscriptionUrl,
  lastUpdate: DateTime.utc(2026),
  populatedHeaders: headers,
  userOverride: userOverride,
);

class _EmptyRulesNotifier extends RulesNotifier {
  @override
  List<Rule> build() => [];
}

// Only supplies synthetic bytes/headers. No server, socket, or user config is used.
class _SubscriptionClient extends DioHttpClient {
  _SubscriptionClient() : super(timeout: const Duration(seconds: 1), userAgent: 'test', debug: false);

  @override
  Future<Response<dynamic>> download(
    String url,
    String path, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    bool proxyOnly = false,
  }) async {
    await File(path).writeAsString(_content);
    return Response<dynamic>(
      requestOptions: RequestOptions(path: url),
      statusCode: 200,
      headers: Headers.fromMap({
        _optionKey: ['true'],
        'profile-title': ['Synthetic profile'],
      }),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Db db;
  late ProfileDao dao;
  late Directory directory;
  late File contentFile;
  late ProviderContainer container;
  late ProfileParser parser;
  late SharedPreferences preferences;
  late SingboxConfigOption baseOptions;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'service-mode': 'vpn',
      'remote-dns-address': '192.0.2.53',
      'direct-dns-address': '192.0.2.54',
      'connection-test-url': 'http://192.0.2.20/generate_204',
    });
    preferences = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) => preferences),
        rulesNotifierProvider.overrideWith(_EmptyRulesNotifier.new),
      ],
    );
    await container.read(sharedPreferencesProvider.future);
    baseOptions = container.read(ConfigOptions.singboxConfigOptions);
    parser = container.read(
      Provider<ProfileParser>((ref) => ProfileParser(ref: ref, httpClient: _SubscriptionClient())),
    );
    directory = await Directory.systemTemp.createTemp('hiddify-fallback-proxy-test-');
    contentFile = await File('${directory.path}/synthetic-profile.json').writeAsString(_content);
    db = Db(NativeDatabase.memory());
    dao = ProfileDao(db);
  });

  tearDown(() async {
    await db.close();
    container.dispose();
    await directory.delete(recursive: true);
  });

  SingboxConfigOption typedOptions(String override, {bool fakeDNS = false}) {
    final original = baseOptions.copyWith(enableFakeDns: fakeDNS);
    final merged = ProfileParser.applyProfileOverride(original.toJson(), override);
    final typed = SingboxConfigOption.fromJson(merged);
    final repository = ConfigOptionRepository(preferences: preferences, getConfigOptions: () => original);
    expect(_right(repository.fullOptionsOverrided(override)), typed);
    return SingboxConfigOption.fromJson(jsonDecode(jsonEncode(typed.toJson())) as Map<String, dynamic>);
  }

  Future<ProfileEntity> saveAndRead(ProfileEntity original, UserOverride override) async {
    await dao.insert(original.toInsertEntry());
    final edited = original.copyWith(userOverride: override);
    final companion = _right(parser.offlineUpdate(profile: edited, tempFilePath: contentFile.path));
    expect(companion.userOverride.present, isTrue);
    await dao.edit(original.id, companion);

    // Inspect the actual existing column, not just the DAO return value.
    final raw = await db
        .customSelect(
          'SELECT user_override FROM profile_entries WHERE id = ?',
          variables: [Variable<String>(original.id)],
        )
        .getSingle();
    final stored = raw.read<String>('user_override');
    expect(UserOverride.fromStr(stored), override);
    final decoded = jsonDecode(stored) as Map<String, dynamic>;
    if (override.preserveDomainForFallbackProxy == null) {
      expect(decoded, isNot(contains(_storageKey)));
    } else {
      expect(decoded[_storageKey], override.preserveDomainForFallbackProxy);
    }
    final entry = (await dao.getById(original.id))!;
    final restored = entry.toEntity();
    expect(restored.userOverride, override);
    expect((await dao.getByName(restored.name))?.id, original.id);
    expect(ProfileParser.profileOverrideHelper(profile: entry.toCompanion(true)), restored.profileOverride());
    return restored;
  }

  group('explicit per-profile fallback proxy opt-in', () {
    test('legacy and unrelated overrides omit the new nullable storage key', () {
      for (final stored in [
        '{"version":1,"enableWarp":true}',
        '{"version":2,"name":"Existing profile"}',
        const UserOverride(name: 'Renamed profile').toStr(),
      ]) {
        final override = UserOverride.fromStr(stored)!;
        expect(override.preserveDomainForFallbackProxy, isNull);
        expect(jsonDecode(override.toStr()) as Map, isNot(contains(_storageKey)));
        expect(
          typedOptions(
            ProfileParser.profileOverride(populatedHeaders: null, userOverride: override),
          ).preserveDomainForFallbackProxy,
          isFalse,
        );
      }
      expect(UserOverride.fromStr(null), isNull);
    });

    for (final flag in [false, true]) {
      test('explicit $flag survives toStr/fromStr and copyWith', () {
        final override = UserOverride(preserveDomainForFallbackProxy: flag, name: 'Original');
        final restored = UserOverride.fromStr(override.toStr())!;
        expect(restored.preserveDomainForFallbackProxy, flag);
        expect(restored.copyWith(name: 'Renamed').preserveDomainForFallbackProxy, flag);
        expect(jsonDecode(restored.toStr()) as Map, containsPair(_storageKey, flag));
      });
    }

    test('typed options default false when JSON key is absent', () {
      expect(baseOptions.preserveDomainForFallbackProxy, isFalse);
      final legacyJSON = baseOptions.toJson()..remove(_optionKey);
      expect(SingboxConfigOption.fromJson(legacyJSON).preserveDomainForFallbackProxy, isFalse);
      expect(baseOptions.toJson()[_optionKey], isFalse);
    });

    for (final source in ['HTTP headers', 'content headers', 'base64 content headers']) {
      test('$source cannot opt in', () {
        final headers = _right(
          ProfileParser.populateHeaders(
            content: source == 'base64 content headers' ? base64Encode(utf8.encode(_content)) : _content,
            remoteHeaders: source == 'HTTP headers' ? {_optionKey: 'true'} : null,
          ),
        );
        expect(headers, isNot(contains(_optionKey)));
        final profile = _right(
          ProfileParser.parse(
            tempFilePath: contentFile.path,
            profile: _remote(headers: headers),
          ),
        );
        expect(profile.userOverride, isNull);
        expect(typedOptions(profile.profileOverride()).preserveDomainForFallbackProxy, isFalse);
      });
    }

    test('raw or legacy populated headers cannot bypass either allowlist', () {
      expect(ProfileParser.allowedProfileHeaders, isNot(contains(_optionKey)));
      expect(ProfileParser.allowedOverrideConfigs, isNot(contains(_optionKey)));
      for (final value in [true, 'true', 1, '1']) {
        for (final flag in <bool?>[null, false, true]) {
          final override = ProfileParser.profileOverride(
            populatedHeaders: {_optionKey: value, _storageKey: true, 'preserve_domain_for_fallback_proxy': true},
            userOverride: UserOverride(preserveDomainForFallbackProxy: flag),
          );
          final decoded = jsonDecode(override) as Map;
          if (flag == null) {
            expect(decoded, isNot(contains(_optionKey)));
          } else {
            expect(decoded[_optionKey], flag);
          }
          expect(typedOptions(override).preserveDomainForFallbackProxy, flag ?? false);
        }
      }
    });

    test('addLocal ignores content opt-in headers', () async {
      final companion = _right(
        await parser
            .addLocal(id: 'added-local', content: _content, tempFilePath: contentFile.path, userOverride: null)
            .run(),
      );
      expect(companion.userOverride.value, isNull);
      expect(
        typedOptions(ProfileParser.profileOverrideHelper(profile: companion)).preserveDomainForFallbackProxy,
        isFalse,
      );
    });

    test('addRemote ignores HTTP and content opt-in headers', () async {
      final companion = _right(
        await parser
            .addRemote(id: 'added-remote', url: _subscriptionUrl, tempFilePath: contentFile.path, userOverride: null)
            .run(),
      );
      expect(companion.userOverride.value, isNull);
      expect(
        typedOptions(ProfileParser.profileOverrideHelper(profile: companion)).preserveDomainForFallbackProxy,
        isFalse,
      );
    });

    for (final flag in <bool?>[null, false, true]) {
      test('updateRemote preserves explicit $flag in the actual user_override column', () async {
        final original = _remote(userOverride: UserOverride(preserveDomainForFallbackProxy: flag));
        await dao.insert(original.toInsertEntry());
        final existing = (await dao.getByUrl(_subscriptionUrl))!.toEntity() as RemoteProfileEntity;
        final companion = _right(await parser.updateRemote(rp: existing, tempFilePath: contentFile.path).run());
        await dao.edit(original.id, companion);
        final row = await db.customSelect('SELECT user_override FROM profile_entries').getSingle();
        expect(UserOverride.fromStr(row.read<String>('user_override'))!.preserveDomainForFallbackProxy, flag);
        final refreshed = (await dao.getById(original.id))!.toEntity();
        expect(refreshed.userOverride, original.userOverride);
        expect(typedOptions(refreshed.profileOverride()).preserveDomainForFallbackProxy, flag ?? false);
      });
    }

    for (final type in ProfileType.values) {
      for (final flag in <bool?>[null, false, true]) {
        test('$type offline save/read and typed JSON preserve $flag', () async {
          final profile = type == ProfileType.remote
              ? _remote(headers: {_optionKey: true})
              : ProfileEntity.local(
                  id: 'local-test',
                  active: true,
                  name: 'Synthetic local',
                  lastUpdate: DateTime.utc(2026),
                  populatedHeaders: {_optionKey: true},
                );
          final restored = await saveAndRead(profile, UserOverride(preserveDomainForFallbackProxy: flag));
          for (final fakeDNS in [false, true]) {
            final options = typedOptions(restored.profileOverride(), fakeDNS: fakeDNS);
            expect(options.preserveDomainForFallbackProxy, flag ?? false);
            expect(options.enableFakeDns, fakeDNS);
            expect(options.toJson()[_optionKey], flag ?? false);
          }
        });
      }
    }
  });

  test(
    'saved profile -> typed Dart JSON -> real Go BuildConfig',
    () async {
      final cases = <Map<String, dynamic>>[];
      for (final type in ProfileType.values) {
        for (final flag in <bool?>[null, false, true]) {
          final id = '${type.name}-$flag';
          final profile = type == ProfileType.remote
              ? _remote(id: id, headers: {_optionKey: true})
              : ProfileEntity.local(
                  id: id,
                  active: true,
                  name: 'Synthetic $id',
                  lastUpdate: DateTime.utc(2026),
                  populatedHeaders: {_optionKey: true},
                );
          final restored = await saveAndRead(
            profile,
            UserOverride(name: 'Synthetic $id', preserveDomainForFallbackProxy: flag),
          );
          for (final fakeDNS in [false, true]) {
            final options = typedOptions(restored.profileOverride(), fakeDNS: fakeDNS);
            cases.add({'name': '$id/fake-$fakeDNS', 'options': options.toJson(), 'want': flag == true && !fakeDNS});
          }
        }
      }
      final file = await File('${directory.path}/typed-options.json').writeAsString(jsonEncode(cases));
      // Match libbox's existing production binary-wide linkname exception.
      // This bridge does not exercise the private OOM profiler ABI.
      final result = await Process.run(
        'go',
        [
          'test',
          '-tags=',
          '-mod=readonly',
          '-ldflags=-checklinkname=0',
          '-timeout=120s',
          '-p=2',
          '-parallel=2',
          './v2/config',
          '-run',
          '^TestPreserveDomainForFallbackProxyAppRoundTrip\$',
          '-count=1',
          '-v',
        ],
        workingDirectory: '${Directory.current.path}/hiddify-core',
        environment: {'HIDDIFY_TEST_FALLBACK_PROXY_OPTIONS': file.path},
      );
      // Keep the builder's per-case evidence visible in the Flutter test log.
      // ignore: avoid_print
      print(result.stdout);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    skip: !const bool.fromEnvironment('HIDDIFY_TEST_GO_BUILDER'),
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
