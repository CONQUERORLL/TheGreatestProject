extends Node
## 音效系统：程序生成 AudioStreamWAV（无外部文件依赖）
## 所有音效统一走这里，音量受设置页“音效”独立音量控制
## headless 无声卡，空跑通过

var _players: Array[AudioStreamPlayer] = []
var _pool_size := 8
var _idx := 0
var _streams: Dictionary = {}   # name -> AudioStreamWAV
var _status_cd: Dictionary = {}  # status_id -> 下次可播放的时间戳（ms，防高频武器刷屏）
var _reaction_cd: Dictionary = {}   # reaction_id -> 下次可播放时间戳（防 AOE 连锁糊成一团）

func _ready() -> void:
	Settings.ensure_audio_buses()
	# 预生成所有音效
	_streams["shoot_pistol"] = _gen_blip(620.0, 0.06, 0.25)
	_streams["shoot_smg"] = _gen_blip(780.0, 0.04, 0.18)
	_streams["shoot_shotgun"] = _gen_noise(0.12, 0.45, 240.0)
	_streams["shoot_rocket"] = _gen_noise(0.20, 0.55, 120.0)
	_streams["shoot_knife"] = _gen_sweep(900.0, 300.0, 0.08, 0.22)
	_streams["enemy_hit"] = _gen_blip(320.0, 0.04, 0.15)
	_streams["enemy_die"] = _gen_sweep(400.0, 80.0, 0.12, 0.30)
	_streams["boss_die"] = _gen_sweep(200.0, 40.0, 0.50, 0.60)
	_streams["player_hit"] = _gen_noise(0.08, 0.30, 80.0)
	_streams["level_up"] = _gen_arpeggio([523.0, 659.0, 784.0], 0.07, 0.25)
	_streams["buy"] = _gen_blip(880.0, 0.05, 0.20)
	_streams["reroll"] = _gen_sweep(400.0, 800.0, 0.06, 0.18)
	_streams["heal"] = _gen_arpeggio([523.0, 784.0], 0.06, 0.20)
	_streams["ui_select"] = _gen_blip(660.0, 0.03, 0.12)
	_streams["ui_click"] = _gen_blip(740.0, 0.035, 0.14)
	_streams["ui_hover"] = _gen_blip(980.0, 0.022, 0.08)
	_streams["ui_page"] = _gen_arpeggio([523.0, 659.0], 0.045, 0.14)
	_streams["ui_back"] = _gen_sweep(520.0, 260.0, 0.055, 0.12)
	_streams["wave_start"] = _gen_arpeggio([392.0, 523.0], 0.10, 0.25)
	_streams["game_over"] = _gen_sweep(300.0, 50.0, 0.60, 0.50)
	_streams["victory"] = _gen_arpeggio([523.0, 659.0, 784.0, 1047.0], 0.12, 0.30)
	_streams["skill_cast"] = _gen_sweep(200.0, 1500.0, 0.20, 0.42)
	# 异常状态触发音（每种状态独立音色；由 EventBus.status_applied 驱动）
	_streams["status_burn"] = _gen_noise(0.16, 0.30, 1400.0)
	_streams["status_poison"] = _gen_sweep(240.0, 520.0, 0.18, 0.22)
	_streams["status_bleed"] = _gen_noise(0.08, 0.24, 520.0)
	_streams["status_freeze"] = _gen_sweep(1400.0, 620.0, 0.20, 0.24)
	_streams["status_slow"] = _gen_sweep(620.0, 260.0, 0.22, 0.20)
	_streams["status_stun"] = _gen_arpeggio([880.0, 660.0, 880.0], 0.05, 0.20)
	# 五行反应音（相生清亮上行 / 相克厚重爆裂；由 EventBus.element_reaction 驱动）
	_streams["reaction_wood_fire"] = _gen_arpeggio([392.0, 523.0, 659.0], 0.06, 0.22)
	_streams["reaction_fire_earth"] = _gen_arpeggio([330.0, 440.0, 523.0], 0.06, 0.22)
	_streams["reaction_earth_metal"] = _gen_sweep(700.0, 1500.0, 0.14, 0.24)
	_streams["reaction_metal_water"] = _gen_sweep(1200.0, 500.0, 0.16, 0.22)
	_streams["reaction_water_wood"] = _gen_arpeggio([523.0, 659.0, 880.0], 0.05, 0.20)
	_streams["reaction_wood_earth"] = _gen_noise(0.18, 0.42, 320.0)
	_streams["reaction_earth_water"] = _gen_sweep(180.0, 40.0, 0.42, 0.55)
	_streams["reaction_fire_water"] = _gen_noise(0.26, 0.50, 900.0)
	_streams["reaction_fire_metal"] = _gen_sweep(1500.0, 300.0, 0.22, 0.40)
	_streams["reaction_metal_wood"] = _gen_noise(0.22, 0.38, 1800.0)
	# 播放器池
	for i in _pool_size:
		var p := AudioStreamPlayer.new()
		p.bus = Settings.BUS_SFX
		add_child(p)
		_players.append(p)
	# 事件接线
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.boss_killed.connect(_on_boss_killed)
	EventBus.player_damaged.connect(_on_player_damaged)
	EventBus.player_died.connect(_on_player_died)
	EventBus.leveled_up.connect(_on_leveled_up)
	EventBus.wave_started.connect(_on_wave_started)
	EventBus.status_applied.connect(_on_status_applied)
	EventBus.element_reaction.connect(_on_element_reaction)

