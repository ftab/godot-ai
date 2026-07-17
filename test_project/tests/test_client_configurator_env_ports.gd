@tool
extends McpTestSuite

## Regression coverage for isolated editor lanes. Environment ports must beat
## machine-wide EditorSettings, lifecycle files must be endpoint-scoped, and
## each dock can limit itself to the MCP client(s) assigned to that lane.

const GodotAiPlugin := preload("res://addons/godot_ai/plugin.gd")

var _saved_env: Dictionary = {}
var _saved_settings: Dictionary = {}
var _saved_resolved_ws_port := 0
var _saved_ws_auth_token := ""
var _lane_http_port := 0
var _lane_ws_port := 0
var _http_reservation: TCPServer = null
var _ws_reservation: TCPServer = null
var _skipped_live_lane := false


func suite_name() -> String:
	return "client_configurator_env_ports"


func suite_setup(_ctx: Dictionary) -> void:
	if McpClientConfigurator.isolated_lane_requested():
		## Mutating the process-wide lane env while the real plugin owns a
		## running env lane can redirect its lifecycle callbacks mid-test.
		## Default-lane CI exercises this suite; a live lane run skips safely.
		_skipped_live_lane = true
		skip_suite("env mutation tests do not run inside a live isolated lane")
		return
	for key in _lane_env_keys():
		_saved_env[key] = _save_env(key)
	var es := EditorInterface.get_editor_settings()
	for key in _managed_setting_keys():
		_saved_settings[key] = es.get_setting(key) if es.has_setting(key) else null
	_saved_settings[McpSettings.SETTING_HTTP_PORT] = (
		es.get_setting(McpSettings.SETTING_HTTP_PORT)
		if es.has_setting(McpSettings.SETTING_HTTP_PORT)
		else null
	)
	_saved_settings[McpClientConfigurator.SETTING_WS_PORT] = (
		es.get_setting(McpClientConfigurator.SETTING_WS_PORT)
		if es.has_setting(McpClientConfigurator.SETTING_WS_PORT)
		else null
	)
	_saved_resolved_ws_port = GodotAiPlugin._resolved_ws_port
	_saved_ws_auth_token = GodotAiPlugin._ws_auth_token
	if not _reserve_test_lane_ports():
		fail_setup("could not reserve two unused ports for isolated-lane tests")


func suite_teardown() -> void:
	if _skipped_live_lane:
		return
	_clean_lane_files()
	for key in _saved_env:
		_restore_env(String(key), _saved_env[key])
	McpClientConfigurator.warm_env_snapshot()
	_restore_settings()
	GodotAiPlugin._resolved_ws_port = _saved_resolved_ws_port
	GodotAiPlugin._ws_auth_token = _saved_ws_auth_token
	if _http_reservation != null:
		_http_reservation.stop()
		_http_reservation = null
	if _ws_reservation != null:
		_ws_reservation.stop()
		_ws_reservation = null


func setup() -> void:
	for key in _lane_env_keys():
		OS.unset_environment(key)
	McpClientConfigurator.warm_env_snapshot()
	_restore_settings()
	_clean_lane_files()
	GodotAiPlugin._resolved_ws_port = McpClientConfigurator.DEFAULT_WS_PORT
	GodotAiPlugin._ws_auth_token = ""


func teardown() -> void:
	_clean_lane_files()
	for key in _lane_env_keys():
		OS.unset_environment(key)
	McpClientConfigurator.warm_env_snapshot()
	_restore_settings()
	GodotAiPlugin._resolved_ws_port = _saved_resolved_ws_port
	GodotAiPlugin._ws_auth_token = _saved_ws_auth_token


func test_http_port_prefers_env_over_editor_setting() -> void:
	var es := EditorInterface.get_editor_settings()
	es.set_setting(McpSettings.SETTING_HTTP_PORT, 8123)
	OS.set_environment(McpClientConfigurator.HTTP_PORT_ENV, str(_lane_http_port))
	OS.set_environment(McpClientConfigurator.WS_PORT_ENV, str(_lane_ws_port))
	assert_eq(McpClientConfigurator.http_port(), _lane_http_port)


