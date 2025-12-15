#!/bin/bash
set -euo pipefail

log() { printf "==> %s\n" "$*"; }

MISE_CONFIG="$HOME/.config/mise/config.toml"

log "mise ツールインストールを開始します"

if ! command -v mise &> /dev/null; then
  log "❌ mise コマンドが見つかりません。brew install mise を実行してください。"
  exit 1
fi
log "✓ mise が見つかりました: $(mise --version)"

if [ ! -f "$MISE_CONFIG" ]; then
  log "❌ mise 設定ファイルが見つかりません: $MISE_CONFIG"
  exit 1
fi

log "✓ 設定ファイルを確認: $MISE_CONFIG"
cat "$MISE_CONFIG"

log "config.toml に記載されたツールをインストール中..."
if mise install; then
  log "✓ すべてのツールのインストールが完了しました"
else
  log "❌ インストール中にエラーが発生しました"
  exit 1
fi

log "インストール済みのツール一覧"
mise list
