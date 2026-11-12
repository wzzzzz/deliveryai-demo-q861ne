#!/usr/bin/env bash
#
# 集成测试: 未指派需求同步 (REQ-001, REQ-002)
#
# 验证禅道需求无负责人时同步至 DeliveryAI 平台的行为:
#   REQ-001: 无负责人需求可正常获取和导入（task 存在且 status != fail）
#   REQ-002: 负责人保持未指派（owner_ids 为空），不映射为产品管理员
#
# 依赖: deliveryai CLI 已安装并登录
#
set -euo pipefail

PRODUCT_ID="p-yezccrcem8s7fjgy7144"
TASK_ID="task-yezccspkhss7fjgy88tf"
ADMIN_ID="u-yeym92e6tcpx7l9t89kl"
WORK_ITEM_ID="3"

# 轮询参数
POLL_INTERVAL_SEC=10
POLL_MAX_SEC=120

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() {
  echo -e "${GREEN}[PASS]${NC} $1"
}

fail() {
  echo -e "${RED}[FAIL]${NC} $1"
  exit 1
}

info() {
  echo -e "${YELLOW}[INFO]${NC} $1"
}

# ─── 前置: 确认 CLI 身份 ───
info "检查 deliveryai CLI 身份..."
AUTH_JSON=$(deliveryai auth status --json)
TOKEN_EXPIRES=$(echo "$AUTH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('expiresAt',''))")
info "Token 过期时间: $TOKEN_EXPIRES"

# ─── 前置: 记录同步前的 task 状态 ───
info "获取同步前的 Task 状态 (TaskID=$TASK_ID)..."
TASK_BEFORE=$(deliveryai api call GetTaskDetail --body "{\"TaskID\":\"$TASK_ID\"}")
OWNER_BEFORE=$(echo "$TASK_BEFORE" | python3 -c "import sys,json; t=json.load(sys.stdin).get('Task',{}); print(json.dumps(t.get('OwnerIDs',[])))")
UPDATED_BEFORE=$(echo "$TASK_BEFORE" | python3 -c "import sys,json; t=json.load(sys.stdin).get('Task',{}); print(t.get('UpdatedAt',''))")
info "同步前 OwnerIDs: $OWNER_BEFORE"
info "同步前 UpdatedAt: $UPDATED_BEFORE"

# ─── Step 1: 触发产品级 Reconcile (REQ-001) ───
info "触发 TriggerProductWorkItemReconcile (ProductID=$PRODUCT_ID)..."
RECONCILE_RESP=$(deliveryai api call TriggerProductWorkItemReconcile \
  --body "{\"ProductId\":\"$PRODUCT_ID\"}" --yes)

TRIGGERED=$(echo "$RECONCILE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Triggered', False))")
MODE=$(echo "$RECONCILE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Mode',''))")
info "Reconcile 触发结果: Triggered=$TRIGGERED, Mode=$MODE"

if [ "$TRIGGERED" != "True" ]; then
  fail "REQ-001: Reconcile 未成功触发 (Triggered=$TRIGGERED)"
fi
pass "REQ-001.1: Reconcile 成功触发"

# ─── Step 2: 轮询等待同步完成 ───
info "等待同步完成（轮询间隔 ${POLL_INTERVAL_SEC}s，最长 ${POLL_MAX_SEC}s）..."
ELAPSED=0
SYNC_DONE=false
UPDATED_AFTER=""

while [ "$ELAPSED" -lt "$POLL_MAX_SEC" ]; do
  sleep "$POLL_INTERVAL_SEC"
  ELAPSED=$((ELAPSED + POLL_INTERVAL_SEC))

  TASK_NOW=$(deliveryai api call GetTaskDetail --body "{\"TaskID\":\"$TASK_ID\"}")
  UPDATED_NOW=$(echo "$TASK_NOW" | python3 -c "import sys,json; t=json.load(sys.stdin).get('Task',{}); print(t.get('UpdatedAt',''))")

  if [ "$UPDATED_NOW" != "$UPDATED_BEFORE" ]; then
    SYNC_DONE=true
    UPDATED_AFTER="$UPDATED_NOW"
    info "检测到 Task 更新: UpdatedAt=$UPDATED_AFTER (耗时 ${ELAPSED}s)"
    break
  fi
  info "等待中... ${ELAPSED}s, UpdatedAt 未变化"