func test_ws_port_prefers_env_over_editor_setting() -> void:
	var es := EditorInterface.get_editor_settings()
	es.set_setting(McpClientConfigurator.SETTING_WS_PORT, 9123)
	OS.set_environment(McpClientConfigurator.HTTP_PORT_ENV, str(_lane_http_port))
	OS.set_environment(McpClientConfigurator.WS_PORT_ENV, str(_lane_ws_port))
	assert_eq(McpClientConfigurator.ws_port(), _lane_ws_port)


func test_invalid_explicit_lane_fails_closed_instead_of_using_editor_setting() -> void:
	var es := EditorInterface.get_editor_settings()
	es.set_setting(McpSettings.SETTING_HTTP_PORT, 8124)
	OS.set_environment(McpClientConfigurator.HTTP_PORT_ENV, "invalid")
	OS.set_environment(McpClientConfigurator.WS_PORT_ENV, str(_lane_ws_port))
	assert_eq(McpClientConfigurator.http_port(), 0)
	assert_eq(McpClientConfigurator.isolated_lane_http_port(), 0)
	assert_contains(
		McpClientConfigurator.isolated_lane_validation_error(),
		"GODOT_AI_HTTP_PORT",
	)


func test_incomplete_lane_pair_fails_closed() -> void:
	OS.set_environment(McpClientConfigurator.HTTP_PORT_ENV, str(_lane_http_port))
	assert_eq(McpClientConfigurator.ws_port(), 0)
	assert_contains(
		McpClientConfigurator.isolated_lane_validation_error(),
		"require both",
	)


func test_lane_ports_must_be_distinct() -> void:
	OS.set_environment(McpClientConfigurator.HTTP_PORT_ENV, str(_lane_http_port))
	OS.set_environment(McpClientConfigurator.WS_PORT_ENV, str(_lane_http_port))
	assert_contains(
		McpClientConfigurator.isolated_lane_validation_error(),
		"must be different",
	)


func test_http_url_and_lifecycle_paths_use_env_lane() -> void:
	_set_lane_ports()
	assert_eq(
		McpClientConfigurator.http_url(),
		"http://127.0.0.1:%d/mcp" % _lane_http_port,
	)
	assert_eq(
		McpClientConfigurator.server_pid_file(),
		"user://godot_ai_servers/%d/server.pid" % _lane_http_port,
	)
	assert_eq(
		McpClientConfigurator.managed_server_record_file(),
		"user://godot_ai_servers/%d/managed.json" % _lane_http_port,
	)


func test_default_lane_preserves_legacy_lifecycle_paths() -> void:
	assert_eq(McpClientConfigurator.server_pid_file(), McpPortResolver.SERVER_PID_FILE)
	assert_eq(McpClientConfigurator.managed_server_record_file(), "")


func test_spawn_flags_use_isolated_lane_pid_file() -> void:
	_set_lane_ports()
	var flags := GodotAiPlugin._build_server_flags(_lane_http_port, _lane_ws_port)
	var pid_flag := flags.find("--pid-file")
	assert_gt(pid_flag, -1, "spawn flags should include --pid-file")
	assert_eq(
		flags[pid_flag + 1],
		ProjectSettings.globalize_path(McpClientConfigurator.server_pid_file()),
	)


func test_lane_pid_proof_uses_resolved_ws_port_not_raw_env() -> void:
	_set_lane_ports()
	var remapped_ws := _lane_ws_port + 1
	var plugin := GodotAiPlugin.new()
	plugin._set_resolved_ws_port(remapped_ws)
	assert_eq(
		plugin._active_lane_ws_port_for_proof(),
		remapped_ws,
		"Windows WS reservation remaps must remain provable by their real launch flags",
	)
	plugin.free()


