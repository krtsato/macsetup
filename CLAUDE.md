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

# 点検（読むだけ。PHASE は pre-import / cutover / ready、既定 ready）
make doctor PHASE=ready

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
| 6 | `repos` | 夜間の自動実行が前提にする手元の複製 9 本を、無いものだけ複製（場所は GitHub の変数から読む。既存は触らない） |
| 7 | `mise` | `install-mise-tools.sh` で言語ツール |
| 8 | `uv_tools` | `uv tool install` で版を固定した道具（NotebookLM の `nlm`） |
| 9 | `go` | `go install` でバイナリ |
| 10 | `npm` | `npm install -g` でグローバルパッケージ（textlint など） |
| 11 | `vscode` | `install-vscode-extensions.sh` で拡張機能 |
| 12 | `runners` | 自前の実行役 5 体を登録し、常駐の設定（plist）まで作る。**起動は `runners_enabled=true` のときだけ**（既定は停止。動いているものは決して止めない） |
| 13 | `nightly_launcher` | `krtsato/watcher` を取得し、その `plan.json` の枠ごとに LaunchAgent を生成・登録。**読み込むのは `nightly_launcher_enabled=true` か、既に読み込み済みの枠だけ** |
| 14 | `moomoo` | moomoo の接続役 OpenD のログ掃除 LaunchAgent を入れ、SDK のコンテナ image が無ければ作る。OpenD 本体は手で入れる |

順序には依存がある。`nightly_launcher` は `gh` の認証（5）と `go`（9）が済んでいる必要がある。`repos` は `gh` の認証（5）の後。`runners` は `gh` の認証（5）と複製（6）・mise（7）の後。`moomoo` は trade-moomoo の複製が要る。

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

## 実行役と起動役 — 停止した状態で用意する

新しい Mac では**登録と常駐の設定までを作り、起動しない**（既定 `runners_enabled: false`・`nightly_launcher_enabled: false`）。
旧端末と同じ夜を二重に起動しないよう、起動は切り替えの手順（段 6）の最後に、旧端末が空になったのを確かめてから行う。

```sh
# 切り替えの時だけ。実行役と起動役を起動する
make playbook EXTRA_VARS='runners_enabled=true nightly_launcher_enabled=true'
```

| 決まり | |
| --- | --- |
| 一覧 | `roles/runners/defaults/main.yaml` の `runners_list`。`roles/doctor/vars/main.yaml` の `doctor_runners` と同じ内容（足し引きしたら両方直す） |
| 名前 | `<ラベル>-<端末名>`（`scutil --get LocalHostName`、`runners_name_suffix` で上書き）。`--replace` は使わない |
| 取得 | `runners_version`（既定 `latest`、`2.338.0` のように固定も可）の配布物を `gh api` で取り、リリース本文の SHA-256 と照合。一致しない・無いときは展開せず失敗。固定しても自動更新は有効 |
| 途中の跡 | `.runner` が無いのに置き場が空でないときは、検証していない `config.sh` へ鍵を渡さないよう失敗する（消すのは人） |
| 冪等 | `.runner` がある（登録済み）なら取得も登録もしない。この Mac で流しても既存の実行役は止まらない |
| 雛形 | 実体のある `bin*/actions.runner.plist.template` を `SessionCreate=false` に直す。自動更新で増える `bin.<版>` の雛形は true に戻るが、点検が見るのは常駐側の plist |
| `.path` | 先頭を mise の shims にする（無ければ作り、あれば残りを保って先頭に足す）。`.env` は触らない |
| 起動 | `runners_enabled` が真のときだけ `launchctl bootstrap` し、今回起動したものは GitHub 上で online になるまで待つ（`runners_online_timeout` 既定 120 秒・`runners_online_interval` 既定 5 秒。来なければ名前つきで失敗）。偽のときは何もしない |
| 起動役 | plist は常に作る。読み込むのは `nightly_launcher_enabled` が真か、その枠が既に読み込み済みのとき（この Mac は `plan.json` の変更後に読み直す動きを保つ） |
| 登録鍵 | 使い捨て。`no_log: true` で、`config.sh` へ渡すだけ。ファイルにもログにも残さない |
| 検査 | `scripts/test-nightly-launcher.sh`（起動役の読み込み規則 4 通り）と `scripts/test-runners.sh`（偽の `gh`・`launchctl`・`config.sh` で、登録の引数・鍵が出力に出ないこと・SHA 不一致での失敗・起動が 1 回だけ・online 待ち・版の固定・途中の跡で止まること・登録済みで何もしないことを確かめる） |

