import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/node/data/node_json_adapter.dart';
import 'package:hiddify/features/proxy/node/data/node_protocol_templates.dart';
import 'package:hiddify/features/proxy/node/model/node_editor_state.dart';
import 'package:hiddify/features/proxy/node/model/node_failure.dart';
import 'package:hiddify/features/proxy/node/notifier/node_providers.dart';
import 'package:hiddify/features/proxy/node/notifier/profile_nodes_notifier.dart';
import 'package:hiddify/features/proxy/node/validation/node_validators.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/validators.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'node_editor_notifier.g.dart';

/// Editor for one node. [rawTag] null means add-mode.
@riverpod
class NodeEditorNotifier extends _$NodeEditorNotifier with AppLogger {
  @override
  Future<NodeEditorState> build(String profileId, String? rawTag) async {
    final service = ref.watch(nodeConfigServiceProvider);
    final profile = (await service.loadProfile(profileId)).match((l) => throw l, (r) => r);
    if (profile is! LocalProfileEntity) throw const NodeFailure.readOnly();

    final loaded = (await service.loadConfig(profileId)).match((l) => throw l, (r) => r);
    final config = loaded.config;
    final rawContent = loaded.rawContent;

    if (rawTag == null) {
      // Add mode: start from an empty vmess skeleton; the form lets the
      // user switch protocols (which resets the draft, with confirmation).
      final draft = NodeProtocolTemplates.create('vmess', '');
      return NodeEditorState(
        profile: profile,
        rawContentSnapshot: rawContent,
        draft: draft,
        originalDraft: NodeJson.deepCopyMap(draft),
        isNew: true,
        groupTags: service.groupTags(config),
      );
    }

    final found = service.findOutbound(config, rawTag);
    final outbound = found.match((l) => throw l, (r) => r);
    if (!NodeProtocolTemplates.isSupported(outbound['type'] as String?)) {
      throw const NodeFailure.unsupportedProtocol();
    }
    final draft = NodeJson.deepCopyMap(outbound);
    return NodeEditorState(
      profile: profile,
      rawContentSnapshot: rawContent,
      draft: draft,
      originalDraft: NodeJson.deepCopyMap(draft),
      rawTag: rawTag,
      groupTags: service.groupTags(config),
    );
  }

  NodeEditorState? get _data => state.asData?.value;

  /// Applies a JSON-path write to the draft and marks dirty.
  void setPath(List<String> path, dynamic value) {
    final data = _data;
    if (data == null) return;
    final draft = NodeJson.deepCopyMap(data.draft);
    NodeJson.putPath(draft, path, value);
    // Clear the field error for the edited leaf (best-effort by last segment).
    final errors = Map<String, String>.of(data.fieldErrors)..remove(path.last);
    state = AsyncData(data.copyWith(draft: draft, fieldErrors: errors));
  }

  /// Applies a TLS mode selection (none/tls/reality) to the draft.
  void setTlsMode(String mode) {
    final data = _data;
    if (data == null) return;
    final draft = NodeJson.deepCopyMap(data.draft);
    NodeJson.applyTlsMode(draft, mode);
    state = AsyncData(data.copyWith(draft: draft));
  }

  /// Switches protocol for a new node (resets the draft skeleton).
  void switchProtocol(String protocol, {required String keepName}) {
    final data = _data;
    if (data == null || !data.isNew) return;
    final draft = NodeProtocolTemplates.create(protocol, keepName);
    state = AsyncData(
      data.copyWith(draft: draft, originalDraft: NodeJson.deepCopyMap(draft), fieldErrors: {}),
    );
  }

  void toggleGroup(String groupTag, bool selected) {
    final data = _data;
    if (data == null) return;
    final selectedGroups = List<String>.of(data.selectedGroups);
    if (selected) {
      if (!selectedGroups.contains(groupTag)) selectedGroups.add(groupTag);
    } else {
      selectedGroups.remove(groupTag);
    }
    state = AsyncData(data.copyWith(selectedGroups: selectedGroups));
  }

