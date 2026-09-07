extends Node
## 音效系统：程序生成 AudioStreamWAV（无外部文件依赖）
## 所有音效统一走这里，音量受设置页主音量控制
## headless 无声卡，空跑通过

var _players: Array[AudioStreamPlayer] = []
var _pool_size := 8
var _idx := 0
var _streams: Dictionary = {}   # name -> AudioStreamWAV

func _ready() -> void:
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
	_streams["wave_start"] = _gen_arpeggio([392.0, 523.0], 0.10, 0.25)
	_streams["game_over"] = _gen_sweep(300.0, 50.0, 0.60, 0.50)
	_streams["victory"] = _gen_arpeggio([523.0, 659.0, 784.0, 1047.0], 0.12, 0.30)
	# 播放器池
	for i in _pool_size:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_players.append(p)
	# 事件接线
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.boss_killed.connect(_on_boss_killed)
	EventBus.player_damaged.connect(_on_player_damaged)
	EventBus.player_died.connect(_on_player_died)
	EventBus.leveled_up.connect(_on_leveled_up)
	EventBus.wave_started.connect(_on_wave_started)

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
