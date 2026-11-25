import 'package:flutter_riverpod/flutter_riverpod.dart';

class SharedInboxPayload {
  const SharedInboxPayload({
    this.subject = '',
    this.text = '',
    this.files = const [],
  });

  final String subject;
  final String text;
  final List<String> files;

  bool get isEmpty =>
      subject.trim().isEmpty && text.trim().isEmpty && files.isEmpty;

  String formattedPromptText() {
    final s = subject.trim();
    final t = text.trim();
    if (s.isNotEmpty && t.isNotEmpty && !t.contains(s)) {
      return '$s\n\n$t';
    }
    return t.isNotEmpty ? t : s;
  }

  static SharedInboxPayload? fromMap(Map<Object?, Object?>? raw) {
    if (raw == null) return null;
    final subject = raw['subject']?.toString() ?? '';
    final text = raw['text']?.toString() ?? '';
    final filesRaw = raw['files'];
    final files = filesRaw is List
        ? filesRaw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : const <String>[];
    final payload = SharedInboxPayload(
      subject: subject,
      text: text,
      files: files,
    );
    return payload.isEmpty ? null : payload;
  }
}

final sharedInboxProvider =
    NotifierProvider<SharedInboxNotifier, SharedInboxPayload?>(
  SharedInboxNotifier.new,
);

class SharedInboxNotifier extends Notifier<SharedInboxPayload?> {
  @override
  SharedInboxPayload? build() => null;

  void enqueue(SharedInboxPayload payload) {
    if (payload.isEmpty) return;
    state = payload;
  }

  SharedInboxPayload? consume() {
    final cur = state;
    state = null;
    return cur;
  }
}