func test_isolated_record_round_trips_without_touching_legacy_settings() -> void:
	_set_lane_ports()
	var es := EditorInterface.get_editor_settings()
	es.set_setting(GodotAiPlugin.MANAGED_SERVER_PID_SETTING, 777)
	es.set_setting(GodotAiPlugin.MANAGED_SERVER_VERSION_SETTING, "legacy-sentinel")

	var plugin := GodotAiPlugin.new()
	plugin._set_resolved_ws_port(_lane_ws_port)
	plugin._set_ws_auth_token("lane-secret")
	plugin._write_managed_server_record(12345, "3.0.3")

	var path := McpClientConfigurator.managed_server_record_file()
	var absolute_path := ProjectSettings.globalize_path(path)
	assert_true(FileAccess.file_exists(path), "isolated record should be persisted")
	assert_false(
		FileAccess.file_exists(absolute_path + ".backup"),
		"ephemeral token record must not retain a config-style backup",
	)
	var record := plugin._read_managed_server_record()
	assert_eq(record.get("pid"), 12345)
	assert_eq(record.get("version"), "3.0.3")
	assert_eq(record.get("ws_port"), _lane_ws_port)
	assert_eq(record.get("ws_token"), "lane-secret")
	assert_eq(es.get_setting(GodotAiPlugin.MANAGED_SERVER_PID_SETTING), 777)
	assert_eq(
		es.get_setting(GodotAiPlugin.MANAGED_SERVER_VERSION_SETTING),
		"legacy-sentinel",
	)

	plugin._clear_managed_server_record()
	assert_false(FileAccess.file_exists(path), "clear should remove only this lane's record")
	assert_eq(es.get_setting(GodotAiPlugin.MANAGED_SERVER_PID_SETTING), 777)
	assert_eq(plugin._read_managed_server_record().get("ws_token"), "")
	plugin.free()


func test_isolated_record_rejects_wrong_field_types_without_conversion_errors() -> void:
	_set_lane_ports()
	var path := McpClientConfigurator.managed_server_record_file()
	var absolute_path := ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(absolute_path.get_base_dir())
	var file := FileAccess.open(absolute_path, FileAccess.WRITE)
	assert_true(file != null, "test setup: corrupt record path should be writable")
	if file == null:
		return
	file.store_string(
		JSON.stringify({
			"schema_version": 2,
			"http_port": _lane_http_port,
			"configured_ws_port": _lane_ws_port,
			"pid": ["not", "a", "pid"],
			"version": {"not": "a string"},
			"ws_port": _lane_ws_port,
			"ws_token": ["not", "a", "token"],
		})
	)
	file.close()

	var plugin := GodotAiPlugin.new()
	var record := plugin._read_managed_server_record()
	assert_eq(record.get("pid"), 0)
	assert_eq(record.get("ws_token"), "")
	plugin.free()


func test_same_http_with_different_ws_does_not_claim_or_clear_other_lane_record() -> void:
	_set_lane_ports()
	var plugin := GodotAiPlugin.new()
	plugin._set_resolved_ws_port(_lane_ws_port)
	plugin._set_ws_auth_token("lane-a-secret")
	assert_true(plugin._write_managed_server_record(23456, "3.0.3"))
	var path := McpClientConfigurator.managed_server_record_file()

	OS.set_environment(McpClientConfigurator.WS_PORT_ENV, str(_lane_ws_port + 2))
	var record := plugin._read_managed_server_record()
	assert_eq(record.get("pid"), 0, "different WS config must not inherit lane A ownership")
	assert_true(
		FileAccess.file_exists(path),
		"rejecting the mismatched lane must not clear lane A's live record",
	)
	plugin.free()


func test_scoped_client_ids_defaults_to_all_clients_when_unset() -> void:
	var scoped := McpClientConfigurator.scoped_client_ids()
	assert_true(scoped.has("codex"), "default scope should preserve normal clients")
	assert_true(scoped.has("claude_code"), "default scope should preserve all-client behavior")


func test_scoped_client_ids_uses_explicit_single_client_env() -> void:
	OS.set_environment(McpClientConfigurator.CLIENT_ID_ENV, "codex")
	OS.set_environment(McpClientConfigurator.AGENT_NAME_ENV, "claude_code")
	assert_eq(Array(McpClientConfigurator.scoped_client_ids()), ["codex"])