  /// Validates the whole draft; returns true when clean.
  bool validate(TranslationsEn t) {
    final data = _data;
    if (data == null) return false;
    final errors = <String, String>{};
    final d = data.draft;
    final type = d['type'] as String? ?? '';

    void req(String key, String? value, String fieldLabel) {
      if (value == null || value.isEmpty) errors[key] = t.errors.nodes.required(field: fieldLabel);
    }

    // Name.
    final name = NodeJson.asString(d['tag']) ?? '';
    if (name.trim().isEmpty) {
      errors['tag'] = t.errors.nodes.required(field: t.common.name);
    }
    // Server + port.
    final server = NodeJson.asString(d['server']) ?? '';
    if (!NodeValidators.isServerAddress(server)) errors['server'] = t.errors.nodes.invalidServer;
    final portRaw = d['server_port'];
    final portStr = portRaw is int ? portRaw.toString() : (portRaw as String? ?? '');
    if (!isPort(portStr)) errors['server_port'] = t.errors.nodes.invalidPort;

    // Credentials per protocol.
    switch (type) {
      case 'vmess':
        _validateUuid(t, d, errors);
      case 'vless':
        _validateUuid(t, d, errors);
        final flow = NodeJson.asString(d['flow']) ?? '';
        final transport = NodeJson.transportTypeOf(d);
        final mux = d['multiplex'] is Map && (d['multiplex'] as Map)['enabled'] == true;
        final combo = NodeValidators.vlessCombinationError(flow: flow, transport: transport, multiplex: mux);
        if (combo != null) errors['flow'] = t.errors.nodes.invalidFlow;
      case 'trojan':
        req('password', NodeJson.asString(d['password']), t.pages.nodeEditor.fields.password);
      case 'shadowsocks':
        final method = NodeJson.asString(d['method']) ?? '';
        final password = NodeJson.asString(d['password']) ?? '';
        if (!NodeValidators.isShadowsocksKey(method, password)) {
          errors['password'] = t.errors.nodes.invalidSsKey;
        }
      case 'tuic':
        _validateUuid(t, d, errors);
        req('password', NodeJson.asString(d['password']), t.pages.nodeEditor.fields.password);
        final hb = NodeJson.asString(d['heartbeat']);
        if (hb != null && hb.isNotEmpty && !NodeValidators.isDuration(hb)) {
          errors['heartbeat'] = t.errors.nodes.invalidDuration;
        }
      case 'hysteria2':
        req('password', NodeJson.asString(d['password']), t.pages.nodeEditor.fields.password);
        for (final k in ['up_mbps', 'down_mbps']) {
          final v = d[k];
          if (v != null && !NodeValidators.isPositiveNumber(v.toString())) {
            errors[k] = t.errors.nodes.invalidNumber;
          }
        }
    }

    // TLS / reality.
    final tlsMode = NodeJson.tlsModeOf(d);
    if (tlsMode == 'reality') {
      final pub = NodeJson.asString(NodeJson.getPath(d, ['tls', 'reality', 'public_key'])) ?? '';
      if (!NodeValidators.isRealityPublicKey(pub)) {
        errors['reality.public_key'] = t.errors.nodes.invalidPublicKey;
      }
      final sid = NodeJson.asString(NodeJson.getPath(d, ['tls', 'reality', 'short_id'])) ?? '';
      if (!NodeValidators.isRealityShortId(sid)) {
        errors['reality.short_id'] = t.errors.nodes.invalidShortId;
      }
    }

    state = AsyncData(data.copyWith(fieldErrors: errors));
    return errors.isEmpty;
  }

  void _validateUuid(TranslationsEn t, Map<String, dynamic> d, Map<String, String> errors) {
    final uuid = NodeJson.asString(d['uuid']) ?? '';
    if (!NodeValidators.isUuid(uuid)) errors['uuid'] = t.errors.nodes.invalidUuid;
  }

