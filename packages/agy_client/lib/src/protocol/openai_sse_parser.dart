import 'dart:convert';

import '../models/usage_quota.dart';

/// Represents a pending OpenAI function tool invocation accumulated across SSE deltas.
class OpenAiToolCallAcc {
  OpenAiToolCallAcc({
    required this.index,
    this.id = '',
    this.name = '',
    String? initialArgs,
  }) : argumentsBuffer = StringBuffer(initialArgs ?? '');

  final int index;
  String id;
  String name;
  final StringBuffer argumentsBuffer;

  Map<String, dynamic> parseArgumentsMap() {
    final raw = argumentsBuffer.toString().trim();
    if (raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return {'_raw': raw};
  }
}

/// Incremental parsed output from one OpenAI `/v1/chat/completions` SSE chunk line
/// or non-streaming JSON response.
class OpenAiStreamSlice {
  const OpenAiStreamSlice({
    this.textDelta = '',
    this.thoughtDelta = '',
    this.usage,
    this.finishReason,
    this.errorMessage,
    this.isDone = false,
  });

  final String textDelta;
  final String thoughtDelta;
  final TokenUsage? usage;
  final String? finishReason;
  final String? errorMessage;
  final bool isDone;
}

/// Stateful SSE chunk parser for OpenAI-compatible `/v1/chat/completions` streams.
///
/// Handles:
/// - `data: {...}` and `data: [DONE]`
/// - Explicit `reasoning_content` / `reasoning` delta fields (DeepSeek, OpenRouter, vLLM, Ollama)
/// - Inline `<think>...</think>` blocks emitted inside `delta.content` (chunk-boundary safe)
/// - Incremental `delta.tool_calls` accumulation
/// - Prompt/completion/reasoning/cached token usage reporting
class OpenAiSseParser {
  final Map<int, OpenAiToolCallAcc> toolCalls = {};
  TokenUsage? latestUsage;
  String? finishReason;

  bool _insideThinkTag = false;
  final StringBuffer _tagCarry = StringBuffer();

  List<OpenAiToolCallAcc> get orderedToolCalls {
    final entries = toolCalls.values.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    return entries;
  }

  /// Splits inline `<think>...</think>` tags cleanly across arbitrary chunk boundaries.
  ({String text, String thought}) splitThinkTags(String chunk) {
    if (chunk.isEmpty) return (text: '', thought: '');
    final input = '${_tagCarry.toString()}$chunk';
    _tagCarry.clear();

    final textOut = StringBuffer();
    final thoughtOut = StringBuffer();
    var pos = 0;

    while (pos < input.length) {
      if (!_insideThinkTag) {
        final openIdx = input.indexOf('<think>', pos);
        if (openIdx >= 0) {
          textOut.write(input.substring(pos, openIdx));
          _insideThinkTag = true;
          pos = openIdx + 7;
          continue;
        }
        final tailStart = input.length - 6;
        final partialIdx = input.lastIndexOf('<');
        if (partialIdx >= 0 && partialIdx >= tailStart) {
          final tail = input.substring(partialIdx);
          if ('<think>'.startsWith(tail)) {
            textOut.write(input.substring(pos, partialIdx));
            _tagCarry.write(tail);
            break;
          }
        }
        textOut.write(input.substring(pos));
        break;
      } else {
        final closeIdx = input.indexOf('</think>', pos);
        if (closeIdx >= 0) {
          thoughtOut.write(input.substring(pos, closeIdx));
          _insideThinkTag = false;
          pos = closeIdx + 8;
          continue;
        }
        final tailStart = input.length - 7;
        final partialIdx = input.lastIndexOf('<');
        if (partialIdx >= 0 && partialIdx >= tailStart) {
          final tail = input.substring(partialIdx);
          if ('</think>'.startsWith(tail)) {
            thoughtOut.write(input.substring(pos, partialIdx));
            _tagCarry.write(tail);
            break;
          }
        }
        thoughtOut.write(input.substring(pos));
        break;
      }
    }

    return (text: textOut.toString(), thought: thoughtOut.toString());
  }

  /// Flushes any trailing buffered characters when the stream completes.
  ({String text, String thought}) flushPendingTags() {
    if (_tagCarry.isEmpty) return (text: '', thought: '');
    final rem = _tagCarry.toString();
    _tagCarry.clear();
    return _insideThinkTag
        ? (text: '', thought: rem)
        : (text: rem, thought: '');
  }

