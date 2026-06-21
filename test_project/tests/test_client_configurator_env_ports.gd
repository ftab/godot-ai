@tool
extends McpTestSuite

## Regression tests for multi-editor launches: per-process environment ports
## must override shared EditorSettings so separate Godot editor instances can
## run separate godot-ai servers from separate project clones.

var _saved_http_env: Variant = null
var _saved_ws_env: Variant = null
var _saved_client_id_env: Variant = null
var _saved_client_ids_env: Variant = null
var _saved_agent_name_env: Variant = null
var _saved_http_setting: Variant = null
var _saved_ws_setting: Variant = null


func suite_name() -> String:
	return "client_configurator_env_ports"


func suite_setup(_ctx: Dictionary) -> void:
	_saved_http_env = OS.get_environment(McpClientConfigurator.HTTP_PORT_ENV) if OS.has_environment(McpClientConfigurator.HTTP_PORT_ENV) else null
	_saved_ws_env = OS.get_environment(McpClientConfigurator.WS_PORT_ENV) if OS.has_environment(McpClientConfigurator.WS_PORT_ENV) else null
	_saved_client_id_env = _save_env(McpClientConfigurator.CLIENT_ID_ENV)
	_saved_client_ids_env = _save_env(McpClientConfigurator.CLIENT_IDS_ENV)
	_saved_agent_name_env = _save_env("GODOT_AI_AGENT_NAME")
	var es := EditorInterface.get_editor_settings()
	_saved_http_setting = es.get_setting(McpSettings.SETTING_HTTP_PORT) if es.has_setting(McpSettings.SETTING_HTTP_PORT) else null
	_saved_ws_setting = es.get_setting(McpClientConfigurator.SETTING_WS_PORT) if es.has_setting(McpClientConfigurator.SETTING_WS_PORT) else null


func suite_teardown() -> void:
	_restore_env(McpClientConfigurator.HTTP_PORT_ENV, _saved_http_env)
	_restore_env(McpClientConfigurator.WS_PORT_ENV, _saved_ws_env)
	_restore_env(McpClientConfigurator.CLIENT_ID_ENV, _saved_client_id_env)
	_restore_env(McpClientConfigurator.CLIENT_IDS_ENV, _saved_client_ids_env)
	_restore_env("GODOT_AI_AGENT_NAME", _saved_agent_name_env)
	var es := EditorInterface.get_editor_settings()
	es.set_setting(McpSettings.SETTING_HTTP_PORT, _saved_http_setting)
	es.set_setting(McpClientConfigurator.SETTING_WS_PORT, _saved_ws_setting)


func test_http_port_prefers_env_over_editor_setting() -> void:
	var es := EditorInterface.get_editor_settings()
	es.set_setting(McpSettings.SETTING_HTTP_PORT, 8123)
	OS.set_environment(McpClientConfigurator.HTTP_PORT_ENV, "18000")
	assert_eq(McpClientConfigurator.http_port(), 18000)


func test_ws_port_prefers_env_over_editor_setting() -> void:
	var es := EditorInterface.get_editor_settings()
	es.set_setting(McpClientConfigurator.SETTING_WS_PORT, 9123)
	OS.set_environment(McpClientConfigurator.WS_PORT_ENV, "19500")
	assert_eq(McpClientConfigurator.ws_port(), 19500)


func test_invalid_env_port_falls_back_to_editor_setting() -> void:
	var es := EditorInterface.get_editor_settings()
	es.set_setting(McpSettings.SETTING_HTTP_PORT, 8124)
	OS.set_environment(McpClientConfigurator.HTTP_PORT_ENV, "invalid")
	assert_eq(McpClientConfigurator.http_port(), 8124)


func test_http_url_uses_env_http_port() -> void:
	OS.set_environment(McpClientConfigurator.HTTP_PORT_ENV, "18002")
	assert_eq(McpClientConfigurator.http_url(), "http://127.0.0.1:18002/mcp")



func test_scoped_client_ids_defaults_to_all_clients_when_unset() -> void:
	var saved_id: Variant = _save_env(McpClientConfigurator.CLIENT_ID_ENV)
	var saved_ids: Variant = _save_env(McpClientConfigurator.CLIENT_IDS_ENV)
	var saved_agent: Variant = _save_env("GODOT_AI_AGENT_NAME")
	OS.unset_environment(McpClientConfigurator.CLIENT_ID_ENV)
	OS.unset_environment(McpClientConfigurator.CLIENT_IDS_ENV)
	OS.unset_environment("GODOT_AI_AGENT_NAME")
	var scoped := McpClientConfigurator.scoped_client_ids()
	assert_true(scoped.has("codex"), "default scope should include normal clients")
	assert_true(scoped.has("claude_code"), "default scope should preserve existing all-client behavior")
	_restore_env(McpClientConfigurator.CLIENT_ID_ENV, saved_id)
	_restore_env(McpClientConfigurator.CLIENT_IDS_ENV, saved_ids)
	_restore_env("GODOT_AI_AGENT_NAME", saved_agent)


