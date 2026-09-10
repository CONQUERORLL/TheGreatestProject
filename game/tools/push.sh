#!/usr/bin/env bash
# push.sh —— 带自动重试与远端校验的推送脚本
#
# 为什么需要它
#   本机到 GitHub 的 HTTPS 链路是概率性可用的：读（ls-remote）时常通，
#   写（push）会以 HTTP 408 / 502 / 长时间挂起 三种形态失败，需重试若干次才能成功。
#   而每次重试都会重新触发凭据管理器认证与工具授权弹窗 ——
#   分散重试 = 连环弹窗。把全部重试收进一次调用，弹窗就只出现一次。
#
# 用法
#   bash game/tools/push.sh [分支]        # 分支缺省取当前分支
#   可调环境变量： ATTEMPTS=6  PER_TRY_TIMEOUT=75  REMOTE=origin
#
# 判据
#   一律以 `git ls-remote` 读回的远端 SHA 为准，**不看 push 的 stdout**：
#   挂起型失败时 push 没有任何输出，容易被误判成「已经推上去了」。
#   本沙箱里 refs/remotes/** 的写入不持久，因此脚本完全不依赖本地 origin/* 缓存。

set -u

REMOTE="${REMOTE:-origin}"
BRANCH="${1:-$(git rev-parse --abbrev-ref HEAD)}"
ATTEMPTS="${ATTEMPTS:-6}"
PER_TRY_TIMEOUT="${PER_TRY_TIMEOUT:-75}"

if [ "$BRANCH" = "HEAD" ]; then
	echo "❌ 当前处于 detached HEAD，请显式指定分支：bash game/tools/push.sh <分支>"
	exit 2
fi

if ! local_sha="$(git rev-parse "$BRANCH" 2>/dev/null)"; then
	echo "❌ 本地不存在分支 $BRANCH"
	exit 2
fi

# 读远端真实 SHA（只认 ls-remote，不信本地 origin/* 缓存）
remote_sha() {
	timeout 30 git ls-remote "$REMOTE" "refs/heads/$BRANCH" 2>/dev/null | awk 'NR==1 { print $1 }'
}

echo "分支 $BRANCH → $REMOTE    本地 ${local_sha:0:7}"

r_sha="$(remote_sha)"
if [ -n "$r_sha" ] && [ "$r_sha" = "$local_sha" ]; then
	echo "✅ 远端已是最新，无需推送（${local_sha:0:7}）"
	exit 0
fi

for i in $(seq 1 "$ATTEMPTS"); do
	# 递增等待：链路故障是波动型的（同一分钟内 502 与成功可能交替出现），
	# 固定 4 秒的节奏太密，容易连续撞在同一段故障窗口里。后几次拉长间隔。
	if [ "$i" -le 2 ]; then
		wait_s=4
	elif [ "$i" -le 4 ]; then
		wait_s=8
	else
		wait_s=15
	fi

	echo "--- 第 $i/$ATTEMPTS 次 ---"
	timeout "$PER_TRY_TIMEOUT" git push "$REMOTE" "$BRANCH" 2>&1 | tail -4
	code="${PIPESTATUS[0]}"
	if [ "$code" -eq 124 ]; then
		echo "（超时被中断：典型的挂起型失败）"
	fi

	r_sha="$(remote_sha)"
	if [ -n "$r_sha" ] && [ "$r_sha" = "$local_sha" ]; then
		echo "✅ 推送成功：$REMOTE/$BRANCH = ${local_sha:0:7}"
		exit 0
	fi
	if [ -n "$r_sha" ]; then
		echo "远端仍为 ${r_sha:0:7}，${wait_s} 秒后重试"
	else
		echo "远端不可达（ls-remote 无响应），${wait_s} 秒后重试"
	fi
	sleep "$wait_s"
done

r_disp="${r_sha:0:7}"
[ -z "$r_sha" ] && r_disp="<不可达>"
echo "❌ $ATTEMPTS 次尝试后仍未推送成功"
echo "   本地 ${local_sha:0:7} / 远端 $r_disp"
echo "   请在本地终端直接执行：git push $REMOTE $BRANCH"
exit 1
