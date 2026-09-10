extends Node
## 全局事件总线：模块间解耦（对应规划的 Signal 事件系统）
## 武器 / 敌人 / 波次 / 商店 / UI 各系统只依赖这里，互不直接引用

signal run_started
signal run_ended(victory: bool)

signal wave_started(wave: int)
signal wave_ended(wave: int)

signal enemy_killed(enemy_type: String)
## 敌人死亡（携带节点引用）：法宝 on_kill 需要读目标死前身上的状态，
## enemy_killed 只带类型字符串不够用。新增信号而不改现有签名，
## 避免破坏 main / sfx / codex_data / wave_manager 四个既有订阅者。
## 在 enemy_killed 之后、queue_free 之前发出（订阅者仍可安全访问节点）
signal enemy_died(enemy: Node2D)
signal boss_killed
signal status_applied(status_id: String, stacks: int, pos: Vector2)
## 五行反应触发（相生/相克）：main.gd 订阅播放特效，法宝系统订阅 on_reaction 触发
signal element_reaction(reaction_id: String, pos: Vector2, targets: Array)
## 获得法宝（掉落/商店/BOSS 入账统一出口）：HUD/商店/图鉴刷新用
signal artifact_acquired(artifact_id: String)

signal codex_unlocked(category: String, id: String)
signal achievement_unlocked(id: String)

## 解锁系统：结算时一次性广播本轮新解锁的内容（[{kind, id}]）
## kind = "character" / "weapon"；main 订阅展示 toast
signal unlocks_achieved(entries: Array)

## 江湖奇遇事件卡：玩家做出选择后广播（图鉴解锁 / 统计 / 后续扩展的统一出口）
signal event_card_triggered(card_id: String, choice_id: String)

signal player_damaged(amount: float)
signal player_died

signal leveled_up(new_level: int)
signal materials_changed(total: int)
signal item_purchased(good_id: String)

signal screen_shake(amount: float)
signal banner_requested(title: String, subtitle: String, duration: float)
