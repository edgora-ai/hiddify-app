import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';

part 'node_failure.freezed.dart';

@freezed
sealed class NodeFailure with _$NodeFailure, Failure {
  const NodeFailure._();

  @With<UnexpectedFailure>()
  const factory NodeFailure.unexpected([Object? error, StackTrace? stackTrace]) = NodeUnexpectedFailure;

  /// Remote profiles are read-only for node editing.
  @With<ExpectedFailure>()
  const factory NodeFailure.readOnly() = NodeReadOnly;

  /// Target outbound no longer exists in the config.
  @With<ExpectedFailure>()
  const factory NodeFailure.notFound() = NodeNotFound;

  /// Raw tag matched zero or multiple outbounds.
  @With<ExpectedFailure>()
  const factory NodeFailure.ambiguousTag() = NodeAmbiguousTag;

  /// Config changed on disk since the editor opened.
  @With<ExpectedFailure>()
  const factory NodeFailure.configChanged() = NodeConfigChanged;

  /// Duplicate tag for add/rename.
  @With<ExpectedFailure>()
  const factory NodeFailure.duplicateName() = NodeDuplicateName;

  /// Rename/delete touches references we refuse to auto-sync
  /// (route rule targets, include/exclude patterns).
  @With<ExpectedFailure>()
  const factory NodeFailure.referenceConflict(String detail) = NodeReferenceConflict;

  /// Refusing to delete the last proxy node or empty a group.
  @With<ExpectedFailure>()
  const factory NodeFailure.wouldBreakConfig(String detail) = NodeWouldBreakConfig;

  /// Config is not editable as a form (root not an object, etc.).
  @With<ExpectedFailure>()
  const factory NodeFailure.invalidStructure(String detail) = NodeInvalidStructure;

  /// Core rejected the new config during offlineUpdate.
  @With<ExpectedFailure>()
  const factory NodeFailure.validationFailed(String detail) = NodeValidationFailed;

  /// Share link cannot represent this outbound.
  @With<ExpectedFailure>()
  const factory NodeFailure.shareUnsupported(String reason) = NodeShareUnsupported;

  /// Protocol has no form support.
  @With<ExpectedFailure>()
  const factory NodeFailure.unsupportedProtocol() = NodeUnsupportedProtocol;

  @override
  ({String type, String? message}) present(TranslationsEn t) {
    return switch (this) {
      NodeUnexpectedFailure() => (type: t.errors.unexpected, message: null),
      NodeReadOnly() => (type: t.errors.nodes.readOnly, message: null),
      NodeNotFound() => (type: t.errors.nodes.notFound, message: null),
      NodeAmbiguousTag() => (type: t.errors.nodes.ambiguousTag, message: null),
      NodeConfigChanged() => (type: t.errors.nodes.configChanged, message: null),
      NodeDuplicateName() => (type: t.errors.nodes.duplicateName, message: null),
      NodeReferenceConflict(:final detail) => (
        type: t.errors.nodes.referenceConflict,
        message: detail,
      ),
      NodeWouldBreakConfig(:final detail) => (
        type: t.errors.nodes.wouldBreakConfig,
        message: detail,
      ),
      NodeInvalidStructure(:final detail) => (
        type: t.errors.nodes.invalidStructure,
        message: detail,
      ),
      NodeValidationFailed(:final detail) => (
        type: t.errors.nodes.validationFailed,
        message: detail,
      ),
      NodeShareUnsupported(:final reason) => (
        type: t.errors.nodes.shareUnsupported,
        message: reason,
      ),
      NodeUnsupportedProtocol() => (type: t.errors.nodes.unsupportedProtocol, message: null),
    };
  }
}
