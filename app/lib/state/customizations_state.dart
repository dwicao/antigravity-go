import 'package:agy_client/agy_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../runtime/runtime_bridge.dart';
import 'projects_state.dart';
import 'runtime_state.dart';

final customizationsProvider =
    NotifierProvider<CustomizationsNotifier, List<CustomizationItem>>(
  CustomizationsNotifier.new,
);

class CustomizationsNotifier extends Notifier<List<CustomizationItem>> {
  @override
  List<CustomizationItem> build() {
    Future.microtask(refresh);
    return const [];
  }

  Future<void> refresh() async {
    final projDir = ref.read(projectsProvider).activeProject.primaryFolder;
    final runtimeRoot = ref.read(runtimeProvider).status.workspaceRoot ?? '';
    final cwd = projDir.isNotEmpty ? projDir : runtimeRoot;
    state = await RuntimeBridge.instance.listCustomizations(cwd);
  }

  Future<bool> saveFile(String path, String content) async {
    final ok = await RuntimeBridge.instance.writeWorkspaceFile(path, content);
    if (ok) await refresh();
    return ok;
  }
}
