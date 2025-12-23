#!/bin/zsh
set -euo pipefail

log() { printf "==> %s\n" "$*"; }

log "Ansible インストールを開始します"

# Xcode Command Line Tools の確認
if ! xcode-select -p >/dev/null 2>&1; then
  log "Xcode Command Line Tools が見つかりません。インストーラを起動します..."
  xcode-select --install || true
  log "インストールが完了したら、このスクリプトを再実行してください。"
  exit 1
fi
log "✓ Xcode Command Line Tools が見つかりました"

# Homebrew のインストール確認
if ! command -v brew &> /dev/null; then
  log "Homebrew をインストール中..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [ -f /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
else
  log "✓ Homebrew が見つかりました"
fi

# Ansible のインストール確認
if command -v ansible &> /dev/null; then
  log "✓ Ansible は既にインストールされています"
  exit 0
fi

# Ansible のインストール
log "Ansible をインストール中..."
brew install ansible

if command -v ansible &> /dev/null; then
  log "Ansible のインストールが完了しました"
  ansible --version | head -n 1
else
  log "❌ インストールに失敗しました"
  exit 1
fi
