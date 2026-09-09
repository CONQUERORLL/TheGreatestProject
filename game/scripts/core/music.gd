extends Node
## BGM：优先加载外部素材 assets/audio/bgm/*.wav，缺失或损坏时回退程序生成
## 懒加载：首次播放某曲目时才读取/渲染 AudioStreamWAV，避免拖慢启动
## 音量由 Settings.music_vol 经 Music 总线控制；headless 空跑通过
## 替换素材：把同名 16-bit PCM WAV 放进 assets/audio/bgm/ 即可，无需改接线

const RATE := 11025
const REST := -99
const BASE_FREQ := 220.0
const TRACK_BPM := {
	"menu": 84.0, "shop": 96.0,
	"battle": 138.0, "battle_mid": 146.0, "battle_late": 156.0, "boss": 150.0,
	"victory": 112.0, "defeat": 70.0,
}
## 外部素材路径（存在则优先；替换 BGM 只需覆盖这些文件）
const TRACK_FILES := {
	"menu": "res://assets/audio/bgm/menu.wav",
	"shop": "res://assets/audio/bgm/shop.wav",
	"battle": "res://assets/audio/bgm/battle.wav",
	"battle_mid": "res://assets/audio/bgm/battle_mid.wav",
	"battle_late": "res://assets/audio/bgm/battle_late.wav",
	"boss": "res://assets/audio/bgm/boss.wav",
	"victory": "res://assets/audio/bgm/victory.wav",
	"defeat": "res://assets/audio/bgm/defeat.wav",
}
## 每步一个 8 分音符；melody/bass 为相对基准音的半音偏移（REST = 休止）
const TRACKS := {
	"menu": {
		"steps": 16,
		"melody": [0, 4, 7, 4, 9, 7, 4, 2, 0, 4, 7, 12, 9, 7, 4, 2],
		"bass": [0, REST, -5, REST, -3, REST, -5, REST,
			0, REST, -5, REST, -7, REST, -5, REST],
	},
	"battle": {
		"steps": 16,
		"melody": [0, 0, 7, 0, 4, 4, 9, 4, 2, 2, 9, 2, 5, 5, 11, 7],
		"bass": [0, 0, -5, -5, -3, -3, -7, -7,
			0, 0, -5, -5, -7, -7, -5, -5],
	},
	"battle_mid": {
		"steps": 16,
		"melody": [0, 0, 3, 0, 7, 7, 10, 7, 5, 5, 10, 5, 3, 3, 7, 5],
		"bass": [0, 0, -5, -5, -3, -3, -7, -7,
			0, 0, -5, -5, -7, -7, -3, -3],
	},
	"battle_late": {
		"steps": 16,
		"melody": [0, 7, 10, 7, 12, 10, 7, 3, 0, 7, 10, 12, 15, 12, 10, 7],
		"bass": [0, 0, -2, -2, -5, -5, -7, -7,
			-2, -2, -5, -5, -7, -7, -10, -10],
	},
	"boss": {
		"steps": 16,
		"melody": [0, 3, 7, 3, 10, 7, 3, 0, 0, 3, 7, 12, 10, 7, 6, 3],
		"bass": [0, 0, -2, -2, -5, -5, -2, -2,
			-7, -7, -5, -5, -2, -2, -5, -5],
	},
	"shop": {
		"steps": 16,
		"melody": [0, 7, 4, 9, 0, 7, 4, 2, 0, 7, 4, 9, 12, 9, 7, 4],
		"bass": [0, REST, -5, REST, -3, REST, -7, REST,
			0, REST, -5, REST, -3, REST, -5, REST],
	},
	"victory": {
		"steps": 16,
		"melody": [0, 4, 7, 12, 9, 7, 4, 7, 0, 4, 7, 12, 14, 12, 7, 4],
		"bass": [0, REST, -5, REST, -3, REST, -5, REST,
			0, REST, -5, REST, -3, REST, -5, REST],
	},
	"defeat": {
		"steps": 16,
		"melody": [0, REST, 3, REST, 7, REST, 3, REST,
			0, REST, 3, REST, 5, 3, 2, REST],
		"bass": [0, REST, -4, REST, -7, REST, -5, REST,
			0, REST, -4, REST, -7, REST, -5, REST],
	},
}

const BASE_DB := -5.0
const SILENT_DB := -60.0

var _player: AudioStreamPlayer
var _streams: Dictionary = {}   # name -> AudioStreamWAV
var _source: Dictionary = {}    # name -> "file" / "synth"（测试观测）
var _current := ""
var _pending := ""              # 淡变中即将切到的曲目
var _fade_tween: Tween = null

func _ready() -> void:
	Settings.ensure_audio_buses()
	_player = AudioStreamPlayer.new()
	_player.bus = Settings.BUS_MUSIC
	_player.volume_db = BASE_DB
	add_child(_player)

## 切换曲目（同曲目播放中则忽略）；fade > 0 时淡出旧曲再淡入新曲
func play_track(name: String, fade := 0.0) -> void:
	if not TRACKS.has(name):
		return
	if name == _current and _player != null and _player.playing:
		if _pending == "":
			return
		_kill_fade()
		_pending = ""
		_player.volume_db = BASE_DB
		return
	if fade > 0.0 and _player != null and _player.playing:
		_fade_to(name, fade)
		return
	_kill_fade()
	_pending = ""
	_switch_now(name, true)

func _switch_now(name: String, reset_volume: bool) -> void:
	if not _streams.has(name):
		_streams[name] = _load_track(name)
	_current = name
	_pending = ""
	_player.stream = _streams[name]
	if reset_volume:
		_player.volume_db = BASE_DB
	_player.play()