## 点検 `make doctor`

`ansible/doctor.yaml`（ロール `doctor`）。**読むだけで何も変更しない**（全タスク `changed_when: false`）。`exec.yaml` には入れない。

| 項目 | 場所・決まり |
| --- | --- |
| 一覧の正本 | `ansible/roles/doctor/vars/main.yaml`（パス・分類・権限・用途・実行役・入口ファイル。**中身の値は持たない**） |
| 点検の本体 | `ansible/roles/doctor/files/checks.sh`（グループごとに `FAIL\|`・`WARN\|` の行を出し、Ansible が溜めて最後に一覧と失敗にする） |
| 段階 | `doctor_phase` = `pre-import` / `cutover` / `ready`（既定 `ready`、不正値は即失敗） |
| テスト用の差し込み | `doctor_home`・`doctor_launchagents_dir`・`doctor_extra_config_files`・`doctor_clone_dir_overrides` |
| 壊して確かめる | `scripts/test-doctor.sh`（欠けた必須ファイル・存在しない複製・`SessionCreate=true` の plist を名指しで検出するか） |

- **公開リポジトリなので**秘密の値・NotebookLM のプロファイル名を書かない。プロファイル名と複製の場所は GitHub の変数から実行時に読む
- 入口ファイルの一覧は、ワークフローの `$X_CLONE_DIR/...`・`git archive origin/main`・`git show` の使い方から導出する。呼び出し先が動いたらここも直す
- プロファイル名は `checks.sh` の shell 変数の中だけで持ち、出力・Ansible の変数へ出さない（`プロファイル1` などの別名で表示。`scripts/test-doctor.sh` が全出力を探して 0 件を確かめる）
- ログインは実行役と同じ環境（`env -i` ＋ 実行役の `.path`）でも確かめる。キーチェーンのセッションの差は plist の `SessionCreate=false` の点検が受け持ち、launchd から起こした process での確認は段 6 の実際の実行でしかできない（launchd の仕事は作らない）
- OpenD は日本時間の日時で判定する。ready では土曜 01:30〜月曜 01:30 以外の閉鎖を失敗にする（`DOCTOR_NOW` / `doctor_now` で上書き可）
- GitHub の秘密 6 組は「移行に必須の組」であって全設定の棚卸しではない

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
│   ├── doctor.yaml             # 点検プレイブック（読むだけ）
│   ├── hosts                   # localhost のみ
│   └── roles/                  # 15 ロール
│       ├── dotfiles_repo/      # dotfiles の clone/pull + hooks 設定
│       ├── homebrew/           # Brewfile によるパッケージ管理
│       ├── macos/              # macOS システム設定
│       ├── dotfiles/           # シンボリックリンク作成
│       ├── github/             # GitHub CLI 認証 + SSH 鍵
│       ├── repos/              # 夜間の自動実行が前提にする手元の複製
│       ├── mise/               # 言語ツール
│       ├── uv_tools/           # 版を固定した uv の道具（nlm）
│       ├── go/                 # Go バイナリ
│       ├── npm/                # グローバルパッケージ
│       ├── vscode/             # VSCode 拡張機能
│       ├── runners/            # 自前の実行役の登録と常駐設定（起動は切り替えの時だけ）
│       ├── nightly_launcher/   # 夜の起動の LaunchAgent
│       ├── moomoo/             # OpenD のログ掃除と SDK の image
│       └── doctor/             # 点検（exec.yaml には入れない）
└── scripts/                    # Ansible から呼び出されるスクリプト群
```
