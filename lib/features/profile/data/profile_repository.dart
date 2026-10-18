import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/db/db.dart';

import 'package:hiddify/core/utils/exception_handler.dart';
import 'package:hiddify/features/profile/data/profile_data_mapper.dart';
import 'package:hiddify/features/profile/data/profile_data_source.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/profile/data/profile_path_resolver.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/profile/model/profile_sort_enum.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:uuid/uuid.dart';

abstract interface class ProfileRepository {
  TaskEither<ProfileFailure, Unit> init();
  TaskEither<ProfileFailure, ProfileEntity?> getById(String id);
  TaskEither<ProfileFailure, Unit> setAsActive(String id);
  TaskEither<ProfileFailure, Unit> setPinned(String id, bool pinned);
  TaskEither<ProfileFailure, Unit> deleteById(String id, bool isActive);
  Stream<Either<ProfileFailure, ProfileEntity?>> watchActiveProfile();
  Stream<Either<ProfileFailure, bool>> watchHasAnyProfile();
  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchAll({
    ProfilesSort sort = ProfilesSort.lastUpdate,
    SortMode sortMode = SortMode.ascending,
  });
  TaskEither<ProfileFailure, Unit> upsertRemote(String url, {UserOverride? userOverride, CancelToken? cancelToken});
  TaskEither<ProfileFailure, Unit> addLocal(String content, {UserOverride? userOverride});
  TaskEither<ProfileFailure, Unit> offlineUpdate(ProfileEntity nProfile, String nContent);
  TaskEither<ProfileFailure, Unit> validateConfig(String path, String tempPath, String? profileOverride, bool debug);
  TaskEither<ProfileFailure, String> generateConfig(String id);
  TaskEither<ProfileFailure, String> getRawConfig(String id);
}

/// An editor must keep its original comparison credentials until explicit reload.
/// This marker contains no config or credentials and is presented by the caller.
class ProfileCommitConflict implements Exception {
  const ProfileCommitConflict();
}

/// Optional checked-write capability; the existing repository API stays intact.
abstract interface class ProfileCommitWriter {
  TaskEither<ProfileFailure, Unit> commitConfig(String id, String content, {required String expectedRawContent});
  TaskEither<ProfileFailure, Unit> commitDetails(
    ProfileEntity profile, {
    required UserOverride? expectedUserOverride,
    String? content,
    String? expectedRawContent,
  });
}

extension ProfileRepositoryCommits on ProfileRepository {
  TaskEither<ProfileFailure, Unit> commitConfig(String id, String content, {required String expectedRawContent}) {
    final repository = this;
    if (repository is ProfileCommitWriter) {
      // Extension calls are statically resolved; invoke the capability member.
      final writer = repository as ProfileCommitWriter;
      return writer.commitConfig(id, content, expectedRawContent: expectedRawContent);
    }
    return TaskEither.left(ProfileFailure.unexpected(UnsupportedError('Checked profile writes are unavailable')));
  }

  TaskEither<ProfileFailure, Unit> commitDetails(
    ProfileEntity profile, {
    required UserOverride? expectedUserOverride,
    String? content,
    String? expectedRawContent,
  }) {
    final repository = this;
    if (repository is ProfileCommitWriter) {
      final writer = repository as ProfileCommitWriter;
      return writer.commitDetails(
        profile,
        expectedUserOverride: expectedUserOverride,
        content: content,
        expectedRawContent: expectedRawContent,
      );
    }
    return TaskEither.left(ProfileFailure.unexpected(UnsupportedError('Checked profile writes are unavailable')));
  }
}

/// Shared by repository instances targeting the same file, not just node editors.
/// The queue owns the *running* async operation, including validation and DB edit.
/// This coordinates cooperating App writers in this isolate, not external processes.
class _ProfileCommits {
  static final _tails = <String, Future<void>>{};

