#!/bin/sh
# 批量把 GitHub 上的正式 release 同步到 Gitee，旧版本优先。
#
# 用法：./sync-gitee-all.sh
#
# 日常发布由 .github/workflows/gitee-sync.yml 自动处理；本脚本用于
# 首次全量导入、CI 失败补跑、镜像长期断档后拉平。
#
# 令牌：GITEE_TOKEN 或 ~/.config/toss/gitee-token（chmod 600，projects 权限）。
set -eu
cd "$(dirname "$0")"

REPO="Micestark/toss"
API="https://gitee.com/api/v5/repos/$REPO"

TOKEN="${GITEE_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$HOME/.config/toss/gitee-token" ]; then
    TOKEN="$(tr -d ' \n' < "$HOME/.config/toss/gitee-token")"
fi
if [ -z "$TOKEN" ]; then
    echo "⚠️  没有 Gitee 令牌，未同步任何版本。"
    echo "   1. 在 gitee.com 生成私人令牌，勾选 projects 权限"
    echo "   2. echo '<token>' > $HOME/.config/toss/gitee-token && chmod 600 $HOME/.config/toss/gitee-token"
    echo "   3. 重跑 ./sync-gitee-all.sh"
    exit 0
fi

TAGS="$(gh release list --limit 200 --json tagName,isDraft,isPrerelease \
    --jq '[.[] | select(.isDraft | not) | select(.isPrerelease | not) | .tagName] | reverse | .[]')"
if [ -z "$TAGS" ]; then
    echo "✗ 没读到 GitHub 上的 release（gh 登录了吗？）" >&2
    exit 1
fi

SYNCED=0
SKIPPED=0
FAILED=""
for TAG in $TAGS; do
    ID="$(curl -sS "$API/releases/tags/$TAG?access_token=$TOKEN" 2>/dev/null \
        | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get("id","") if isinstance(d,dict) else "")
except Exception:
    print("")' 2>/dev/null || true)"
    if [ -n "$ID" ]; then
        echo "· ${TAG} 已在 Gitee，跳过"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    if ./sync-gitee-release.sh "$TAG"; then
        SYNCED=$((SYNCED + 1))
    else
        FAILED="$FAILED $TAG"
    fi
done

echo "✓ 完成：新同步 ${SYNCED} 个，已存在 ${SKIPPED} 个${FAILED:+，失败:${FAILED}}"
[ -z "$FAILED" ]
