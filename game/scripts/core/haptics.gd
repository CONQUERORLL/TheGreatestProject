extends Node
## 手柄震动反馈（Input.start_joy_vibration；未连接手柄时调用自动无害）
## 所有震动统一走这里：便于节流（防连续击杀叠满）与全局开关
## headless 冒烟测试无手柄，空跑通过

var enabled := true
var _min_interval_ms := 40
var _last_ms := 0

func rumble(weak: float, strong: float, duration: float) -> void:
	if not enabled or duration <= 0.0:
		return
	var now := Time.get_ticks_msec()
	if now - _last_ms < _min_interval_ms:
		return
	_last_ms = now
	weak = clampf(weak, 0.0, 1.0)
	strong = clampf(strong, 0.0, 1.0)
	if weak <= 0.0 and strong <= 0.0:
		return
	for device in Input.get_connected_joypads():
		Input.start_joy_vibration(device, weak, strong, duration)

## 战斗震动：由 screen_shake 强度线性映射（受击 3.5 / BOSS 弹幕 3.0 / 火箭 2.5 / 霰弹 2.0）
func rumble_from_shake(amount: float) -> void:
	var t: float = clampf(amount / 3.5, 0.0, 1.0)
	rumble(0.1 + 0.2 * t, 0.25 + 0.55 * t, 0.12 + 0.12 * t)

func stop() -> void:
	for device in Input.get_connected_joypads():
		Input.stop_joy_vibration(device)