  static Future<T> run<T>(String key, Future<T> Function() operation) async {
    final previous = _tails[key];
    final release = Completer<void>();
    _tails[key] = release.future;
    if (previous != null) await previous;
    try {
      return await operation();
    } finally {
      release.complete();
      if (identical(_tails[key], release.future)) _tails.remove(key);
    }
  }
}

class ProfileRepositoryImpl with ExceptionHandler, InfraLogger implements ProfileRepository, ProfileCommitWriter {
  ProfileRepositoryImpl({
    required ProfileDataSource profileDataSource,
    required ProfilePathResolver profilePathResolver,
    required HiddifyCoreService singbox,
    required ConfigOptionRepository configOptionRepository,
    required ProfileParser profileParser,
  }) : _profileParser = profileParser,
       _configOptionRepo = configOptionRepository,
       _singbox = singbox,
       _profilePathResolver = profilePathResolver,
       _profileDataSource = profileDataSource;

  final ProfileDataSource _profileDataSource;
  final ProfilePathResolver _profilePathResolver;
  final HiddifyCoreService _singbox;
  final ConfigOptionRepository _configOptionRepo;
  final ProfileParser _profileParser;

  TaskEither<ProfileFailure, Unit> _write(String id, Future<Either<ProfileFailure, Unit>> Function() operation) =>
      TaskEither(
        () => _ProfileCommits.run(_profilePathResolver.file(id).absolute.path, () async {
          try {
            return await operation();
          } catch (error, stackTrace) {
            return left(error is ProfileFailure ? error : ProfileFailure.unexpected(error, stackTrace));
          }
        }),
      );

  @override
  TaskEither<ProfileFailure, Unit> init() {
    return exceptionHandler(() async {
      if (!kIsWeb) {
        if (!await _profilePathResolver.directory.exists()) {
          await _profilePathResolver.directory.create(recursive: true);
        }
      }

      return right(unit);
    }, ProfileUnexpectedFailure.new);
  }

  @override
  TaskEither<ProfileFailure, ProfileEntity?> getById(String id) {
    return TaskEither.tryCatch(
      () => _profileDataSource.getById(id).then((value) => value?.toEntity()),
      ProfileUnexpectedFailure.new,
    );
  }

  @override
  TaskEither<ProfileFailure, Unit> setAsActive(String id) {
    return _write(id, () async {
      await _profileDataSource.edit(id, const ProfileEntriesCompanion(active: Value(true)));
      return right(unit);
    });
  }

  @override
  TaskEither<ProfileFailure, Unit> setPinned(String id, bool pinned) {
    return _write(id, () async {
      await _profileDataSource.edit(id, ProfileEntriesCompanion(pinned: Value(pinned)));
      return right(unit);
    });
  }

  @override
  TaskEither<ProfileFailure, Unit> deleteById(String id, bool isActive) {
    return _write(id, () async {
      await _profileDataSource.deleteById(id, isActive);
      await _profilePathResolver.file(id).delete();
      return right(unit);
    });
  }

  @override
  Stream<Either<ProfileFailure, ProfileEntity?>> watchActiveProfile() {
    return _profileDataSource.watchActiveProfile().map((event) => event?.toEntity()).handleExceptions((
      error,
      stackTrace,
    ) {
      loggy.error("error watching active profile", error, stackTrace);
      return ProfileUnexpectedFailure(error, stackTrace);
    });
  }

  @override
  Stream<Either<ProfileFailure, bool>> watchHasAnyProfile() {
    return _profileDataSource
        .watchProfilesCount()
        .map((event) => event != 0)
        .handleExceptions(ProfileUnexpectedFailure.new);
  }

  @override
  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchAll({
    ProfilesSort sort = ProfilesSort.lastUpdate,
    SortMode sortMode = SortMode.ascending,
  }) {
    return _profileDataSource
        .watchAll(sort: sort, sortMode: sortMode)
        .map((event) => event.map((e) => e.toEntity()).toList())
        .handleExceptions(ProfileUnexpectedFailure.new);
  }