func test_scoped_client_ids_uses_explicit_single_client_env() -> void:
	var saved_id: Variant = _save_env(McpClientConfigurator.CLIENT_ID_ENV)
	var saved_ids: Variant = _save_env(McpClientConfigurator.CLIENT_IDS_ENV)
	var saved_agent: Variant = _save_env("GODOT_AI_AGENT_NAME")
	OS.set_environment(McpClientConfigurator.CLIENT_ID_ENV, "codex")
	OS.unset_environment(McpClientConfigurator.CLIENT_IDS_ENV)
	OS.set_environment("GODOT_AI_AGENT_NAME", "claude_code")
	assert_eq(Array(McpClientConfigurator.scoped_client_ids()), ["codex"])
	_restore_env(McpClientConfigurator.CLIENT_ID_ENV, saved_id)
	_restore_env(McpClientConfigurator.CLIENT_IDS_ENV, saved_ids)
	_restore_env("GODOT_AI_AGENT_NAME", saved_agent)


func test_scoped_client_ids_parses_aliases_and_ignores_unknown_without_falling_back() -> void:
	var saved_id: Variant = _save_env(McpClientConfigurator.CLIENT_ID_ENV)
	var saved_ids: Variant = _save_env(McpClientConfigurator.CLIENT_IDS_ENV)
	var saved_agent: Variant = _save_env("GODOT_AI_AGENT_NAME")
	OS.unset_environment(McpClientConfigurator.CLIENT_ID_ENV)
	OS.set_environment(McpClientConfigurator.CLIENT_IDS_ENV, "codex, claude-code, definitely-not-a-client")
	OS.unset_environment("GODOT_AI_AGENT_NAME")
	assert_eq(Array(McpClientConfigurator.scoped_client_ids()), ["codex", "claude_code"])
	_restore_env(McpClientConfigurator.CLIENT_ID_ENV, saved_id)
	_restore_env(McpClientConfigurator.CLIENT_IDS_ENV, saved_ids)
	_restore_env("GODOT_AI_AGENT_NAME", saved_agent)


func test_scoped_client_ids_can_infer_from_matching_agent_name() -> void:
	var saved_id: Variant = _save_env(McpClientConfigurator.CLIENT_ID_ENV)
	var saved_ids: Variant = _save_env(McpClientConfigurator.CLIENT_IDS_ENV)
	var saved_agent: Variant = _save_env("GODOT_AI_AGENT_NAME")
	OS.unset_environment(McpClientConfigurator.CLIENT_ID_ENV)
	OS.unset_environment(McpClientConfigurator.CLIENT_IDS_ENV)
	OS.set_environment("GODOT_AI_AGENT_NAME", "codex")
	assert_eq(Array(McpClientConfigurator.scoped_client_ids()), ["codex"])
	_restore_env(McpClientConfigurator.CLIENT_ID_ENV, saved_id)
	_restore_env(McpClientConfigurator.CLIENT_IDS_ENV, saved_ids)
	_restore_env("GODOT_AI_AGENT_NAME", saved_agent)


func test_scoped_client_ids_unknown_explicit_env_returns_empty_not_all_clients() -> void:
	var saved_id: Variant = _save_env(McpClientConfigurator.CLIENT_ID_ENV)
	var saved_ids: Variant = _save_env(McpClientConfigurator.CLIENT_IDS_ENV)
	var saved_agent: Variant = _save_env("GODOT_AI_AGENT_NAME")
	OS.set_environment(McpClientConfigurator.CLIENT_ID_ENV, "definitely-not-a-client")
	OS.unset_environment(McpClientConfigurator.CLIENT_IDS_ENV)
	OS.unset_environment("GODOT_AI_AGENT_NAME")
	assert_eq(Array(McpClientConfigurator.scoped_client_ids()), [])
	_restore_env(McpClientConfigurator.CLIENT_ID_ENV, saved_id)
	_restore_env(McpClientConfigurator.CLIENT_IDS_ENV, saved_ids)
	_restore_env("GODOT_AI_AGENT_NAME", saved_agent)


func _save_env(name: String) -> Variant:
	return OS.get_environment(name) if OS.has_environment(name) else null


func _restore_env(name: String, saved: Variant) -> void:
	if saved == null:
		OS.unset_environment(name)
	else:
		OS.set_environment(name, str(saved))