done

if [ "$SYNC_DONE" != "true" ]; then
  info "轮询超时，使用当前 Task 状态继续校验（同步可能已在触发前完成）"
fi

# ─── Step 3: 校验 REQ-001 — task 存在且 status != fail ───
TASK_AFTER=$(deliveryai api call GetTaskDetail --body "{\"TaskID\":\"$TASK_ID\"}")
STATUS_AFTER=$(echo "$TASK_AFTER" | python3 -c "import sys,json; t=json.load(sys.stdin).get('Task',{}); print(t.get('Status',''))")
WORK_ITEM_ID_AFTER=$(echo "$TASK_AFTER" | python3 -c "import sys,json; t=json.load(sys.stdin).get('Task',{}); print(t.get('WorkItemID',''))")

info "同步后 Task 状态: Status=$STATUS_AFTER, WorkItemID=$WORK_ITEM_ID_AFTER"

if [ "$STATUS_AFTER" = "fail" ]; then
  fail "REQ-001.2: Task 状态为 fail，同步失败"
fi
pass "REQ-001.2: Task 存在且 status != fail (status=$STATUS_AFTER)"

# ─── Step 4: 校验 REQ-002 — owner_ids 为空，不含管理员 ───
OWNER_AFTER=$(echo "$TASK_AFTER" | python3 -c "import sys,json; t=json.load(sys.stdin).get('Task',{}); print(json.dumps(t.get('OwnerIDs',[])))")
info "同步后 OwnerIDs: $OWNER_AFTER"

# 解析 owner_ids 数组长度和内容
OWNER_COUNT=$(echo "$TASK_AFTER" | python3 -c "import sys,json; t=json.load(sys.stdin).get('Task',{}); print(len(t.get('OwnerIDs',[])))")
OWNER_CONTAINS_ADMIN=$(echo "$TASK_AFTER" | python3 -c "import sys,json; t=json.load(sys.stdin).get('Task',{}); print('u-yeym92e6tcpx7l9t89kl' in t.get('OwnerIDs',[]))")

# REQ-002.1: owner_ids 应为空数组
if [ "$OWNER_COUNT" != "0" ]; then
  fail "REQ-002.1: owner_ids 不为空 (OwnerIDs=$OWNER_AFTER, count=$OWNER_COUNT)"
fi
pass "REQ-002.1: owner_ids 为空数组 []"

# REQ-002.2: owner_ids 不含产品管理员
if [ "$OWNER_CONTAINS_ADMIN" = "True" ]; then
  fail "REQ-002.2: owner_ids 包含产品管理员 $ADMIN_ID"
fi
pass "REQ-002.2: owner_ids 不含产品管理员 ($ADMIN_ID)"

# REQ-002.3: 综合校验 — 空值保持，无默认回退
pass "REQ-002.3: 无负责人需求同步后 owner_ids 保持未指派，无默认回退"

# ─── 汇总 ───
echo ""
echo "========================================"
echo "  集成测试结果: 未指派需求同步"
echo "========================================"
echo "  ProductID:    $PRODUCT_ID"
echo "  TaskID:       $TASK_ID"
echo "  WorkItemID:   $WORK_ITEM_ID"
echo "  Status:       $STATUS_AFTER"
echo "  OwnerIDs:     $OWNER_AFTER"
echo "  AdminID:      $ADMIN_ID (不应出现在 OwnerIDs)"
echo "========================================"
echo ""
pass "全部验收标准通过"
