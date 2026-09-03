# AGENTS.md

macOS 自動セットアップリポジトリにおける AI エージェント向けの共通指示。

## プロジェクト概要

Ansible + シェルスクリプト + Makefile で macOS の開発環境構築を自動化するリポジトリ。
パッケージ管理は Homebrew、設定ファイルは別リポジトリ (`~/dev/me/dotfiles`) で管理する。

## 重要な規約

### パッケージ追加・削除時の更新対象

Homebrew パッケージを変更する場合、以下の 3 ファイルをすべて更新する:

1. `~/dev/me/dotfiles/brewfile.me` — Source of Truth（アルファベット順）
2. `ansible/roles/homebrew/vars/main.yaml` — Ansible 変数（アルファベット順）
3. `.github/instructions/auto-setup/auto-setup.md` — ドキュメント（アルファベット順）

### Ansible タスクの書き方

- `ansible.builtin.shell` では PATH を必ず明示する
- `changed_when` と `failed_when` を定義して冪等性を保つ
- sudo が必要な場面では askpass ヘルパーパターンを踏襲する

### シェルスクリプトの書き方

- `set -euo pipefail` を必ず先頭に記述する
- ログは `log()` 関数で統一する
- 非対話実行は環境変数（`SKIP_CONFIRM=1` など）で制御する

### ドキュメント

- すべて日本語で記述する
- Markdown 編集後は `npx markdownlint-cli2 --config ~/dev/me/dotfiles/.markdownlint.yaml <file>` を実行する

## ディレクトリ構成

```text
macsetup/
├── Makefile                    # オーケストレーション
├── ansible/
│   ├── exec.yaml               # メインプレイブック
│   ├── hosts                   # localhost のみ
│   └── roles/                  # 8 ロール（実行順序は exec.yaml 参照）
│       ├── dotfiles_repo/      # dotfiles リポジトリの clone/pull + hooks 設定
│       ├── homebrew/           # Brewfile によるパッケージ管理
│       ├── macos/              # macOS システム設定
│       ├── dotfiles/           # シンボリックリンク作成
│       ├── github/             # GitHub CLI 認証 + SSH 鍵
│       ├── mise/               # 言語ツールインストール
│       ├── go/                 # Go バイナリインストール
│       └── vscode/             # VSCode 拡張機能
└── scripts/                    # Ansible から呼び出されるスクリプト群
```
