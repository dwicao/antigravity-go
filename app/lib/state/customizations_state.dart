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
    ref.listen(
      projectsProvider.select((p) => p.activeProjectId),
      (_, _) => Future.microtask(refresh),
    );
    Future.microtask(refresh);
    return const [];
  }

  String _resolveCwd() {
    final projDir = ref.read(projectsProvider).activeProject.primaryFolder;
    final runtimeRoot = ref.read(runtimeProvider).status.workspaceRoot ?? '';
    return projDir.isNotEmpty ? projDir : runtimeRoot;
  }

  Future<void> refresh() async {
    final cwd = _resolveCwd();
    final items = await RuntimeBridge.instance.listCustomizations(cwd);
    if (!ref.mounted) return;
    state = items;
  }

  Future<bool> saveFile(String path, String content) async {
    final ok = await RuntimeBridge.instance.writeWorkspaceFile(path, content);
    if (ok) await refresh();
    return ok;
  }

  Future<String?> createSkill({
    required String name,
    String description = '',
    String scope = 'Project',
    String? content,
  }) async {
    final path = await RuntimeBridge.instance.createSkill(
      name: name,
      description: description,
      scope: scope,
      cwd: _resolveCwd(),
      content: content,
    );
    if (path != null) await refresh();
    return path;
  }

  Future<bool> addHttpMcpServer({
    required String name,
    required String url,
    String? authHeader,
  }) async {
    final ok = await RuntimeBridge.instance.addHttpMcpServer(
      name: name,
      url: url,
      authHeader: authHeader,
    );
    if (ok) await refresh();
    return ok;
  }
}
