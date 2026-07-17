"""Cross-file contract for isolated multi-editor server lanes.

Behavior is exercised by the GDScript suites. These checks keep the wiring
visible to normal Python CI too: a future refactor must not retain the env
surface while silently routing lifecycle reads back to the legacy shared
record or an unsafe worker-thread getenv.
"""

from __future__ import annotations

from pathlib import Path

from tests.unit._gdscript_text import get_func_block

ROOT = Path(__file__).resolve().parents[2]
CONFIGURATOR = (ROOT / "plugin/addons/godot_ai/client_configurator.gd").read_text(encoding="utf-8")
PATH_TEMPLATE = (ROOT / "plugin/addons/godot_ai/clients/_path_template.gd").read_text(
    encoding="utf-8"
)
PORT_RESOLVER = (ROOT / "plugin/addons/godot_ai/utils/port_resolver.gd").read_text(encoding="utf-8")
PLUGIN = (ROOT / "plugin/addons/godot_ai/plugin.gd").read_text(encoding="utf-8")
LIFECYCLE = (ROOT / "plugin/addons/godot_ai/utils/server_lifecycle.gd").read_text(encoding="utf-8")
ATOMIC_WRITE = (ROOT / "plugin/addons/godot_ai/clients/_atomic_write.gd").read_text(
    encoding="utf-8"
)
DOCK = (ROOT / "plugin/addons/godot_ai/mcp_dock.gd").read_text(encoding="utf-8")
CONNECTION = (ROOT / "plugin/addons/godot_ai/connection.gd").read_text(encoding="utf-8")


def test_port_envs_override_editor_settings_through_safe_snapshot() -> None:
    assert 'const HTTP_PORT_ENV := "GODOT_AI_HTTP_PORT"' in CONFIGURATOR
    assert 'const WS_PORT_ENV := "GODOT_AI_WS_PORT"' in CONFIGURATOR
    assert "_read_env_or_port_setting(HTTP_PORT_ENV" in CONFIGURATOR
    assert "_read_env_or_port_setting(WS_PORT_ENV" in CONFIGURATOR

    env_reader = get_func_block(CONFIGURATOR, "static func _read_env_port(env_key: String) -> int:")
    raw_env = get_func_block(CONFIGURATOR, "static func _raw_env(env_key: String) -> String:")
    assert "_raw_env(env_key)" in env_reader
    assert "McpPathTemplate.env_lookup(env_key)" in raw_env
    assert "\tvar raw := OS.get_environment" not in env_reader
    for name in (
        "GODOT_AI_HTTP_PORT",
        "GODOT_AI_WS_PORT",
        "GODOT_AI_CLIENT_ID",
        "GODOT_AI_CLIENT_IDS",
        "GODOT_AI_AGENT_NAME",
    ):
        assert f'"{name}"' in PATH_TEMPLATE


def test_pid_and_managed_record_paths_are_scoped_by_http_lane() -> None:
    pid_path = get_func_block(
        PORT_RESOLVER, "static func server_pid_file(lane_http_port: int = 0) -> String:"
    )
    assert "godot_ai_servers" in PORT_RESOLVER
    assert "lane_http_port" in pid_path
    assert "server.pid" in pid_path

    record_path = get_func_block(
        CONFIGURATOR, "static func managed_server_record_file() -> String:"
    )
    assert "isolated_lane_http_port()" in record_path
    assert "managed.json" in record_path


def test_spawn_health_and_cleanup_all_use_the_lane_pid_path() -> None:
    build_flags = get_func_block(
        PLUGIN, "static func _build_server_flags(port: int, ws_port: int) -> Array[String]:"
    )
    assert "ClientConfigurator.server_pid_file()" in build_flags

    read_pid = get_func_block(PLUGIN, "static func _read_pid_file() -> int:")
    clear_pid = get_func_block(PLUGIN, "static func _clear_pid_file() -> void:")
    assert "ClientConfigurator.isolated_lane_http_port()" in read_pid
    assert "ClientConfigurator.isolated_lane_http_port()" in clear_pid

    health = get_func_block(LIFECYCLE, "func check_server_health() -> void:")
    assert "_host._read_pid_file_for_lifecycle()" in health
    assert "PortResolver.read_pid_file()" not in health