  OpenAiStreamSlice? parseLine(String rawLine) {
    final trimmed = rawLine.trim();
    if (trimmed.isEmpty || trimmed.startsWith(':')) return null;

    var payload = trimmed;
    if (payload.startsWith('data:')) {
      payload = payload.substring(5).trim();
    } else if (!payload.startsWith('{')) {
      return null;
    }

    if (payload == '[DONE]') {
      final tail = flushPendingTags();
      return OpenAiStreamSlice(
        textDelta: tail.text,
        thoughtDelta: tail.thought,
        usage: latestUsage,
        finishReason: finishReason ?? 'stop',
        isDone: true,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final root = decoded.map((k, v) => MapEntry(k.toString(), v));

    final err = root['error'];
    if (err is Map) {
      final msg = err['message']?.toString() ?? jsonEncode(err);
      return OpenAiStreamSlice(errorMessage: msg);
    } else if (err is String && err.isNotEmpty) {
      return OpenAiStreamSlice(errorMessage: err);
    }

    final parsedUsage = _parseUsage(root['usage']);
    if (parsedUsage != null) {
      latestUsage = parsedUsage;
    }

    final choices = root['choices'];
    if (choices is! List || choices.isEmpty) {
      if (parsedUsage != null) {
        return OpenAiStreamSlice(usage: parsedUsage);
      }
      return null;
    }

    final firstChoice = choices.first;
    if (firstChoice is! Map) return null;
    final choice = firstChoice.map((k, v) => MapEntry(k.toString(), v));
    final choiceFinish = choice['finish_reason']?.toString();
    if (choiceFinish != null && choiceFinish.isNotEmpty) {
      finishReason = choiceFinish;
    }

    final deltaRaw = choice['delta'] ?? choice['message'];
    final delta = deltaRaw is Map
        ? deltaRaw.map((k, v) => MapEntry(k.toString(), v))
        : const <String, dynamic>{};

    final toolList = delta['tool_calls'];
    if (toolList is List) {
      for (final item in toolList) {
        if (item is! Map) continue;
        final tm = item.map((k, v) => MapEntry(k.toString(), v));
        final idx = (tm['index'] as num?)?.toInt() ?? 0;
        final acc = toolCalls.putIfAbsent(
          idx,
          () => OpenAiToolCallAcc(index: idx),
        );
        final id = tm['id']?.toString();
        if (id != null && id.isNotEmpty) acc.id = id;
        final fn = tm['function'];
        if (fn is Map) {
          final fnName = fn['name']?.toString();
          final fnArgs = fn['arguments']?.toString();
          if (fnName != null && fnName.isNotEmpty) acc.name = fnName;
          if (fnArgs != null && fnArgs.isNotEmpty) acc.argumentsBuffer.write(fnArgs);
        }
      }
    }

    final explicitThought =
        (delta['reasoning_content'] ?? delta['reasoning'])?.toString() ?? '';
    final rawContent = delta['content'];
    var contentStr = '';
    if (rawContent is String) {
      contentStr = rawContent;
    } else if (rawContent is List) {
      final buf = StringBuffer();
      for (final part in rawContent) {
        if (part is Map && part['text'] != null) {
          buf.write(part['text'].toString());
        }
      }
      contentStr = buf.toString();
    }

    final split = splitThinkTags(contentStr);
    final combinedThought = '$explicitThought${split.thought}';
    if (split.text.isEmpty &&
        combinedThought.isEmpty &&
        parsedUsage == null &&
        choiceFinish == null) {
      return null;
    }

    return OpenAiStreamSlice(
      textDelta: split.text,
      thoughtDelta: combinedThought,
      usage: parsedUsage ?? latestUsage,
      finishReason: choiceFinish,
    );
  }

  static TokenUsage? _parseUsage(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.map((k, v) => MapEntry(k.toString(), v));
    final promptTokens = (m['prompt_tokens'] as num?)?.toInt() ??
        (m['input_tokens'] as num?)?.toInt() ??
        0;
    final completionTokens = (m['completion_tokens'] as num?)?.toInt() ??
        (m['output_tokens'] as num?)?.toInt() ??
        0;
    final totalTokens = (m['total_tokens'] as num?)?.toInt() ??
        (promptTokens + completionTokens);

    var cacheRead = 0;
    final promptDetails = m['prompt_tokens_details'];
    if (promptDetails is Map) {
      cacheRead = (promptDetails['cached_tokens'] as num?)?.toInt() ?? 0;
    }

    var reasoningTokens = 0;
    final compDetails = m['completion_tokens_details'];
    if (compDetails is Map) {
      reasoningTokens =
          (compDetails['reasoning_tokens'] as num?)?.toInt() ?? 0;
    }

    if (promptTokens <= 0 && completionTokens <= 0 && totalTokens <= 0) {
      return null;
    }
    return TokenUsage(
      inputTokens: promptTokens,
      outputTokens: completionTokens,
      cacheReadTokens: cacheRead,
      thinkingTokens: reasoningTokens,
      totalTokens: totalTokens,
      contextTokens: promptTokens + completionTokens,
    );
  }
}
