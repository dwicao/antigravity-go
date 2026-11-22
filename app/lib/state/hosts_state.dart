import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../remote/ssh_host.dart';

class HostsState {
  const HostsState({
    this.activeHostId = 'local',
    this.sshHosts = const [],
  });

  final String activeHostId;
  final List<SshHostConfig> sshHosts;

  bool get isLocalActive => activeHostId == 'local';

  SshHostConfig? get activeSshHost {
    if (isLocalActive) return null;
    for (final h in sshHosts) {
      if (h.id == activeHostId) return h;
    }
    return null;
  }

  HostsState copyWith({
    String? activeHostId,
    List<SshHostConfig>? sshHosts,
  }) {
    return HostsState(
      activeHostId: activeHostId ?? this.activeHostId,
      sshHosts: sshHosts ?? this.sshHosts,
    );
  }
}

final hostsProvider =
    NotifierProvider<HostsNotifier, HostsState>(HostsNotifier.new);

class HostsNotifier extends Notifier<HostsState> {
  static const _hostsKey = 'agy_ssh_hosts_v1';
  static const _activeHostKey = 'agy_active_host_id';
  static const _secure = FlutterSecureStorage();

  @override
  HostsState build() {
    Future.microtask(_load);
    return const HostsState();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_hostsKey);
    final active = prefs.getString(_activeHostKey) ?? 'local';
    final hosts = <SshHostConfig>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        for (final item in decoded.whereType<Map<String, dynamic>>()) {
          hosts.add(SshHostConfig.fromJson(item));
        }
      } catch (_) {}
    }
    state = HostsState(activeHostId: active, sshHosts: hosts);
  }

  Future<void> selectHost(String hostId) async {
    state = state.copyWith(activeHostId: hostId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeHostKey, hostId);
  }

  Future<SshHostConfig> addOrUpdateHost(
    SshHostConfig host, {
    String? password,
    String? privateKeyPem,
  }) async {
    final normalized = host.id.isEmpty
        ? SshHostConfig(
            id: const Uuid().v4(),
            name: host.name,
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            defaultWorkspace: host.defaultWorkspace,
            agyBinary: host.agyBinary,
            usePrivateKey: host.usePrivateKey,
          )
        : host;

    final list = [...state.sshHosts];
    final idx = list.indexWhere((h) => h.id == normalized.id);
    if (idx >= 0) {
      list[idx] = normalized;
    } else {
      list.add(normalized);
    }

    if (password != null && password.isNotEmpty) {
      await _secure.write(key: 'ssh_pwd_${normalized.id}', value: password);
    }
    if (privateKeyPem != null && privateKeyPem.isNotEmpty) {
      await _secure.write(
        key: 'ssh_key_${normalized.id}',
        value: privateKeyPem,
      );
    }

    state = state.copyWith(sshHosts: list);
    await _saveList(list);
    return normalized;
  }

  Future<void> removeHost(String id) async {
    final next = state.sshHosts.where((h) => h.id != id).toList();
    final nextActive = state.activeHostId == id ? 'local' : state.activeHostId;
    state = HostsState(activeHostId: nextActive, sshHosts: next);
    await _secure.delete(key: 'ssh_pwd_$id');
    await _secure.delete(key: 'ssh_key_$id');
    await _saveList(next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeHostKey, nextActive);
  }

  Future<(String? password, String? privateKey)> readCredentials(
    String hostId,
  ) async {
    final pwd = await _secure.read(key: 'ssh_pwd_$hostId');
    final key = await _secure.read(key: 'ssh_key_$hostId');
    return (pwd, key);
  }

  Future<void> _saveList(List<SshHostConfig> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _hostsKey,
      jsonEncode(list.map((h) => h.toJson()).toList()),
    );
  }
}
