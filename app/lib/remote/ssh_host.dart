class SshHostConfig {
  const SshHostConfig({
    required this.id,
    required this.name,
    required this.hostname,
    this.port = 22,
    required this.username,
    this.defaultWorkspace = '~',
    this.agyBinary = 'agy',
    this.usePrivateKey = false,
    this.hostKeyFingerprint,
  });

  final String id;
  final String name;
  final String hostname;
  final int port;
  final String username;
  final String defaultWorkspace;
  final String agyBinary;
  final bool usePrivateKey;
  final String? hostKeyFingerprint;

  SshHostConfig copyWith({
    String? name,
    String? hostname,
    int? port,
    String? username,
    String? defaultWorkspace,
    String? agyBinary,
    bool? usePrivateKey,
    String? hostKeyFingerprint,
  }) {
    return SshHostConfig(
      id: id,
      name: name ?? this.name,
      hostname: hostname ?? this.hostname,
      port: port ?? this.port,
      username: username ?? this.username,
      defaultWorkspace: defaultWorkspace ?? this.defaultWorkspace,
      agyBinary: agyBinary ?? this.agyBinary,
      usePrivateKey: usePrivateKey ?? this.usePrivateKey,
      hostKeyFingerprint: hostKeyFingerprint ?? this.hostKeyFingerprint,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'hostname': hostname,
        'port': port,
        'username': username,
        'defaultWorkspace': defaultWorkspace,
        'agyBinary': agyBinary,
        'usePrivateKey': usePrivateKey,
        if (hostKeyFingerprint != null)
          'hostKeyFingerprint': hostKeyFingerprint,
      };

  factory SshHostConfig.fromJson(Map<String, dynamic> json) {
    return SshHostConfig(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Remote Host',
      hostname: json['hostname'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 22,
      username: json['username'] as String? ?? '',
      defaultWorkspace: json['defaultWorkspace'] as String? ?? '~',
      agyBinary: json['agyBinary'] as String? ?? 'agy',
      usePrivateKey: json['usePrivateKey'] as bool? ?? false,
      hostKeyFingerprint: json['hostKeyFingerprint'] as String?,
    );
  }
}
