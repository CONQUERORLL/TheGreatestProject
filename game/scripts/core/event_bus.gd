extends Node
## 全局事件总线：模块间解耦（对应规划的 Signal 事件系统）
## 武器 / 敌人 / 波次 / 商店 / UI 各系统只依赖这里，互不直接引用

signal run_started
signal run_ended(victory: bool)

signal wave_started(wave: int)
signal wave_ended(wave: int)

signal enemy_killed(enemy_type: String)
signal boss_killed
signal status_applied(status_id: String, stacks: int, pos: Vector2)
signal element_reaction(reaction_id: String, pos: Vector2, targets: Array)

signal codex_unlocked(category: String, id: String)
signal achievement_unlocked(id: String)

signal player_damaged(amount: float)
signal player_died

signal leveled_up(new_level: int)
signal materials_changed(total: int)
signal item_purchased(good_id: String)

signal screen_shake(amount: float)
signal banner_requested(title: String, subtitle: String, duration: float)