  /// Saves the draft. Returns the outcome; never throws into AsyncError so
  /// the form keeps user input on failure.
  Future<NodeSaveResult> save(TranslationsEn t) async {
    final data = _data;
    if (data == null) return const NodeSaveResult.aborted();
    if (data.isSaving) return const NodeSaveResult.aborted();
    if (!validate(t)) return const NodeSaveResult.invalid();

    state = AsyncData(data.copyWith(savePhase: NodeSavePhase.saving, saveError: null));
    final service = ref.read(nodeConfigServiceProvider);

    final eitherResult = data.isNew
        ? await service.addNode(
            profileId: data.profile.id,
            expectedRawContent: data.rawContentSnapshot,
            draft: data.draft,
            groupTags: data.selectedGroups,
          )
        : await service.updateNode(
            profileId: data.profile.id,
            expectedRawContent: data.rawContentSnapshot,
            rawTag: data.rawTag!,
            newDraft: data.draft,
          );

    if (eitherResult.isLeft()) {
      final failure = eitherResult.getLeft().toNullable()!;
      final cur = _data;
      if (cur != null) {
        state = AsyncData(
          cur.copyWith(savePhase: NodeSavePhase.saveFailed, saveError: failure.present(t).type),
        );
      }
      // Refresh snapshot info on conflict so a retry compares correctly.
      if (failure is NodeConfigChanged) {
        _refreshSnapshot();
      }
      return NodeSaveResult.failed(failure);
    }

    state = AsyncData(
      _data!.copyWith(
        savePhase: NodeSavePhase.saved,
        originalDraft: NodeJson.deepCopyMap(_data!.draft),
        rawTag: _data!.isNew ? NodeJson.asString(_data!.draft['tag']) : _data!.rawTag,
        isNew: false,
      ),
    );
    // Keep the nodes list fresh.
    ref.invalidate(profileNodesNotifierProvider(data.profile.id));

    // Apply to the running core when this is the active, connected profile.
    final shouldApply = await _shouldApply(data.profile.id);
    if (!shouldApply) return const NodeSaveResult.saved();
    return _apply(data.profile.id, t);
  }

  /// Retries only the apply step (config already saved).
  Future<NodeSaveResult> retryApply(TranslationsEn t) async {
    final data = _data;
    if (data == null) return const NodeSaveResult.aborted();
    return _apply(data.profile.id, t);
  }

  Future<bool> _shouldApply(String profileId) async {
    final active = await ref.read(activeProfileProvider.future);
    if (active?.id != profileId) return false;
    final status = ref.read(connectionNotifierProvider).valueOrNull;
    return status is Connected;
  }

  Future<NodeSaveResult> _apply(String profileId, TranslationsEn t) async {
    final data = _data;
    if (data == null) return const NodeSaveResult.aborted();
    state = AsyncData(data.copyWith(savePhase: NodeSavePhase.applying));

    final active = await ref.read(activeProfileProvider.future);
    await ref.read(connectionNotifierProvider.notifier).reconnect(active);

    final status = ref.read(connectionNotifierProvider).asData?.value;
    final cur = _data;
    if (status is Connected) {
      if (cur != null) state = AsyncData(cur.copyWith(savePhase: NodeSavePhase.applied));
      return const NodeSaveResult.applied();
    }
    final err = ref.read(connectionNotifierProvider).asError?.error;
    if (cur != null) {
      state = AsyncData(
        cur.copyWith(
          savePhase: NodeSavePhase.applyFailed,
          saveError: err != null ? t.presentShortError(err) : t.pages.nodeEditor.messages.applyFailed,
        ),
      );
    }
    return const NodeSaveResult.applyFailed();
  }

  Future<void> _refreshSnapshot() async {
    final data = _data;
    if (data == null) return;
    final service = ref.read(nodeConfigServiceProvider);
    final loaded = (await service.loadConfig(data.profile.id)).match((_) => null, (r) => r);
    if (loaded == null) return;
    // Keep the draft; only refresh the snapshot so the next save compares
    // against the newest content (target re-checked at save time).
    state = AsyncData(data.copyWith(rawContentSnapshot: loaded.rawContent));
  }
}

/// Outcome of [NodeEditorNotifier.save]/[retryApply] for the page to react.
class NodeSaveResult {
  const NodeSaveResult._(this.kind, this.failure);

  const NodeSaveResult.aborted() : this._(NodeSaveKind.aborted, null);
  const NodeSaveResult.invalid() : this._(NodeSaveKind.invalid, null);
  const NodeSaveResult.saved() : this._(NodeSaveKind.saved, null);
  const NodeSaveResult.applied() : this._(NodeSaveKind.applied, null);
  const NodeSaveResult.applyFailed() : this._(NodeSaveKind.applyFailed, null);
  const NodeSaveResult.failed(NodeFailure failure) : this._(NodeSaveKind.failed, failure);

  final NodeSaveKind kind;
  final NodeFailure? failure;
}

enum NodeSaveKind { aborted, invalid, saved, applied, applyFailed, failed }
