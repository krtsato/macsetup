#!/bin/bash
set -euo pipefail

# 使い方: ./setup-github-ssh.sh [-t ed25519|ecdsa] [email]
# email 省略時は git config --global user.email を利用。無ければエラー終了。

log() { printf "==> %s\n" "$*"; }

KEY_TYPE="ed25519"
EMAIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--type)
      KEY_TYPE="$2"
      shift 2
      ;;
    *)
      EMAIL="$1"
      shift
      ;;
  esac
done

if [[ -z "$EMAIL" ]]; then
  EMAIL="$(git config --global user.email 2>/dev/null || true)"
fi

case "$KEY_TYPE" in
  ed25519)
    KEYGEN_ARGS=(-t ed25519)
    KEY_SUFFIX="ed25519"
    ;;
  ecdsa)
    KEYGEN_ARGS=(-t ecdsa -b 521)
    KEY_SUFFIX="ecdsa"
    ;;
  *)
    echo "鍵タイプは ed25519 または ecdsa を指定してください" >&2
    exit 1
    ;;
esac

# gh のインストール/ログイン確認（未ログインなら異常終了）
if ! command -v gh >/dev/null 2>&1; then
  log "gh が見つかりません。GitHub CLI をインストールしてください。"
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  log "gh が未ログインです。gh auth login を完了してから再実行してください。"
  exit 1
fi

if [[ -z "$EMAIL" ]]; then
  echo "メールアドレスが不明です。引数で指定するか git config --global user.email を設定してください。" >&2
  exit 1
fi

HOSTNAME="$(hostname | tr '[:upper:]' '[:lower:]' | tr -d '_-')"
# shellcheck disable=SC2088
KEY_PATH="~/.ssh/id_${KEY_SUFFIX}_github"
KEY_PATH_REAL="${KEY_PATH/#\~/$HOME}"
TITLE="macbook-${HOSTNAME}-$(date +%Y%m%d)-${KEY_SUFFIX}"

# SSH Key が無ければ生成
if [[ -f "$KEY_PATH_REAL" ]]; then
  log "既存の鍵を使用します: $KEY_PATH"
else
  log "SSH 鍵を生成します ($KEY_SUFFIX): $KEY_PATH"
  ssh-keygen "${KEYGEN_ARGS[@]}" -C "$EMAIL" -f "$KEY_PATH_REAL" -N ""
fi

# ssh-agent / keychain 登録
log "ssh-agent に鍵を登録します"
if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
  eval "$(ssh-agent -s)"
fi
ssh-add --apple-use-keychain "$KEY_PATH_REAL"

# ~/.ssh/config に GitHub 用設定が無ければ追加
log "$HOME/.ssh/config を確認します"
CONFIG_LINE="IdentityFile $KEY_PATH"
if ! grep -q "$CONFIG_LINE" "$HOME/.ssh/config" 2>/dev/null; then
  cat >> "$HOME/.ssh/config" <<EOF_CFG

Host github.com
  AddKeysToAgent yes
  UseKeychain yes
  $CONFIG_LINE
EOF_CFG
  log "$HOME/.ssh/config に設定を追加しました"
else
  log "$HOME/.ssh/config は既に設定済みです"
fi

# GitHub への登録
log "gh で認証済みです。公開鍵を登録します"
gh ssh-key add "$KEY_PATH_REAL.pub" --title "$TITLE"

log "完了。接続テスト: ssh -T git@github.com"
