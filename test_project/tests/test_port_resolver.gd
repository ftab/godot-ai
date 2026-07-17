@tool
extends McpTestSuite

## Direct coverage for McpPortResolver. Pure parsers are also exercised
## indirectly via plugin.gd shims in test_netstat_parser.gd /
## test_plugin_lifecycle.gd; this suite focuses on (a) live OS smoke
## that the parsers can't reach and (b) seam smoke proving the new
## `class_name` is callable from outside plugin.gd.


func suite_name() -> String:
	return "port_resolver"


# ----- seam smoke (proves the class_name is reachable) ----------------

func test_parser_seam_callable_directly() -> void:
	var pid := McpPortResolver.parse_windows_netstat_pid(
		"  TCP  0.0.0.0:8000  0.0.0.0:0  LISTENING  57865\n", 8000
	)
	assert_eq(pid, 57865)


func test_resolved_ws_port_seam_callable_directly() -> void:
	## Stale record version drops cached ws_port — pure logic, locked in
	## end-to-end by test_plugin_lifecycle.gd; here only as a seam check.
	assert_eq(
		McpPortResolver.resolved_ws_port_for_existing_server(9500, "2.1.0", "2.2.0", 10500),
		10500
	)


# ----- live OS smoke (genuinely new coverage) -------------------------

func test_can_bind_local_port_succeeds_on_free_port() -> void:
	var port := 51247
	var probe := TCPServer.new()
	if probe.listen(port, "127.0.0.1") != OK:
		skip("port %d is already held on this host" % port)
		return
	probe.stop()
	assert_true(McpPortResolver.can_bind_local_port(port))


func test_can_bind_local_port_returns_false_when_held() -> void:
	var port := 51248
	var holder := TCPServer.new()
	if holder.listen(port, "127.0.0.1") != OK:
		skip("could not seize port for held-port assertion")
		return
	var got_bind := McpPortResolver.can_bind_local_port(port)
	holder.stop()
	assert_false(got_bind)


func test_is_port_in_use_checks_os_listeners_after_bind_probe_on_posix() -> void:
	if OS.get_name() == "Windows":
		skip("POSIX-only lsof confirmation")
		return
	var python_check: Array = []
	if OS.execute("python3", ["--version"], python_check, true) != 0:
		skip("python3 is unavailable for live listener smoke")
		return

	var port := 51249
	var probe := TCPServer.new()
	if probe.listen(port, "127.0.0.1") != OK:
		skip("port %d is already held on this host" % port)
		return
	probe.stop()

	var pid := OS.create_process("python3", ["-m", "http.server", str(port)])
	if pid <= 0:
		skip("could not start python http.server")
		return

	var listener_seen := false
	for _i in range(20):
		OS.delay_msec(100)
		if not McpPortResolver.find_all_pids_on_port(port).is_empty():
			listener_seen = true
			break
	if not listener_seen:
		OS.kill(pid)
		skip("python http.server did not bind test port")
		return

	var bind_still_succeeds := McpPortResolver.can_bind_local_port(port)
	if not bind_still_succeeds:
		OS.kill(pid)
		McpPortResolver.wait_for_port_free(port, 2.0)
		skip("python http.server also held IPv4 loopback; POSIX fallback precondition unavailable")
		return

	var detected := McpPortResolver.is_port_in_use(port)
	OS.kill(pid)
	McpPortResolver.wait_for_port_free(port, 2.0)

	assert_true(detected)


func test_pid_alive_rejects_sentinel_pids() -> void:
	assert_false(McpPortResolver.pid_alive(0))
	assert_false(McpPortResolver.pid_alive(-1))


func test_pid_alive_recognises_editor_pid() -> void:
	## The Godot editor process is a known-live PID on every platform.
	assert_true(McpPortResolver.pid_alive(OS.get_process_id()))


