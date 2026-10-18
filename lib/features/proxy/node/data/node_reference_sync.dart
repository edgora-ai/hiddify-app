/// Reference handling for node rename/delete.
///
/// Only known schema paths are synced automatically. Anything ambiguous
/// (route rule action targets, include/exclude patterns) refuses the
/// operation instead of guessing — see [ReferenceCheck].
abstract final class NodeReferenceSync {
  /// Outbound types that hold member references.
  static const groupTypes = {'selector', 'urltest'};

  /// Result of scanning a config for references to [tag].
  static ReferenceCheck check({
    required Map<String, dynamic> config,
    required String tag,
  }) {
    final groups = <String>[];
    final defaults = <String>[];
    var finalRoute = false;
    final detours = <String>[];
    final ruleTargets = <String>[];
    final patternRefs = <String>[];

    final outbounds = config['outbounds'];
    if (outbounds is List) {
      for (final o in outbounds) {
        if (o is! Map<String, dynamic>) continue;
        final oTag = o['tag'];
        final oType = o['type'];
        if (oType is String && groupTypes.contains(oType)) {
          final members = o['outbounds'];
          if (members is List && members.contains(tag)) groups.add('$oTag');
          if (o['default'] == tag) defaults.add('$oTag');
          for (final k in ['include', 'exclude']) {
            final inc = o[k];
            if (inc is List && inc.contains(tag)) patternRefs.add('$oTag.$k');
            if (inc is String && inc.isNotEmpty) patternRefs.add('$oTag.$k');
          }
        }
        if (o['detour'] == tag) detours.add('${o['tag']}');
      }
    }

    final route = config['route'];
    if (route is Map<String, dynamic>) {
      if (route['final'] == tag) finalRoute = true;
      final rules = route['rules'];
      if (rules is List) {
        _scanRules(rules, tag, ruleTargets, 'route.rules');
      }
    }

    return ReferenceCheck(
      groups: groups,
      defaults: defaults,
      finalRoute: finalRoute,
      detours: detours,
      ruleTargets: ruleTargets,
      patternRefs: patternRefs,
    );
  }

  static void _scanRules(List rules, String tag, List<String> out, String path) {
    for (var i = 0; i < rules.length; i++) {
      final r = rules[i];
      if (r is! Map<String, dynamic>) continue;
      final here = '$path[$i]';
      // Only the action target counts as a reference; match conditions
      // (domain, ip_cidr, port, ...) must NOT be string-replaced.
      if (r['outbound'] == tag) out.add(here);
      final nested = r['rules'];
      if (nested is List) _scanRules(nested, tag, out, '$here.rules');
    }
  }

  /// Applies a rename inside [config] (mutates it). Call [check] first and
  /// refuse when [ReferenceCheck.hasBlockingRefs] is true.
  static void applyRename({
    required Map<String, dynamic> config,
    required String oldTag,
    required String newTag,
  }) {
    final outbounds = config['outbounds'];
    if (outbounds is List) {
      for (final o in outbounds) {
        if (o is! Map<String, dynamic>) continue;
        final members = o['outbounds'];
        if (members is List) {
          for (var i = 0; i < members.length; i++) {
            if (members[i] == oldTag) members[i] = newTag;
          }
        }
        if (o['default'] == oldTag) o['default'] = newTag;
        if (o['detour'] == oldTag) o['detour'] = newTag;
        for (final k in ['include', 'exclude']) {
          final inc = o[k];
          if (inc is List) {
            for (var i = 0; i < inc.length; i++) {
              if (inc[i] == oldTag) inc[i] = newTag;
            }
          }
        }
      }
    }
    final route = config['route'];
    if (route is Map<String, dynamic> && route['final'] == oldTag) {
      route['final'] = newTag;
    }
  }

  /// Removes member/default references for a deleted tag (mutates [config]).
  /// Returns the list of groups that referenced the tag.
  static List<String> applyDeleteMemberRefs({
    required Map<String, dynamic> config,
    required String tag,
  }) {
    final touched = <String>[];
    final outbounds = config['outbounds'];
    if (outbounds is List) {
      for (final o in outbounds) {
        if (o is! Map<String, dynamic>) continue;
        final members = o['outbounds'];
        if (members is List && members.contains(tag)) {
          members.removeWhere((e) => e == tag);
          touched.add('${o['tag']}');
        }
      }
    }
    return touched;
  }
}

/// Scan result for references to one outbound tag.
class ReferenceCheck {
  const ReferenceCheck({
    required this.groups,
    required this.defaults,
    required this.finalRoute,
    required this.detours,
    required this.ruleTargets,
    required this.patternRefs,
  });

  /// Groups whose member list contains the tag (auto-syncable).
  final List<String> groups;

  /// Groups whose `default` is the tag (needs a replacement on delete).
  final List<String> defaults;

  /// Whether `route.final` points at the tag.
  final bool finalRoute;

  /// Outbounds/endpoints using the tag as `detour`.
  final List<String> detours;

  /// Route rules using the tag as action target (blocking).
  final List<String> ruleTargets;

  /// include/exclude pattern references (blocking: may be regex).
  final List<String> patternRefs;

  /// True when rename/delete must be refused (unknown or unsafe refs).
  bool get hasBlockingRefs => ruleTargets.isNotEmpty || patternRefs.isNotEmpty;

  bool get hasAnyRef =>
      groups.isNotEmpty ||
      defaults.isNotEmpty ||
      finalRoute ||
      detours.isNotEmpty ||
      hasBlockingRefs;
}
