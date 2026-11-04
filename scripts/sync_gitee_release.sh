#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GITEE_OWNER="${GITEE_OWNER:-Micestark}"
GITEE_REPO="${GITEE_REPO:-toss}"
VERSION="${VERSION:-${TOSS_VERSION:-}}"
DMG_PATH="${DMG_PATH:-$ROOT/dist/toss-$VERSION.dmg}"

if [[ -z "${GITEE_TOKEN:-}" ]]; then
  echo "✗ 缺少 GITEE_TOKEN，无法同步到 Gitee" >&2
  exit 1
fi
if [[ -z "$VERSION" ]]; then
  echo "✗ 缺少 VERSION（例如 VERSION=0.1.0）" >&2
  exit 1
fi
if [[ ! -f "$DMG_PATH" ]]; then
  echo "✗ 找不到安装包：$DMG_PATH" >&2
  exit 1
fi

API="https://gitee.com/api/v5/repos/${GITEE_OWNER}/${GITEE_REPO}"
TAG="v${VERSION}"
ASSET_NAME="$(basename "$DMG_PATH")"
TMP_JSON="$(mktemp -t toss-gitee-release)"
trap 'rm -f "$TMP_JSON"' EXIT

echo "→ 同步 $TAG / $ASSET_NAME 到 Gitee ${GITEE_OWNER}/${GITEE_REPO}"

STATUS="$(curl -sS -o "$TMP_JSON" -w '%{http_code}' \
  "${API}/releases/tags/${TAG}?access_token=${GITEE_TOKEN}")"

RELEASE_ID=""
if [[ "$STATUS" == "200" ]]; then
  RELEASE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$TMP_JSON")"
  echo "  复用已有 Release（id=$RELEASE_ID）"
elif [[ "$STATUS" == "404" ]]; then
  STATUS="$(curl -sS -o "$TMP_JSON" -w '%{http_code}' -X POST "${API}/releases" \
    --data-urlencode "access_token=${GITEE_TOKEN}" \
    --data-urlencode "tag_name=${TAG}" \
    --data-urlencode "name=Toss ${VERSION}" \
    --data-urlencode "target_commitish=main" \
    --data-urlencode "body=Release ${TAG}")"
  if [[ "$STATUS" != "200" && "$STATUS" != "201" ]]; then
    echo "✗ 创建 Gitee Release 失败（HTTP $STATUS）：" >&2
    cat "$TMP_JSON" >&2
    exit 1
  fi
  RELEASE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$TMP_JSON")"
  echo "  已创建 Release（id=$RELEASE_ID）"
else
  echo "✗ 查询 Gitee Release 失败（HTTP $STATUS）：" >&2
  cat "$TMP_JSON" >&2
  exit 1
fi

HAS_ASSET="$(python3 - "$TMP_JSON" "$ASSET_NAME" <<'PY'
import json
import sys

path, name = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception:
    print("0")
    raise SystemExit(0)

assets = data.get("assets") or []
print("1" if any(a.get("name") == name for a in assets) else "0")
PY
)"

if [[ "$HAS_ASSET" == "1" ]]; then
  echo "  附件已存在，跳过上传"
else
  STATUS="$(curl -sS -o "$TMP_JSON" -w '%{http_code}' \
    -X POST "${API}/releases/${RELEASE_ID}/attach_files" \
    -F "access_token=${GITEE_TOKEN}" \
    -F "file=@${DMG_PATH}")"
  if [[ "$STATUS" != "200" && "$STATUS" != "201" ]]; then
    echo "✗ 上传附件失败（HTTP $STATUS）：" >&2
    cat "$TMP_JSON" >&2
    exit 1
  fi
  echo "  已上传 $ASSET_NAME"
fi

echo "✓ Gitee 同步完成：${API}/releases/tag/${TAG}"