  @override
  TaskEither<ProfileFailure, Unit> upsertRemote(String url, {UserOverride? userOverride, CancelToken? cancelToken}) =>
      TaskEither.tryCatch(
        () async => (await _profileDataSource.getByUrl(url))?.toEntity(),
        ProfileFailure.unexpected,
      ).flatMap((existing) {
        final id = existing?.id ?? const Uuid().v4();
        return _write(id, () async {
          // Re-read inside the shared commit lock: an override edit may have
          // queued since the URL lookup. Never restore that stale entity.
          final current = existing == null ? null : (await _profileDataSource.getById(id))?.toEntity();
          if (existing != null && current == null) return left(const ProfileFailure.notFound());
          final file = _profilePathResolver.file(id);
          final tempFile = _profilePathResolver.tempFile('$id.${const Uuid().v4()}');
          try {
            final updating = current is RemoteProfileEntity;
            final parsed =
                await (current is RemoteProfileEntity
                        ? _profileParser.updateRemote(
                            rp: userOverride == null ? current : current.copyWith(userOverride: userOverride),
                            tempFilePath: tempFile.path,
                            cancelToken: cancelToken,
                          )
                        : _profileParser.addRemote(
                            id: id,
                            url: url,
                            tempFilePath: tempFile.path,
                            userOverride: userOverride,
                            cancelToken: cancelToken,
                          ))
                    .run();
            if (parsed.isLeft()) return left(parsed.getLeft().toNullable()!);
            final entry = parsed.getRight().toNullable()!;
            final validated = await validateConfig(
              file.path,
              tempFile.path,
              ProfileParser.profileOverrideHelper(profile: entry),
              false,
            ).run();
            if (validated.isLeft()) return validated;
            if (updating) {
              await _profileDataSource.edit(id, entry);
            } else {
              await _profileDataSource.insert(entry);
            }
            return right(unit);
          } finally {
            if (await tempFile.exists()) await tempFile.delete();
          }
        });
      });

  @override
  TaskEither<ProfileFailure, Unit> addLocal(String content, {UserOverride? userOverride}) => TaskEither(() {
    final id = const Uuid().v4();
    return _write(id, () async {
      final file = _profilePathResolver.file(id);
      final tempFile = _profilePathResolver.tempFile('$id.${const Uuid().v4()}');
      try {
        await tempFile.writeAsString(content);
        return await _profileParser
            .addLocal(id: id, content: content, tempFilePath: tempFile.path, userOverride: userOverride)
            .flatMap(
              (profEntity) =>
                  validateConfig(
                    file.path,
                    tempFile.path,
                    ProfileParser.profileOverrideHelper(profile: profEntity),
                    false,
                  ).flatMap(
                    (_) => TaskEither.tryCatch(() async {
                      await _profileDataSource.insert(profEntity);
                      return unit;
                    }, ProfileFailure.unexpected),
                  ),
            )
            .run();
      } finally {
        if (await tempFile.exists()) await tempFile.delete();
      }
    }).run();
  });

  @override
  TaskEither<ProfileFailure, Unit> offlineUpdate(ProfileEntity profile, String nContent) =>
      _write(profile.id, () async {
        final current = (await _profileDataSource.getById(profile.id))?.toEntity();
        if (current == null || current.runtimeType != profile.runtimeType) return left(const ProfileFailure.notFound());
        return _persistConfig(current.copyWith(userOverride: profile.userOverride), nContent);
      });

  @override
  TaskEither<ProfileFailure, Unit> commitConfig(String id, String content, {required String expectedRawContent}) =>
      _write(id, () async {
        final current = (await _profileDataSource.getById(id))?.toEntity();
        // The node editor cannot recreate a deleted profile or edit a remote one.
        if (current is! LocalProfileEntity) return left(const ProfileFailure.notFound());
        if (await _profilePathResolver.file(id).readAsString() != expectedRawContent) {
          return left(const ProfileFailure.unexpected(ProfileCommitConflict()));
        }
        // Use the entity read under this lock, including the latest user override.
        return _persistConfig(current, content);
      });

