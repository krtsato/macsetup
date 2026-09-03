# CLAUDE.md

macOS 自動セットアップリポジトリ。Ansible + シェルスクリプト + Makefile で新規 Mac を開発環境として構築する。

## コマンド

```sh
# 初回セットアップ（Homebrew + Ansible 導入 → プレイブック実行）
make setup ANSIBLE_FLAGS='--ask-become-pass'

# Ansible プレイブック単体実行
make playbook ANSIBLE_FLAGS='--ask-become-pass'

# Markdown lint（編集後に必ず実行）
npx markdownlint-cli2 --config ~/dev/me/dotfiles/.markdownlint.yaml <file>
```

## アーキテクチャ

### 実行フロー

`make setup` → `scripts/install-brew-ansible.sh`（bootstrap）→ `ansible-playbook ansible/exec.yaml`

### Ansible ロール実行順序

1. **dotfiles_repo** — `~/dev/me/dotfiles` を clone/pull
2. **homebrew** — `~/dev/me/dotfiles/brewfile.me` から `brew bundle` でインストール → dump で同期
3. **macos** — `osx_defaults` / NVRAM でシステム設定
4. **dotfiles** — `link-symbolic-dotfiles.sh` でシンボリックリンク作成
5. **github** — `gh auth` 確認 + SSH 鍵生成・登録
6. **mise** — `install-mise-tools.sh` で言語ツールインストール
7. **go** — `go install` でバイナリインストール
8. **npm** — `npm install -g` でグローバルパッケージインストール（textlint 等）
9. **vscode** — `install-vscode-extensions.sh` で拡張機能インストール

### dotfiles リポジトリとの関係

- **Brewfile** (`~/dev/me/dotfiles/brewfile.me`) がパッケージの Source of Truth
- `ansible/roles/homebrew/vars/main.yaml` はドキュメント参照用の一覧
- Brewfile に追記したら vars/main.yaml と `.github/instructions/auto-setup/auto-setup.md` も同期する

## コーディング規約

### Ansible

- すべての `shell` タスクで PATH を明示的に制限する: `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`
- `changed_when` / `failed_when` を必ず定義し、冪等性を確保する
- sudo が必要なタスクは askpass パターン（一時ヘルパースクリプト経由）を使用する

### シェルスクリプト

- 先頭に `set -euo pipefail` を記述する
- ログ出力は `log()` 関数で `==>` プレフィクスを付ける
- 非対話モードを `SKIP_CONFIRM=1` 等の環境変数で制御する

### ドキュメント

- すべて日本語で記述する
- Markdown 編集後は必ず markdownlint を実行する
- パッケージ追加時は Brewfile / vars/main.yaml / auto-setup.md の 3 箇所を更新する
