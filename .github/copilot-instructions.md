# Copilot Instructions

macOS 自動セットアップリポジトリ（Ansible + シェルスクリプト + Makefile）。

## 言語

すべてのコメント、コミットメッセージ、ドキュメントを日本語で記述すること。

## パッケージ管理

Homebrew パッケージの追加・削除時は以下の 3 ファイルをアルファベット順で同期する:

1. `~/dev/me/dotfiles/brewfile.me`（Source of Truth）
2. `ansible/roles/homebrew/vars/main.yaml`
3. `.github/instructions/auto-setup/auto-setup.md`

## Ansible 規約

- `ansible.builtin.shell` タスクでは PATH を明示する: `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`
- `changed_when` / `failed_when` を定義して冪等性を保つ
- sudo が必要なタスクは askpass ヘルパーパターンを使用する（`homebrew/tasks/main.yaml` 参照）

## シェルスクリプト規約

- `set -euo pipefail` を必ず先頭に記述する
- ログ出力は `log()` 関数で `==>` プレフィクスを付ける
- 非対話モードは環境変数（`SKIP_CONFIRM=1` など）で制御する

## Markdown

編集後は `npx markdownlint-cli2 --config ~/dev/me/dotfiles/.markdownlint.yaml <file>` で検証する。
