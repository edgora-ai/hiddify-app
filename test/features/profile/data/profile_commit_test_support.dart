import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/features/profile/data/profile_data_mapper.dart';
import 'package:hiddify/features/profile/data/profile_data_source.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/profile/data/profile_path_resolver.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';

T requireRight<L, T>(Either<L, T> value) => value.match((failure) => throw TestFailure('$failure'), (value) => value);

/// An early Left/throw must fail at the missing checkpoint, not hang waiting for
/// validation that the operation can no longer reach. The caller still awaits
/// the operation after releasing its gate, so later errors are not discarded.
Future<void> waitForCheckpoint<T>(
  Future<void> checkpoint,
  Future<T> operation, {
  required String description,
  String Function(T result)? describeResult,
}) => Future.any<void>([
  checkpoint,
  operation.then<void>((result) {
    throw TestFailure(
      '$description was not reached; operation completed with ${describeResult?.call(result) ?? result}',
    );
  }),
]);

Future<void> releaseAndSettle(Completer<void> release, Iterable<Future<Object?>> operations) async {
  if (!release.isCompleted) release.complete();
  await Future.wait<Object?>(operations);
}

const testProfileId = 'isolated-profile';
const testOverride = UserOverride(name: 'User profile', extraSecurity: 'warp', enableFragment: true);

Map<String, dynamic> originalNode() => <String, dynamic>{
  'type': 'trojan',
  'tag': 'A',
  'server': 'a.example.invalid',
  'server_port': 443,
  'password': 'original-password',
  'tls': <String, dynamic>{
    'enabled': true,
    'server_name': 'tls.example.invalid',
    'future_tls_option': <dynamic>['untouched'],
  },
  'future_node_option': <String, dynamic>{
    'nested': <dynamic>[
      'one',
      <String, dynamic>{'two': 2},
    ],
  },
};

Map<String, dynamic> addedNode() => <String, dynamic>{
  'type': 'trojan',
  'tag': 'B',
  'server': 'b.example.invalid',
  'server_port': 8443,
  'password': 'new-password',
  'future_added_option': <String, dynamic>{'preserved': true},
};

Map<String, dynamic> originalConfig() => <String, dynamic>{
  'outbounds': <dynamic>[
    originalNode(),
    <String, dynamic>{
      'type': 'selector',
      'tag': 'select',
      'outbounds': <dynamic>['A'],
      'future_group_option': true,
    },
    <String, dynamic>{'type': 'direct', 'tag': 'direct', 'future_direct_option': 7},
  ],
  'endpoints': <dynamic>[
    <String, dynamic>{'type': 'wireguard', 'tag': 'endpoint', 'future_endpoint_option': 'kept'},
  ],
  'dns': <String, dynamic>{
    'servers': <dynamic>[
      <String, dynamic>{'tag': 'dns', 'address': '192.0.2.53'},
    ],
  },
  'route': <String, dynamic>{
    'final': 'select',
    'future_route_option': <dynamic>['keep'],
  },
  'experimental': <String, dynamic>{
    'future_option': <String, dynamic>{'retained': true},
  },
  'future_root_option': <dynamic>[1, 2, 3],
};

/// No core process or network: the real repository, parser metadata, files and
/// Drift DAO run against owned synthetic storage; only core validation is replaced.
class ProfileCommitHarness {
  ProfileCommitHarness._(this.root, this.db, this.dao, this.paths, this.parser);

  final Directory root;
  final Db db;
  final ProfileDao dao;
  final ProfilePathResolver paths;
  final TestProfileParser parser;

  static Future<ProfileCommitHarness> create() async {
    final root = await Directory.systemTemp.createTemp('hiddify-profile-commit-');
    final paths = ProfilePathResolver(root);
    await paths.directory.create();
    final db = Db(NativeDatabase.memory());
    return ProfileCommitHarness._(root, db, ProfileDao(db), paths, TestProfileParser());
  }

  TestProfileRepository repository() => TestProfileRepository(this);

  Future<ProfileEntity> seed({String id = testProfileId, bool remote = false}) async {
    final ProfileEntity profile = remote
        ? ProfileEntity.remote(
            id: id,
            active: false,
            name: 'User profile',
            url: 'https://subscription.example.invalid/profile.json',
            lastUpdate: DateTime.utc(2026),
            userOverride: testOverride,
            pinned: true,
          )
        : ProfileEntity.local(
            id: id,
            active: false,
            name: 'User profile',
            lastUpdate: DateTime.utc(2026),
            userOverride: testOverride,
            pinned: true,
          );
    await paths.file(id).writeAsString(jsonEncode(originalConfig()));
    await dao.insert(profile.toInsertEntry());
    return profile;
  }

