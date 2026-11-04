#!/bin/sh
# 同步一个 GitHub Release 到 Gitee：推 tag、建 release、传 dmg。
#
# 用法：./sync-gitee-release.sh <tag> [dmg 路径]
# 例：./sync-gitee-release.sh v1.2.0 dist/toss-1.2.0.dmg
#
# CI 由 .github/workflows/gitee-sync.yml 自动调用，本机可用
# ./sync-gitee-all.sh 批量补历史版本。脚本是幂等的：
#   - tag 已在 Gitee 就跳过推送；
#   - release 已存在就复用 id；
#   - 同名附件已存在就不重复上传。
#
# 令牌：Gitee 私人令牌（projects 权限）。优先读 $GITEE_TOKEN，
# 其次读 ~/.config/toss/gitee-token（chmod 600）。
# 没有令牌时只打印指引并退出 0——Gitee 只是镜像，不能挡 GitHub 发布。
set -eu

TAG="${1:?usage: sync-gitee-release.sh <tag> [dmg]}"
REPO="Micestark/toss"
API="https://gitee.com/api/v5/repos/$REPO"
SLUG="toss"

TOKEN="${GITEE_TOKEN:-}"
TOKEN_FILE="$HOME/.config/$SLUG/gitee-token"
if [ -z "$TOKEN" ] && [ -f "$TOKEN_FILE" ]; then
    TOKEN="$(tr -d ' \n' < "$TOKEN_FILE")"
fi

if [ -z "$TOKEN" ]; then
    echo "⚠️  没有 Gitee 令牌，本次未同步。"
    echo "   1. 在 gitee.com 生成私人令牌，勾选 projects 权限"
    echo "   2. 本机兜底：echo '<token>' > $TOKEN_FILE && chmod 600 $TOKEN_FILE"
    echo "   3. CI 自动同步：gh secret set GITEE_TOKEN -R TonyMistark/toss"
    echo "   4. 配好后重跑本脚本或 Sync to Gitee workflow"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PUSH_LOG="$WORK/push.log"

DMG="${2:-}"
if [ -z "$DMG" ]; then
    if ! gh release download "$TAG" --pattern '*.dmg' --dir "$WORK" >/dev/null 2>&1; then
        echo "✗ $TAG 在 GitHub 上没有 dmg 附件，无法镜像" >&2
        exit 1
    fi
    DMG="$(ls "$WORK"/*.dmg | head -1)"
fi

if [ ! -f "$DMG" ]; then
    echo "✗ 找不到安装包：$DMG" >&2
    exit 1
fi

SIZE_MB=$(( ($(stat -f%z "$DMG" 2>/dev/null || stat -c%s "$DMG") + 1048575) / 1048576 ))
if [ "$SIZE_MB" -gt 100 ]; then
    echo "⚠️  $(basename "$DMG") 有 ${SIZE_MB} MiB，Gitee 附件上限为 100 MiB" >&2
fi

# 1. 推 tag。Gitee 需要先有对应 commit 才能挂 release。
if ! git rev-parse --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    git fetch --tags origin >/dev/null 2>&1 || true
fi
if ! git rev-parse --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "✗ 本地没有 tag ${TAG}，请先 git fetch --tags" >&2
    exit 1
fi

echo "→ 推送 tag ${TAG} 到 Gitee…"
# Gitee 的 HTTPS 用户名必须是真实账号名，否则会报 token username invalid。
PUSH_URL="https://${REPO%%/*}:$TOKEN@gitee.com/$REPO.git"
if git push "$PUSH_URL" "refs/tags/$TAG" >"$PUSH_LOG" 2>&1; then
    echo "  tag 已推送"
else
    if git ls-remote "$PUSH_URL" "refs/tags/$TAG" 2>/dev/null | grep -q "refs/tags/$TAG"; then
        echo "  tag 已在 Gitee"
    else
        echo "  ✗ tag 推送失败：" >&2
        cat "$PUSH_LOG" >&2
        exit 1
    fi
fi