func test_scoped_client_ids_parses_aliases_and_drops_unknown_entries() -> void:
	OS.set_environment(
		McpClientConfigurator.CLIENT_IDS_ENV,
		"codex; claude-code, definitely-not-a-client",
	)
	assert_eq(
		Array(McpClientConfigurator.scoped_client_ids()),
		["codex", "claude_code"],
	)


func test_scoped_client_ids_can_infer_exact_agent_name() -> void:
	OS.set_environment(McpClientConfigurator.AGENT_NAME_ENV, "Codex")
	assert_eq(Array(McpClientConfigurator.scoped_client_ids()), ["codex"])


func test_unknown_explicit_client_scope_is_empty_not_all_clients() -> void:
	OS.set_environment(McpClientConfigurator.CLIENT_ID_ENV, "definitely-not-a-client")
	assert_eq(Array(McpClientConfigurator.scoped_client_ids()), [])


func _set_lane_ports() -> void:
	OS.set_environment(McpClientConfigurator.HTTP_PORT_ENV, str(_lane_http_port))
	OS.set_environment(McpClientConfigurator.WS_PORT_ENV, str(_lane_ws_port))


func _lane_env_keys() -> PackedStringArray:
	return PackedStringArray([
		McpClientConfigurator.HTTP_PORT_ENV,
		McpClientConfigurator.WS_PORT_ENV,
		McpClientConfigurator.CLIENT_ID_ENV,
		McpClientConfigurator.CLIENT_IDS_ENV,
		McpClientConfigurator.AGENT_NAME_ENV,
	])


func _managed_setting_keys() -> PackedStringArray:
	return PackedStringArray([
		GodotAiPlugin.MANAGED_SERVER_PID_SETTING,
		GodotAiPlugin.MANAGED_SERVER_VERSION_SETTING,
		GodotAiPlugin.MANAGED_SERVER_WS_PORT_SETTING,
		GodotAiPlugin.MANAGED_SERVER_WS_TOKEN_SETTING,
	])


func _restore_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	for key in _saved_settings:
		es.set_setting(String(key), _saved_settings[key])


func _clean_lane_files() -> void:
	if _lane_http_port <= 0:
		return
	var record_path := ProjectSettings.globalize_path(
		"user://godot_ai_servers/%d/managed.json" % _lane_http_port
	)
	var pid_path := ProjectSettings.globalize_path(
		McpPortResolver.server_pid_file(_lane_http_port)
	)
	for path in [record_path, record_path + ".backup", pid_path]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _reserve_test_lane_ports() -> bool:
	var start := 30000 + (OS.get_process_id() % 20000)
	for offset in range(2048):
		var candidate := 30000 + ((start - 30000 + offset) % 30000)
		if _lane_state_exists(candidate):
			continue
		var reservation := TCPServer.new()
		if reservation.listen(candidate, "127.0.0.1") != OK:
			continue
		_lane_http_port = candidate
		_http_reservation = reservation
		break
	if _lane_http_port <= 0:
		return false

	for offset in range(2048):
		var candidate := 30000 + ((_lane_http_port - 30000 + 4096 + offset) % 30000)
		if candidate == _lane_http_port:
			continue
		var reservation := TCPServer.new()
		if reservation.listen(candidate, "127.0.0.1") != OK:
			continue
		_lane_ws_port = candidate
		_ws_reservation = reservation
		break
	return _lane_ws_port > 0


func _lane_state_exists(port: int) -> bool:
	var base := ProjectSettings.globalize_path(
		"user://godot_ai_servers/%d" % port
	)
	return (
		FileAccess.file_exists(base.path_join("managed.json"))
		or FileAccess.file_exists(base.path_join("managed.json.backup"))
		or FileAccess.file_exists(base.path_join("server.pid"))
	)


func _save_env(name: String) -> Variant:
	return OS.get_environment(name) if OS.has_environment(name) else null


func _restore_env(name: String, saved: Variant) -> void:
	if saved == null:
		OS.unset_environment(name)
	else:
		OS.set_environment(name, str(saved))
