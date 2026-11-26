/// Pure Dart client, ACP/stream-json protocol parsers, model catalog, and
/// quota/usage ledger for Google Antigravity CLI (`agy`).
library;

export 'src/models/agy_cli_catalog.dart';
export 'src/models/agy_model.dart';
export 'src/models/auth_status.dart';
export 'src/models/automation_task.dart';
export 'src/models/chat_event.dart';
export 'src/models/customization_item.dart';
export 'src/models/diff_hunk.dart';
export 'src/models/execution_mode.dart';
export 'src/models/openai_provider_config.dart';
export 'src/models/permission_preset.dart';
export 'src/models/project_info.dart';
export 'src/models/session_info.dart';
export 'src/models/unified_line_diff.dart';
export 'src/models/usage_quota.dart';
export 'src/mcp/mcp_http_client.dart';
export 'src/protocol/acp_codec.dart';
export 'src/protocol/openai_sse_parser.dart';
export 'src/protocol/stream_json_parser.dart';
export 'src/protocol/usage_output_parser.dart';
export 'src/transport/agy_transport.dart';
export 'src/usage/model_pricing.dart';
export 'src/usage/usage_ledger.dart';
export 'src/voice/voice_prompt_normalizer.dart';
export 'src/harness/harness_engine.dart';
export 'src/harness/lifecycle_hooks.dart';
export 'src/harness/repo_map_builder.dart';