def test_isolated_record_persists_token_outside_editor_settings() -> None:
    read_record = get_func_block(PLUGIN, "func _read_managed_server_record() -> Dictionary:")
    write_record = get_func_block(
        PLUGIN, "func _write_managed_server_record(pid: int, version: String) -> bool:"
    )
    clear_record = get_func_block(PLUGIN, "func _clear_managed_server_record() -> void:")
    lane_writer = get_func_block(
        PLUGIN,
        "func _write_lane_managed_server_record(path: String, pid: int, version: String) -> bool:",
    )

    assert "managed_server_record_file()" in read_record
    assert "managed_server_record_file()" in write_record
    assert "managed_server_record_file()" in clear_record
    assert "AtomicWrite.write" in lane_writer
    assert '"ws_token": _ws_auth_token' in lane_writer
    assert '"schema_version": 2' in lane_writer
    assert '"configured_ws_port": ClientConfigurator.ws_port()' in lane_writer
    assert '".backup"' in lane_writer
    assert "_remove_lane_managed_server_record_files" in lane_writer


def test_invalid_or_incomplete_lane_configuration_fails_closed() -> None:
    validation = get_func_block(
        CONFIGURATOR,
        "static func isolated_lane_validation_error() -> String:",
    )
    assert "both GODOT_AI_HTTP_PORT" in validation
    assert "must be different" in validation

    start = get_func_block(LIFECYCLE, "func _start_server_impl(async_gen: int) -> void:")
    assert "isolated_lane_validation_error()" in start
    assert "set_terminal_diagnosis(McpServerStateScript.CRASHED)" in start

    for signature in (
        "func _read_managed_server_record() -> Dictionary:",
        "func _write_managed_server_record(pid: int, version: String) -> bool:",
        "func _clear_managed_server_record() -> void:",
    ):
        block = get_func_block(PLUGIN, signature)
        assert "isolated_lane_validation_error()" in block


def test_client_status_surface_uses_scoped_ids() -> None:
    handler = (ROOT / "plugin/addons/godot_ai/handlers/client_handler.gd").read_text(
        encoding="utf-8"
    )
    dock = (ROOT / "plugin/addons/godot_ai/mcp_dock.gd").read_text(encoding="utf-8")
    status = get_func_block(handler, "func check_client_status(_params: Dictionary) -> Dictionary:")
    build = get_func_block(dock, "func _build_ui() -> void:")
    assert "McpClientConfigurator.scoped_client_ids()" in status
    assert "ClientConfigurator.scoped_client_ids()" in build


def test_lane_ownership_requires_exact_process_launch_ports() -> None:
    lane_match = get_func_block(
        PLUGIN,
        (
            "static func _commandline_matches_server_lane("
            "cmd: String, http_port: int, ws_port: int) -> bool:"
        ),
    )
    assert '"--port"' in lane_match
    assert '"--ws-port"' in lane_match

    find_pid = get_func_block(PLUGIN, "func _find_managed_pid(port: int) -> int:")
    assert "_pid_cmdline_is_godot_ai_for_proof(pid)" in find_pid
    assert "ClientConfigurator.isolated_lane_requested()" in find_pid
    assert "\t\treturn 0" in find_pid

    active_ws = get_func_block(
        PLUGIN,
        "func _active_lane_ws_port_for_proof() -> int:",
    )
    assert "_read_managed_server_record()" in active_ws
    assert "_resolved_ws_port" in active_ws


def test_isolated_recovery_never_falls_back_to_status_name_proof() -> None:
    recovery = get_func_block(
        PLUGIN,
        (
            "func _evaluate_recovery_port_occupant_proof("
            "\n\tport: int, live: Dictionary = {}, record_override: Dictionary = {}"
            "\n) -> Dictionary:"
        ),
    )
    lane_guard = recovery.index("if ClientConfigurator.isolated_lane_requested():")
    status_fallback = recovery.index("_live_status_identifies_godot_ai(current_live)")
    assert lane_guard < status_fallback
    assert 'return {"proof": "", "pids": []}' in recovery[lane_guard:status_fallback]


def test_isolated_explicit_restart_filters_to_exact_lane_ownership() -> None:
    restart = get_func_block(
        PLUGIN,
        "func force_restart_or_start_dev_server() -> bool:",
    )
    assert "if ClientConfigurator.isolated_lane_requested():" in restart
    assert "_pid_cmdline_is_godot_ai_for_proof(candidate)" in restart
    assert "refusing to restart it without exact HTTP/WS ownership proof" in restart
    proof = restart.index("if candidates.is_empty():")
    reset = restart.index("_lifecycle.reset_for_force_restart()", proof)
    assert proof < reset


def test_sensitive_atomic_temp_is_chmodded_closed_before_write() -> None:
    write = get_func_block(
        ATOMIC_WRITE,
        "static func write(path: String, content: String) -> bool:",
    )
    close_at = write.index("file.close()")
    chmod_at = write.index("if not _apply_mode(tmp_path, target_mode):")
    reopen_at = write.index("FileAccess.open(tmp_path, FileAccess.READ_WRITE)")
    store_at = write.index("file.store_string(content)")
    assert close_at < chmod_at < reopen_at < store_at


