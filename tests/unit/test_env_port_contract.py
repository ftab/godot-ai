from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIGURATOR = ROOT / "plugin/addons/godot_ai/client_configurator.gd"
SETTINGS = ROOT / "plugin/addons/godot_ai/utils/settings.gd"
PORT_RESOLVER = ROOT / "plugin/addons/godot_ai/utils/port_resolver.gd"
PLUGIN = ROOT / "plugin/addons/godot_ai/plugin.gd"


def test_client_configurator_declares_port_env_vars():
    text = CONFIGURATOR.read_text(encoding="utf-8")
    assert 'const HTTP_PORT_ENV := "GODOT_AI_HTTP_PORT"' in text
    assert 'const WS_PORT_ENV := "GODOT_AI_WS_PORT"' in text


def test_client_configurator_ports_read_env_before_editor_settings():
    text = CONFIGURATOR.read_text(encoding="utf-8")
    assert "_read_env_or_port_setting(HTTP_PORT_ENV" in text
    assert "_read_env_or_port_setting(WS_PORT_ENV" in text


def test_settings_has_int_env_range_helper():
    text = SETTINGS.read_text(encoding="utf-8")
    assert "static func env_int_in_range" in text
    assert "OS.get_environment" in text
    assert "is_valid_int" in text


def test_port_resolver_supports_agent_scoped_pid_files():
    text = PORT_RESOLVER.read_text(encoding="utf-8")
    assert "static func server_pid_file" in text
    assert "GODOT_AI_AGENT_NAME" in text
    assert "godot_ai_server_%s.pid" in text


def test_spawn_flags_use_dynamic_pid_file_path():
    text = PLUGIN.read_text(encoding="utf-8")
    assert "ProjectSettings.globalize_path(PortResolver.server_pid_file())" in text