  @override
  TaskEither<ProfileFailure, Unit> commitDetails(
    ProfileEntity profile, {
    required UserOverride? expectedUserOverride,
    String? content,
    String? expectedRawContent,
  }) => _write(profile.id, () async {
    final current = (await _profileDataSource.getById(profile.id))?.toEntity();
    if (current == null || current.runtimeType != profile.runtimeType) return left(const ProfileFailure.notFound());
    if (current.userOverride != expectedUserOverride) {
      return left(const ProfileFailure.unexpected(ProfileCommitConflict()));
    }
    final updated = current.copyWith(userOverride: profile.userOverride);
    if (content != null) {
      if (expectedRawContent == null ||
          await _profilePathResolver.file(profile.id).readAsString() != expectedRawContent) {
        return left(const ProfileFailure.unexpected(ProfileCommitConflict()));
      }
      return _persistConfig(updated, content);
    }
    // Override-only save: parse current metadata, but never validate/rewrite the
    // config file. The details page's display projection is not a write source.
    final parsed = ProfileParser.parse(tempFilePath: _profilePathResolver.file(profile.id).path, profile: updated);
    if (parsed.isLeft()) return left(parsed.getLeft().toNullable()!);
    await _profileDataSource.edit(profile.id, parsed.getRight().toNullable()!.toUpdateEntry());
    return right(unit);
  });

  /// Called only while the profile commit lock is held. Each parse owns its temp
  /// file; cleanup cannot remove another writer's input, even on failure.
  Future<Either<ProfileFailure, Unit>> _persistConfig(ProfileEntity profile, String content) async {
    final file = _profilePathResolver.file(profile.id);
    final tempFile = _profilePathResolver.tempFile('${profile.id}.${const Uuid().v4()}');
    try {
      await tempFile.writeAsString(content);
      return await TaskEither.fromEither(_profileParser.offlineUpdate(profile: profile, tempFilePath: tempFile.path))
          .flatMap(
            (entry) =>
                validateConfig(
                  file.path,
                  tempFile.path,
                  ProfileParser.profileOverrideHelper(profile: entry),
                  false,
                ).flatMap(
                  (_) => TaskEither.tryCatch(() async {
                    await _profileDataSource.edit(profile.id, entry);
                    return unit;
                  }, ProfileFailure.unexpected),
                ),
          )
          .run();
    } finally {
      if (await tempFile.exists()) await tempFile.delete();
    }
  }

  @override
  TaskEither<ProfileFailure, Unit> validateConfig(String path, String tempPath, String? profileOverride, bool debug) =>
      TaskEither.fromEither(_configOptionRepo.fullOptionsOverrided(profileOverride))
          .mapLeft((configOptionFailure) => ProfileFailure.invalidConfig(null, configOptionFailure))
          .flatMap(
            (overridedOptions) => _singbox
                .changeOptions(overridedOptions)
                .mapLeft(ProfileFailure.invalidConfig)
                .flatMap(
                  (_) => _singbox.validateConfigByPath(path, tempPath, debug).mapLeft(ProfileFailure.invalidConfig),
                ),
          );

  @override
  TaskEither<ProfileFailure, String> generateConfig(String id) => TaskEither.fromEither(
    Either.tryCatch(() => _profilePathResolver.file(id), ProfileFailure.unexpected),
  ).flatMap((configFile) => _singbox.generateFullConfigByPath(configFile.path).mapLeft(ProfileFailure.unexpected));

  @override
  TaskEither<ProfileFailure, String> getRawConfig(String id) {
    return TaskEither.fromEither(
      Either.tryCatch(() => _profilePathResolver.file(id), ProfileFailure.unexpected),
    ).flatMap((configFile) => TaskEither.tryCatch(() => configFile.readAsString(), ProfileFailure.unexpected));
  }
}
