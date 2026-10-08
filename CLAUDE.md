# CLAUDE.md

macOS 自動セットアップリポジトリ。Ansible ＋ シェルスクリプト ＋ Makefile で新しい Mac を開発環境にする。
設定ファイル自体は別リポジトリ（`~/dev/me/dotfiles`）が持ち、ここは**入れる手順**だけを持つ。

このファイルが正本。`AGENTS.md` と `.github/copilot-instructions.md` はここへのシンボリックリンク。

## コマンド

```sh
# 初回セットアップ（Homebrew + Ansible 導入 → プレイブック実行）
make setup ANSIBLE_FLAGS='--ask-become-pass'

# プレイブック単体
make playbook ANSIBLE_FLAGS='--ask-become-pass'

# Markdown lint（編集後に必ず）
npx markdownlint-cli2 --config ~/dev/me/dotfiles/.markdownlint.yaml <file>
```

## 実行フロー

`make setup` → `scripts/install-brew-ansible.sh`（bootstrap）→ `ansible-playbook ansible/exec.yaml`

## ロールの順序

| 順 | ロール | すること |
| --- | --- | --- |
| 1 | `dotfiles_repo` | `~/dev/me/dotfiles` を clone/pull → コミット前の認証情報検査（`core.hooksPath`）を設定 |
| 2 | `homebrew` | `~/dev/me/dotfiles/brewfile.me` から `brew bundle` → dump で同期 |
| 3 | `macos` | `osx_defaults` / NVRAM でシステム設定 |
| 4 | `dotfiles` | `link-symbolic-dotfiles.sh` でシンボリックリンク作成 |
| 5 | `github` | `gh auth` 確認 ＋ SSH 鍵の生成・登録 |
| 6 | `mise` | `install-mise-tools.sh` で言語ツール |
| 7 | `go` | `go install` でバイナリ |
| 8 | `npm` | `npm install -g` でグローバルパッケージ（textlint など） |
| 9 | `vscode` | `install-vscode-extensions.sh` で拡張機能 |
| 10 | `nightly_launcher` | `krtsato/watcher` を取得し、その `plan.json` の枠ごとに LaunchAgent を生成・登録 |

順序には依存がある。`nightly_launcher` は `gh` の認証（5）と `go`（7）が済んでいる必要がある。

## パッケージを足すとき — 3 か所を揃える

| 順 | ファイル | 役割 |
| --- | --- | --- |
| 1 | `~/dev/me/dotfiles/brewfile.me` | **正本** |
| 2 | `ansible/roles/homebrew/vars/main.yaml` | Ansible 変数（ドキュメント参照用の一覧） |
| 3 | `.github/instructions/auto-setup/auto-setup.md` | ドキュメント |

**いずれもアルファベット順。** 1 つだけ直すと、残りが黙って古くなる。

**書くのはコマンド名ではなく formula 名。** 両者が違うものがある。たとえば Google Workspace の `gws` は
`googleworkspace-cli` で入れる。`brew install gws` は git リポジトリをまとめて扱う別の道具で、同じ `gws` を入れて衝突する。

## 夜の起動 — 正本は watcher にある

投資のパイプラインは GitHub の定期実行ではなく**この Mac から**起こす（GitHub の予定は 12 分〜10 時間遅れ、
時刻を選べない）。つまり **Mac の設定がパイプラインの一部**で、買い替えて忘れると夜が丸ごと消える。

| | |
| --- | --- |
| **時刻・順序・依存・曜日の正本** | **`krtsato/watcher` の `cmd/nightly-launcher/plan.json`**。ここには書かない |
| この役がすること | その `plan.json` を読み、枠ごとに LaunchAgent を生成して登録する |
| 設計と運用 | [watcher の docs/launcher.md](https://github.com/krtsato/watcher/blob/main/docs/launcher.md) |

**`plan.json` を変えたら `make playbook` を流す。** LaunchAgent は設定時に時刻を書き出すので、
流し忘れると Mac は古い時刻で起き、起動役は「枠の時刻から離れすぎています」と言って**毎晩何もしない**。
見張りが数日後に報告するが、気づくのは遅れる。

## 規約

### Ansible

- `ansible.builtin.shell` では **PATH を明示的に制限する**: `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`
- `changed_when` / `failed_when` を必ず定義し、冪等性を確保する
- sudo が必要なタスクは **askpass ヘルパーパターン**（一時ヘルパースクリプト経由）を使う
  — `ansible/roles/homebrew/tasks/main.yaml` 参照

### シェルスクリプト

- 先頭に `set -euo pipefail`
- ログは `log()` 関数で `==>` を付ける
- 非対話モードは環境変数（`SKIP_CONFIRM=1` など）で制御する

### 言語

**コメント・コミットメッセージ・ドキュメントはすべて日本語。**

### Markdown

編集後に必ず `npx markdownlint-cli2 --config ~/dev/me/dotfiles/.markdownlint.yaml <file>`。

## ディレクトリ構成

```text
macsetup/
├── Makefile                    # オーケストレーション
├── ansible/
│   ├── exec.yaml               # メインプレイブック（ロールの順序はここ）
│   ├── hosts                   # localhost のみ
│   └── roles/                  # 10 ロール
│       ├── dotfiles_repo/      # dotfiles の clone/pull + hooks 設定
│       ├── homebrew/           # Brewfile によるパッケージ管理
│       ├── macos/              # macOS システム設定
│       ├── dotfiles/           # シンボリックリンク作成
│       ├── github/             # GitHub CLI 認証 + SSH 鍵
│       ├── mise/               # 言語ツール
│       ├── go/                 # Go バイナリ
│       ├── npm/                # グローバルパッケージ
│       ├── vscode/             # VSCode 拡張機能
│       └── nightly_launcher/   # 夜の起動の LaunchAgent
└── scripts/                    # Ansible から呼び出されるスクリプト群
```