  Future<void> verifyStored(
    ProfileRepository repository,
    Map<String, dynamic> expected, {
    String id = testProfileId,
    UserOverride userOverride = testOverride,
  }) async {
    // Write -> inspect actual file/SQL -> repository readback -> search both
    // the persisted entity and the complete raw node object.
    final bytes = await paths.file(id).readAsString();
    expect(jsonDecode(bytes), expected);
    final row = await db
        .customSelect(
          'SELECT name, user_override, pinned FROM profile_entries WHERE id = ?',
          variables: [Variable<String>(id)],
        )
        .getSingle();
    expect(UserOverride.fromStr(row.read<String>('user_override')), userOverride);
    expect(row.read<bool>('pinned'), isTrue);
    final entity = requireRight(await repository.getById(id).run())!;
    expect(entity.userOverride, userOverride);
    expect((await dao.getByName(entity.name))?.id, id);
    expect(requireRight(await repository.getRawConfig(id).run()), bytes);
    final config = jsonDecode(bytes) as Map<String, dynamic>;
    final nodes = (config['outbounds'] as List).whereType<Map<String, dynamic>>();
    expect(nodes.singleWhere((node) => node['tag'] == 'A'), (expected['outbounds'] as List).first);
  }

  Future<void> dispose() async {
    await db.close();
    await root.delete(recursive: true);
  }
}

class TestProfileParser implements ProfileParser {
  String remoteContent = jsonEncode(originalConfig());
  int remoteUpdates = 0;

  @override
  Either<ProfileFailure, ProfileEntriesCompanion> offlineUpdate({
    required ProfileEntity profile,
    required String tempFilePath,
  }) => ProfileParser.parse(profile: profile, tempFilePath: tempFilePath).map((entity) => entity.toUpdateEntry());

  @override
  TaskEither<ProfileFailure, ProfileEntriesCompanion> updateRemote({
    required RemoteProfileEntity rp,
    required String tempFilePath,
    CancelToken? cancelToken,
  }) => TaskEither(() async {
    remoteUpdates++;
    await File(tempFilePath).writeAsString(remoteContent);
    return offlineUpdate(profile: rp, tempFilePath: tempFilePath);
  });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedCore implements HiddifyCoreService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedOptions implements ConfigOptionRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestProfileRepository extends ProfileRepositoryImpl {
  TestProfileRepository(this.harness)
    : super(
        profileDataSource: harness.dao,
        profilePathResolver: harness.paths,
        singbox: _UnusedCore(),
        configOptionRepository: _UnusedOptions(),
        profileParser: harness.parser,
      );

  final ProfileCommitHarness harness;
  Future<void> Function()? beforeValidation;
  Completer<void>? configCommitRequested;
  Completer<void>? detailsCommitRequested;
  bool rejectValidation = false;
  String? generatedContent;
  final validationInputs = <String>[];

  @override
  TaskEither<ProfileFailure, String> generateConfig(String id) {
    final content = generatedContent;
    return content == null ? super.generateConfig(id) : TaskEither.right(content);
  }

  @override
  TaskEither<ProfileFailure, Unit> commitConfig(String id, String content, {required String expectedRawContent}) {
    configCommitRequested?.complete();
    configCommitRequested = null;
    return super.commitConfig(id, content, expectedRawContent: expectedRawContent);
  }

  @override
  TaskEither<ProfileFailure, Unit> commitDetails(
    ProfileEntity profile, {
    required UserOverride? expectedUserOverride,
    String? content,
    String? expectedRawContent,
  }) {
    detailsCommitRequested?.complete();
    detailsCommitRequested = null;
    return super.commitDetails(
      profile,
      expectedUserOverride: expectedUserOverride,
      content: content,
      expectedRawContent: expectedRawContent,
    );
  }

  @override
  TaskEither<ProfileFailure, Unit> validateConfig(String path, String tempPath, String? profileOverride, bool debug) =>
      TaskEither(() async {
        validationInputs.add(tempPath);
        final wait = beforeValidation;
        beforeValidation = null;
        if (wait != null) await wait();
        if (rejectValidation) return left(const ProfileFailure.invalidConfig());
        await File(path).writeAsString(await File(tempPath).readAsString());
        return right(unit);
      });
}