func test_read_pid_file_round_trips_value() -> void:
	if FileAccess.file_exists(McpPortResolver.SERVER_PID_FILE):
		McpPortResolver.clear_pid_file()
	assert_eq(McpPortResolver.read_pid_file(), 0)

	var f := FileAccess.open(McpPortResolver.SERVER_PID_FILE, FileAccess.WRITE)
	f.store_string("12345")
	f.close()
	assert_eq(McpPortResolver.read_pid_file(), 12345)
	McpPortResolver.clear_pid_file()
	assert_eq(McpPortResolver.read_pid_file(), 0)


func test_server_pid_file_namespaces_isolated_http_ports() -> void:
	assert_eq(McpPortResolver.server_pid_file(), McpPortResolver.SERVER_PID_FILE)
	assert_eq(
		McpPortResolver.server_pid_file(18421),
		"user://godot_ai_servers/18421/server.pid",
	)
	assert_true(
		McpPortResolver.server_pid_file(18421) != McpPortResolver.server_pid_file(18422),
		"distinct HTTP endpoints must never share lifecycle PID state",
	)


func test_isolated_pid_file_round_trip_does_not_touch_default() -> void:
	var reserved := _reserve_unused_lane_namespace()
	var lane_port := int(reserved.get("port", 0))
	var reservation: TCPServer = reserved.get("server")
	if lane_port <= 0 or reservation == null:
		skip("could not reserve an unused isolated-lane namespace")
		return
	var path := McpPortResolver.server_pid_file(lane_port)
	var absolute_path := ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(absolute_path.get_base_dir())

	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_true(file != null, "test setup: isolated pid path should be writable")
	if file == null:
		reservation.stop()
		return
	file.store_string("54321")
	file.close()
	assert_eq(McpPortResolver.read_pid_file(lane_port), 54321)
	McpPortResolver.clear_pid_file(lane_port)
	assert_eq(McpPortResolver.read_pid_file(lane_port), 0)
	reservation.stop()


func _reserve_unused_lane_namespace() -> Dictionary:
	var start := 32000 + (OS.get_process_id() % 18000)
	for offset in range(2048):
		var candidate := 30000 + ((start - 30000 + offset) % 30000)
		var lane_dir := ProjectSettings.globalize_path(
			"user://godot_ai_servers/%d" % candidate
		)
		if (
			FileAccess.file_exists(lane_dir.path_join("managed.json"))
			or FileAccess.file_exists(lane_dir.path_join("managed.json.backup"))
			or FileAccess.file_exists(lane_dir.path_join("server.pid"))
		):
			continue
		var reservation := TCPServer.new()
		if reservation.listen(candidate, "127.0.0.1") == OK:
			return {"port": candidate, "server": reservation}
	return {}


func test_windows_powershell_candidates_prefers_system32_path() -> void:
	## System32 must come first so a hijacked PATH can't intercept.
	var candidates := McpPortResolver.windows_powershell_candidates()
	assert_true(candidates.size() >= 3)
	assert_true(candidates[0].ends_with("powershell.exe"))


func test_netstat_parse_is_locale_independent() -> void:
	## The state column is localized ("ABHÖREN", "ÉCOUTE", ...); the
	## listener signal is the wildcard ":0" FOREIGN address, which is
	## locale-independent (mirrors script/_dev_env.py).
	var german := "  TCP  0.0.0.0:8000  0.0.0.0:0  ABHÖREN  4242\n"
	var pids := McpPortResolver.parse_windows_netstat_pids(german, 8000)
	assert_eq(pids.size(), 1, "localized state must still parse via the :0 foreign addr")
	assert_eq(pids[0], 4242)


func test_netstat_parse_still_skips_established_rows() -> void:
	## An ESTABLISHED row's foreign address carries a real port — it must
	## not be mistaken for a listener even when the local port matches.
	var established := "  TCP  10.0.0.5:8000  10.0.0.9:51515  HERGESTELLT  777\n"
	var pids := McpPortResolver.parse_windows_netstat_pids(established, 8000)
	assert_eq(pids.size(), 0, "non-listener rows must be skipped regardless of locale")
