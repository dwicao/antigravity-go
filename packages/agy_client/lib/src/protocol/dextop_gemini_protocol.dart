import 'dart:convert';

class DextopTextToolCall {
  const DextopTextToolCall({
    required this.name,
    required this.arguments,
    required this.rawJson,
  });

  final String name;
  final Map<String, dynamic> arguments;
  final String rawJson;
}

/// Pure-Dart prompt & `<tool_call>` codec for driving Dextop's `gemini_web_prompt`
/// MCP tool as an agentic coding backend inside Antigravity Go.
class DextopGeminiProtocol {
  const DextopGeminiProtocol._();

  static final RegExp _tagRegex = RegExp(
    r'<(?:tool_call|mcp_call)>\s*(\{[\s\S]*?\})\s*</(?:tool_call|mcp_call)>',
    caseSensitive: false,
  );

  static final RegExp _fenceRegex = RegExp(
    r'```(?:tool_call|mcp_call)\s*\r?\n(\{[\s\S]*?\})\s*```',
    caseSensitive: false,
  );

  static final RegExp _genericToolJsonFenceRegex = RegExp(
    r'```json\s*\r?\n(\{[\s\S]*?"(?:name|tool)"\s*:\s*"(?:run_command|read_file|edit_file|write_file|list_dir|search_files|inspect_var|delegate_subagent)"[\s\S]*?\})\s*```',
    caseSensitive: false,
  );

  static ({List<DextopTextToolCall> calls, String visibleText}) parseToolCalls(
    String replyText,
  ) {
    if (replyText.trim().isEmpty) {
      return (calls: const [], visibleText: '');
    }

    final calls = <DextopTextToolCall>[];
    final spansToStrip = <({int start, int end})>[];

    void scan(RegExp re) {
      for (final match in re.allMatches(replyText)) {
        final rawJson = match.group(1)?.trim() ?? '';
        if (rawJson.isEmpty) continue;
        // Skip overlapping matches already captured cleanly.
        if (spansToStrip.any(
          (s) => match.start < s.end && match.end > s.start,
        )) {
          continue;
        }
        try {
          final decoded = jsonDecode(rawJson);
          if (decoded is! Map) continue;
          final map = decoded.cast<String, dynamic>();
          final toolName =
              (map['name'] ?? map['tool'] ?? '').toString().trim();
          if (toolName.isEmpty) continue;
          final rawArgs = map['arguments'] ?? map['args'];
          final args = rawArgs is Map
              ? rawArgs.cast<String, dynamic>()
              : <String, dynamic>{};
          calls.add(
            DextopTextToolCall(name: toolName, arguments: args, rawJson: rawJson),
          );
          spansToStrip.add((start: match.start, end: match.end));
        } catch (_) {}
      }
    }

    scan(_tagRegex);
    scan(_fenceRegex);
    scan(_genericToolJsonFenceRegex);

    if (spansToStrip.isEmpty) {
      return (calls: calls, visibleText: replyText.trim());
    }

    spansToStrip.sort((a, b) => a.start.compareTo(b.start));
    final visible = StringBuffer();
    var cursor = 0;
    for (final span in spansToStrip) {
      if (span.start > cursor) {
        visible.write(replyText.substring(cursor, span.start));
      }
      cursor = span.end;
    }
    if (cursor < replyText.length) {
      visible.write(replyText.substring(cursor));
    }

    return (
      calls: calls,
      visibleText: visible.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n').trim(),
    );
  }