def test_atomic_copy_fallback_fails_when_final_mode_cannot_be_secured() -> None:
    write = get_func_block(
        ATOMIC_WRITE,
        "static func write(path: String, content: String) -> bool:",
    )
    fallback = write[write.index("if DirAccess.copy_absolute(tmp_path, path) == OK") :]
    success = fallback[: fallback.index("# Copy didn't land cleanly")]
    assert "if _apply_mode(path, target_mode):" in success
    assert "return true" in success
    assert "\t\t_apply_mode(path, target_mode)\n" not in success


def test_env_lane_collision_ui_does_not_write_ignored_editor_setting() -> None:
    panel = get_func_block(
        DOCK,
        "func _update_crash_panel(server_status: Dictionary) -> void:",
    )
    apply = get_func_block(
        DOCK,
        "func _on_port_apply_requested(new_port: int) -> void:",
    )
    hint = get_func_block(DOCK, "static func _free_port_hint(port: int) -> String:")
    assert "not ClientConfigurator.isolated_lane_requested()" in panel
    assert "ClientConfigurator.isolated_lane_requested()" in apply
    assert "GODOT_AI_HTTP_PORT" in hint
    assert "GODOT_AI_WS_PORT" in hint


def test_connection_waits_for_a_server_specific_start_outcome() -> None:
    enter = get_func_block(PLUGIN, "func _enter_tree() -> void:")
    assert enter.index("_set_resolved_ws_port(lane_ws_port)") < enter.index(
        "_connection = Connection.new()"
    )
    assert "var server_start_pending: bool" in enter
    assert "ServerStateScript.SPAWNING" in enter
    assert "ServerStateScript.READY" in enter
    assert "Resolving Godot AI server before connecting" in enter
    assert "Resolving isolated Godot AI lane before connecting" in enter

    ready = get_func_block(CONNECTION, "func _ready() -> void:")
    assert ready.index("if connect_blocked:") < ready.index("_connect_to_server()")
    assert "set_process(false)" in ready

    resume = get_func_block(CONNECTION, "func resume_connecting() -> void:")
    assert "connect_blocked = false" in resume
    assert "_peer = WebSocketPeer.new()" in resume
    assert "_connect_to_server()" in resume


def test_free_http_lane_preflights_ws_before_command_discovery_or_spawn() -> None:
    start = get_func_block(LIFECYCLE, "func _start_server_impl(async_gen: int) -> void:")
    preflight = start.index("_host._is_port_in_use(ws_port)")
    assert preflight < start.index("ClientConfigurator.get_server_command()")
    assert preflight < start.index("OS.create_process(cmd, args)")
    assert "_ws_port_in_use_message(ws_port)" in start
    assert "McpServerStateScript.FOREIGN_PORT" in start
    assert "_block_isolated_lane_connection(_server_status_message)" in start


def test_guarded_lane_requires_live_http_version_and_ws_proof() -> None:
    start = get_func_block(LIFECYCLE, "func _start_server_impl(async_gen: int) -> void:")
    guarded = start[start.index("if _host._server_started_this_session") :]
    assert "_host._probe_live_server_status_for_port(port)" in guarded
    assert "_server_status_compatibility(" in guarded
    assert "transition_state(McpServerStateScript.READY)" in guarded
    assert "_host._resume_connection_after_lane_start()" in guarded
    assert "transition_state(McpServerStateScript.GUARDED)" in guarded
    assert "_block_isolated_lane_connection(" in guarded


def test_invalid_lane_cannot_use_dev_server_escape_hatches() -> None:
    for signature in (
        "func force_restart_or_start_dev_server() -> bool:",
        "func start_dev_server() -> void:",
        "func stop_dev_server() -> void:",
    ):
        block = get_func_block(PLUGIN, signature)
        assert "isolated_lane_validation_error()" in block

    explicit_resume = get_func_block(
        PLUGIN, "func _resume_connection_after_explicit_server_start() -> void:"
    )
    start_dev = get_func_block(PLUGIN, "func start_dev_server() -> void:")
    assert "resume_connecting()" in explicit_resume
    assert "_arm_server_version_check()" in explicit_resume
    assert "_resume_connection_after_explicit_server_start()" in start_dev

    dock_update = get_func_block(DOCK, "func _update_dev_section_buttons() -> void:")
    assert "isolated_lane_validation_error()" in dock_update
    assert "Invalid Server Lane" in dock_update