## 淡出 → 换曲 → 淡入；重复调用会取消上一段淡变
func _fade_to(name: String, fade: float) -> void:
	_kill_fade()
	_pending = name
	_fade_tween = create_tween()
	_fade_tween.tween_property(_player, "volume_db", SILENT_DB, maxf(0.05, fade * 0.45))
	_fade_tween.tween_callback(func() -> void: _switch_now(name, false))
	_fade_tween.tween_property(_player, "volume_db", BASE_DB, maxf(0.05, fade * 0.55))

func stop(fade := 0.0) -> void:
	_kill_fade()
	_pending = ""
	_current = ""
	if _player == null:
		return
	if fade > 0.0 and _player.playing:
		_fade_tween = create_tween()
		_fade_tween.tween_property(_player, "volume_db", SILENT_DB, fade)
		_fade_tween.tween_callback(func() -> void:
			_player.stop()
			_player.volume_db = BASE_DB)
	else:
		_player.stop()
		_player.volume_db = BASE_DB

func _kill_fade() -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = null

func current_track() -> String:
	return _current

## 当前曲目的来源：file（外部素材）/ synth（程序生成回退）
func current_source() -> String:
	return String(_source.get(_current, ""))

## 测试观测：播放器当前音量（dB）
func volume_db() -> float:
	return _player.volume_db if _player != null else 0.0

## 波次 → 曲目：1-4 战斗 / 5-7 中盘 / 8+ 终盘 / BOSS 波 BOSS 曲
func track_for_wave(w: int) -> String:
	if Config.is_boss_wave(w):
		return "boss"
	if w >= 8:
		return "battle_late"
	if w >= 5:
		return "battle_mid"
	return "battle"

# ---------------- 渲染 ----------------

## 优先外部素材；文件缺失/格式不支持时回退程序生成
func _load_track(name: String) -> AudioStreamWAV:
	var path := String(TRACK_FILES.get(name, ""))
	if path != "":
		var ext := _load_wav_file(path)
		if ext != null:
			_source[name] = "file"
			return ext
	_source[name] = "synth"
	return _gen_track(name)

## 直接解析 16-bit PCM WAV（不经 Godot 导入管线；导出时用 include_filter 带上原始文件）
func _load_wav_file(path: String) -> AudioStreamWAV:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()
	if bytes.size() < 44 or _tag(bytes, 0) != "RIFF" or _tag(bytes, 8) != "WAVE":
		return null
	var pos := 12
	var fmt_ok := false
	var channels := 1
	var rate := RATE
	var data_off := -1
	var data_len := 0
	while pos + 8 <= bytes.size():
		var cid := _tag(bytes, pos)
		var csize := bytes.decode_u32(pos + 4)
		var body := pos + 8
		if cid == "fmt " and body + 16 <= bytes.size():
			var audio_format := bytes.decode_u16(body)
			channels = bytes.decode_u16(body + 2)
			rate = int(bytes.decode_u32(body + 4))
			var bits := bytes.decode_u16(body + 14)
			fmt_ok = audio_format == 1 and bits == 16 and channels >= 1 and channels <= 2
		elif cid == "data":
			data_off = body
			data_len = mini(csize, bytes.size() - body)
		pos = body + csize + (csize & 1)
	if not fmt_ok or data_off < 0 or data_len <= 0 or rate <= 0:
		return null
	var frames := data_len / (channels * 2)
	if frames <= 0:
		return null
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.stereo = channels == 2
	stream.data = bytes.slice(data_off, data_off + data_len)
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = frames
	return stream

func _tag(bytes: PackedByteArray, pos: int) -> String:
	if pos + 4 > bytes.size():
		return ""
	return bytes.slice(pos, pos + 4).get_string_from_ascii()

func _gen_track(name: String) -> AudioStreamWAV:
	var spec: Dictionary = TRACKS[name]
	var bpm := float(TRACK_BPM.get(name, 120.0))
	var step_dur := 60.0 / bpm / 2.0
	var steps := int(spec.get("steps", 16))
	var total := int(RATE * step_dur * float(steps))
	var melody: Array = spec.get("melody", [])
	var bass: Array = spec.get("bass", [])
	var rng := RandomNumberGenerator.new()   # 局部 RNG：不消耗全局 GameRng，保每日挑战种子确定性
	rng.seed = 0x5EED_1234
	var data := PackedByteArray()
	data.resize(total * 2)
	for i in total:
		var t := float(i) / RATE
		var step := int(t / step_dur) % steps
		var step_t := fmod(t, step_dur)
		var s := 0.0
		if step < melody.size():
			var m := int(melody[step])
			if m != REST:
				s += _voice(_freq(m), step_t, step_dur, 0.20, 5.0)
		if step < bass.size():
			var b := int(bass[step])
			if b != REST:
				s += _voice(_freq(b - 24), step_t, step_dur, 0.30, 2.2)
		if step % 4 == 0:
			s += rng.randf_range(-1.0, 1.0) * exp(-40.0 * step_t) * 0.035
		var v := int(clampf(s, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, v)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	stream.data = data
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = total
	return stream

func _freq(semi: int) -> float:
	return BASE_FREQ * pow(2.0, float(semi) / 12.0)

## 单个音符：基频 + 三次谐波，10ms 起音 + 指数衰减
func _voice(freq: float, t: float, step_dur: float, vol: float, decay: float) -> float:
	if freq <= 0.0:
		return 0.0
	var env := exp(-decay * t / step_dur) * minf(1.0, t / 0.01)
	return (sin(TAU * freq * t) * 0.8 + sin(TAU * freq * 3.0 * t) * 0.2) * env * vol
