import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/proxy/node/data/node_config_service.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'node_providers.g.dart';

@Riverpod(keepAlive: true)
NodeConfigService nodeConfigService(Ref ref) {
  return NodeConfigService(ref.watch(profileRepositoryProvider).requireValue);
}