# 1b. 补默认分支，避免镜像首页空白。失败只警告，不影响 release。
BRANCH="${GITEE_BRANCH:-main}"
if [ -n "$BRANCH" ]; then
    if git rev-parse --verify "refs/heads/$BRANCH" >/dev/null 2>&1; then
        if git push "$PUSH_URL" "refs/heads/$BRANCH" >/dev/null 2>&1 \
            || git ls-remote --heads "$PUSH_URL" "$BRANCH" 2>/dev/null | grep -q "refs/heads/$BRANCH"; then
            echo "  分支 ${BRANCH} 已同步"
        else
            echo "  ⚠ 分支推送失败——release 不受影响，镜像代码页可能滞后" >&2
        fi
    elif git rev-parse --verify "refs/remotes/origin/$BRANCH" >/dev/null 2>&1; then
        if git push "$PUSH_URL" "refs/remotes/origin/$BRANCH:refs/heads/$BRANCH" >/dev/null 2>&1; then
            echo "  分支 ${BRANCH} 已同步"
        else
            echo "  ⚠ 分支推送失败——release 不受影响，镜像代码页可能滞后" >&2
        fi
    fi
fi

# 2. 建 release，优先复用 GitHub 的标题与说明。
echo "→ 创建 Gitee Release ${TAG}…"
NAME="$(gh release view "$TAG" --json name --jq .name)"
BODY="$(gh release view "$TAG" --json body --jq .body)"
CREATE_RESPONSE="$(curl -sS -w '\n%{http_code}' -X POST "$API/releases" \
    --data-urlencode "access_token=$TOKEN" \
    --data-urlencode "tag_name=$TAG" \
    --data-urlencode "target_commitish=$TAG" \
    --data-urlencode "name=$NAME" \
    --data-urlencode "body=$BODY")"
CREATE_STATUS="$(printf '%s' "$CREATE_RESPONSE" | tail -n1)"
CREATE_BODY="$(printf '%s' "$CREATE_RESPONSE" | sed '$d')"

RELEASE_ID=""
if [ "$CREATE_STATUS" = "201" ]; then
    RELEASE_ID="$(printf '%s' "$CREATE_BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
else
    # Gitee 对不存在的 tag 可能返回 200 + null；刚推完 tag 也有索引窗口。
    # 这里轮询几次拿 id，拿不到才报错。
    for ATTEMPT in 1 2 3 4 5; do
        QUERY="$(curl -sS "$API/releases/tags/$TAG?access_token=$TOKEN" || true)"
        RELEASE_ID="$(printf '%s' "$QUERY" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = None
print(data.get("id", "") if isinstance(data, dict) else "")
' || true)"
        [ -n "$RELEASE_ID" ] && break
        sleep 2
    done
    if [ -z "$RELEASE_ID" ]; then
        echo "  ✗ 创建 release 失败（HTTP ${CREATE_STATUS}）：" >&2
        printf '%s\n' "$CREATE_BODY" >&2
        exit 1
    fi
    echo "  release 已存在，复用 id ${RELEASE_ID}"
fi
echo "  release id ${RELEASE_ID}"

# 3. 传附件；同名附件已存在就跳过，避免重跑堆重复文件。
ASSET_NAME="$(basename "$DMG")"
if curl -sS "$API/releases/tags/$TAG?access_token=$TOKEN" \
    | ASSET="$ASSET_NAME" python3 -c '
import json, os, sys
release = json.load(sys.stdin)
names = [a.get("attachment_name") or a.get("name") or "" for a in release.get("assets", [])]
sys.exit(0 if os.environ["ASSET"] in names else 1)
'
then
    echo "  附件 ${ASSET_NAME} 已在 Gitee，跳过上传"
    echo "✓ Gitee release 就绪：https://gitee.com/$REPO/releases/tag/$TAG"
    exit 0
fi

echo "→ 上传 ${ASSET_NAME}（${SIZE_MB} MiB）…"
UPLOAD_RESPONSE="$(curl -sS -X POST "$API/releases/$RELEASE_ID/attach_files" \
    -F "access_token=$TOKEN" \
    -F "file=@$DMG")"
UPLOAD_URL="$(printf '%s' "$UPLOAD_RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("browser_download_url", ""))')"
if [ -z "$UPLOAD_URL" ]; then
    echo "  ✗ 附件上传失败：" >&2
    printf '%s\n' "$UPLOAD_RESPONSE" >&2
    exit 1
fi

echo "✓ Gitee release 就绪：$UPLOAD_URL"