func play(name: String) -> void:
	if not _streams.has(name):
		return
	var p := _players[_idx]
	_idx = (_idx + 1) % _pool_size
	p.stream = _streams[name]
	p.play()

func _on_enemy_killed(type: String) -> void:
	play("enemy_die")

func _on_boss_killed() -> void:
	play("boss_die")

func _on_player_damaged(_amount: float) -> void:
	play("player_hit")

func _on_player_died() -> void:
	play("game_over")

func _on_leveled_up(_lv: int) -> void:
	play("level_up")

func _on_wave_started(_w: int) -> void:
	play("wave_start")

## 状态首次触发：同状态 200ms 节流（火焰喷射器 10 发/秒也不会糊成一片）
func _on_status_applied(status_id: String, _stacks: int, _pos: Vector2) -> void:
	var now := Time.get_ticks_msec()
	if now < int(_status_cd.get(status_id, 0)):
		return
	_status_cd[status_id] = now + 200
	play("status_" + status_id)

## 五行反应音：同反应 160ms 节流（水生木扩散连锁时不会叠成白噪）
func _on_element_reaction(reaction_id: String, _pos: Vector2, _targets: Array) -> void:
	var now := Time.get_ticks_msec()
	if now < int(_reaction_cd.get(reaction_id, 0)):
		return
	_reaction_cd[reaction_id] = now + 160
	play("reaction_" + reaction_id)

# ---------------- 程序生成 AudioStreamWAV ----------------

const RATE := 22050

func _gen_blip(freq: float, dur: float, vol: float) -> AudioStreamWAV:
	var n := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / RATE
		var env := exp(-6.0 * t / dur)
		var s := sin(TAU * freq * t) * env * vol
		var v := int(clampf(s, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, v)
	return _make_stream(data)

func _gen_noise(dur: float, vol: float, cutoff: float) -> AudioStreamWAV:
	var n := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	var prev := 0.0
	for i in n:
		var t := float(i) / RATE
		var env := exp(-5.0 * t / dur)
		var raw := GameRng.range_f(-1.0, 1.0)
		# 简单低通：截止频率越低越闷
		var a := cutoff / RATE
		prev = prev * (1.0 - a) + raw * a
		var s := prev * env * vol
		var v := int(clampf(s, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, v)
	return _make_stream(data)

func _gen_sweep(f0: float, f1: float, dur: float, vol: float) -> AudioStreamWAV:
	var n := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / RATE
		var env := exp(-4.0 * t / dur)
		var freq := f0 + (f1 - f0) * (t / dur)
		var s := sin(TAU * freq * t) * env * vol
		var v := int(clampf(s, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, v)
	return _make_stream(data)

func _gen_arpeggio(freqs: Array, note_dur: float, vol: float) -> AudioStreamWAV:
	var n := int(RATE * note_dur * freqs.size())
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / RATE
		var note_idx: int = int(t / note_dur)
		if note_idx >= freqs.size():
			note_idx = freqs.size() - 1
		var note_t := fmod(t, note_dur)
		var env := exp(-5.0 * note_t / note_dur)
		var s := sin(TAU * freqs[note_idx] * t) * env * vol
		var v := int(clampf(s, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, v)
	return _make_stream(data)

func _make_stream(data: PackedByteArray) -> AudioStreamWAV:
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = data
	return s
