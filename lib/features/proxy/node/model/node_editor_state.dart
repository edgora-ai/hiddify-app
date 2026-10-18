import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';

part 'node_editor_state.freezed.dart';

/// Save/apply phase. Persistence and core-apply are reported separately so
/// the UI can distinguish "saved" from "saved and applied".
enum NodeSavePhase { idle, saving, saved, applying, applied, applyFailed, saveFailed }

@freezed
class NodeEditorState with _$NodeEditorState {
  const NodeEditorState._();

  const factory NodeEditorState({
    required ProfileEntity profile,
    required String rawContentSnapshot,
    required Map<String, dynamic> draft,
    required Map<String, dynamic> originalDraft,
    String? rawTag,
    @Default(false) bool isNew,
    @Default(NodeSavePhase.idle) NodeSavePhase savePhase,
    @Default({}) Map<String, String> fieldErrors,
    String? saveError,
    @Default([]) List<String> groupTags,
    @Default([]) List<String> selectedGroups,
  }) = _NodeEditorState;

  bool get isDirty => !_mapsEqual(draft, originalDraft) || (isNew && selectedGroups.isNotEmpty);

  bool get isSaving => savePhase == NodeSavePhase.saving || savePhase == NodeSavePhase.applying;

  static bool _mapsEqual(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k)) return false;
      final va = a[k];
      final vb = b[k];
      if (va is Map<String, dynamic> && vb is Map<String, dynamic>) {
        if (!_mapsEqual(va, vb)) return false;
      } else if (va is List && vb is List) {
        if (va.length != vb.length) return false;
        for (var i = 0; i < va.length; i++) {
          final ea = va[i];
          final eb = vb[i];
          if (ea is Map<String, dynamic> && eb is Map<String, dynamic>) {
            if (!_mapsEqual(ea, eb)) return false;
          } else if (ea != eb) {
            return false;
          }
        }
      } else if (va != vb) {
        return false;
      }
    }
    return true;
  }
}