  static String buildInitialPrompt({
    required String systemInstructions,
    required List<Map<String, String>> trimmedHistory,
    required String userPrompt,
    required bool supportsTools,
    bool includeVariables = true,
    bool includeSubagent = true,
  }) {
    final buf = StringBuffer();
    if (systemInstructions.trim().isNotEmpty) {
      buf.writeln('<antigravity_agent_system>');
      buf.writeln(systemInstructions.trim());
      if (supportsTools) {
        buf.writeln();
        buf.writeln('Tool Call Format (STRICT):');
        buf.writeln(
          'To invoke a tool, emit one or more blocks using EXACTLY:',
        );
        buf.writeln(
          '<tool_call>{"name":"TOOL_NAME","arguments":{...}}</tool_call>',
        );
        buf.writeln('Available tool names & required parameters:');
        buf.writeln('- read_file: {"path": "...", "start_line"?: int, "limit"?: int, "force_reread"?: bool}');
        buf.writeln('- edit_file: {"path": "...", "old_string": "...", "new_string": "..."}');
        buf.writeln('- write_file: {"path": "...", "content": "..."}');
        buf.writeln('- list_dir: {"path"?: "...", "max_depth"?: int}');
        buf.writeln('- search_files: {"pattern": "...", "path"?: "..."}');
        buf.writeln('- run_command: {"command": "...", "cwd"?: "..."}');
        if (includeVariables) {
          buf.writeln('- inspect_var: {"name": "...", "start_line"?: int, "limit"?: int, "grep"?: "..."}');
        }
        if (includeSubagent) {
          buf.writeln('- delegate_subagent: {"role": "...", "task": "..."}');
        }
        buf.writeln(
          'Wait for <tool_results> before assuming tool output. When done, respond normally without any <tool_call>.',
        );
      }
      buf.writeln('</antigravity_agent_system>');
      buf.writeln();
    }

    if (trimmedHistory.isNotEmpty) {
      buf.writeln('<conversation_context>');
      for (final m in trimmedHistory) {
        final roleLabel = m['role'] == 'assistant' ? 'Assistant' : 'User';
        buf.writeln('[$roleLabel]');
        buf.writeln(m['content'] ?? '');
        buf.writeln();
      }
      buf.writeln('</conversation_context>');
      buf.writeln();
    }

    buf.write(userPrompt.trim());
    return buf.toString().trim();
  }

  static String buildToolResultsDeltaPrompt(
    List<({String callId, String name, String content})> results,
  ) {
    final buf = StringBuffer('<tool_results>\n');
    for (final r in results) {
      buf.writeln('<tool_result id="${r.callId}" name="${r.name}">');
      buf.writeln(r.content);
      buf.writeln('</tool_result>');
    }
    buf.writeln('</tool_results>');
    buf.writeln(
      'Continue completing the user task. Output the next <tool_call>...</tool_call> if more actions are needed, or present your verified final answer.',
    );
    return buf.toString();
  }

  /// Extracts decoded JSON payload or text returned by Dextop's `tools/call`.
  static ({bool ok, String replyText, String? error, bool streamingComplete})
      parseDextopGeminiResponse(Map<String, dynamic> rpcJson) {
    final rpcErr = rpcJson['error'];
    if (rpcErr != null) {
      return (
        ok: false,
        replyText: '',
        error: rpcErr is Map ? (rpcErr['message']?.toString() ?? rpcErr.toString()) : rpcErr.toString(),
        streamingComplete: false,
      );
    }

    final result = (rpcJson['result'] as Map?)?.cast<String, dynamic>();
    if (result == null) {
      return (
        ok: false,
        replyText: '',
        error: 'Empty MCP result from Dextop',
        streamingComplete: false,
      );
    }

    final isError = result['isError'] == true;
    final contentList = result['content'] as List? ?? const [];
    final rawText = contentList
        .whereType<Map>()
        .map((c) => c['text']?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .join('\n')
        .trim();

    if (rawText.startsWith('{')) {
      try {
        final decoded = jsonDecode(rawText);
        if (decoded is Map) {
          final map = decoded.cast<String, dynamic>();
          final payloadOk = map['ok'] != false && !isError;
          final reply = map['replyText']?.toString() ?? '';
          final err = map['error']?.toString();
          final complete = map['streamingComplete'] == true;
          return (
            ok: payloadOk,
            replyText: reply,
            error: payloadOk ? null : (err ?? rawText),
            streamingComplete: complete,
          );
        }
      } catch (_) {}
    }

    return (
      ok: !isError && rawText.isNotEmpty,
      replyText: isError ? '' : rawText,
      error: isError ? (rawText.isNotEmpty ? rawText : 'Gemini Web tool error') : null,
      streamingComplete: true,
    );
  }
}
