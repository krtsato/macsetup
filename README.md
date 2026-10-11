# Macbook Setup

`.github/instructions/auto-setup/auto-setup.md` の内容を Ansible + シェル + Makefile で自動化するためのリポジトリです。GUI 設定など手作業が必要な箇所はそのまま残しています。

## セットアップ手順

| 手順 | 内容                                    | コマンド/補足                                                                                                                                |
| ---- | --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | Xcode Command Line Tools をインストール | `xcode-select --install`                                                                                                                     |
| 2    | Rosseta が必要な場合はインストール      | `softwareupdate --install-rosetta --agree-to-license`（M4 Macbook では不要）                                                                 |
| 3    | macsetup リポジトリを clone             | `git clone https://github.com/krtsato/macsetup.git ~/dev/me/macsetup`                                                                        |
| 4    | 秘匿ファイルを配置                      | `~/.aws`, `~/.ssh`, `~/.claude.json`, `~/.gitconfig`, `~/.npmrc`, `~/.wakatime.cfg` など                                                     |
| 5    | ワンコマンド実行                        | `make setup ANSIBLE_FLAGS='--ask-become-pass'`（非対話にしたい場合は `make setup EXTRA_VARS="homebrew_sudo_password=YOUR_PASSWORD"` でも可） |

## Make タスク

| ターゲット | 目的 | 例 |
| --- | --- | --- |
| `make setup` | `bootstrap` 実行後にプレイブックを実行 | 初回セットアップに推奨 |
| `make bootstrap` | Homebrew と Ansible を導入 | 初回のみ |
| `make playbook` | `ansible/exec.yaml` を localhost に実行 | `make playbook ANSIBLE_FLAGS='--ask-become-pass' EXTRA_VARS="github_ssh_key_type=ed25519"` |
| `make doctor` | 状態の点検（読むだけ） | `make doctor PHASE=pre-import` |
| `make secrets-list` | 運ぶ物と実行役・起動役の停止状態を表示（何も作らない） | `make secrets-list` |
| `make secrets-export` | 秘密と記録を暗号化イメージへ（旧端末） | `make secrets-export OUT=$HOME/Desktop/macsetup-secrets.dmg` |
| `make secrets-import` | イメージの中身を置く（新端末。全部か何もなしか） | `make secrets-import IMAGE=/Volumes/USB/macsetup-secrets.dmg` |
| `make secrets-restore` | 今ある物を退避して、イメージの中身で置き換える | `make secrets-restore IMAGE=/Volumes/USB/macsetup-secrets.dmg` |
| `make help` | 簡易ヘルプ表示 | - |

主要な変数

| 変数                           | 用途                                                                        | デフォルト/例                            | 必須か |
| ------------------------------ | --------------------------------------------------------------------------- | ---------------------------------------- | ------ |
| `ANSIBLE_FLAGS` / `EXTRA_VARS` | `ansible-playbook` の追加オプション                                         | `EXTRA_VARS="sudo_pass=..."` など        | 任意   |
| `sudo_pass`                    | Homebrew/macOS ロールで sudo を非対話実行するためのパスワード               | （空、非対話で実行したい場合は指定する） | 任意   |
| `SSH_KEY_TYPE`                 | GitHub 鍵タイプ（`make playbook` 時の `github_ssh_key_type` に対応）        | `ed25519`                                | 任意   |
| `GITHUB_EMAIL`                 | GitHub 鍵コメント用メール（`make playbook` 時の `github_ssh_email` に対応） | 空（省略可）                             | 任意   |

補足:

- macOS ロールで NVRAM を触るため、sudo パスワード指定（`sudo_pass` か `--ask-become-pass`）が必須。
- GitHub ロール中に未ログインなら `gh auth login -h github.com -s admin:public_key` を求めるプロンプトが出るので、従ってブラウザ認証する。
- dotfiles ロールは `SKIP_CONFIRM=1` で `link-symbolic-dotfiles.sh` を非対話実行（手動実行時は確認プロンプトあり）。
- mise ロールは `.ssh/config` のパーミッションを 600 に自動修正してからインストールを実行し、ダウンロードの一時失敗時にはリトライします。
- macOS ロールでデフォルトシェルを設定する際は、Homebrew の zsh (`/opt/homebrew/bin/zsh`) が存在すればそちらを優先し、無ければ `/bin/zsh` を設定します。

### EXTRA_VARS の指定例

Homebrew/macOS の sudo パスワードと GitHub 鍵パラメータをまとめて指定し、完全非対話で実行する例:

```sh
make setup \
  EXTRA_VARS='sudo_pass=YOUR_PW github_ssh_key_type=ed25519 github_ssh_email=you@example.com'
```

※対話的にパスワード入力したい場合は EXTRA_VARS のパスワードを外し、`ANSIBLE_FLAGS='--ask-become-pass'` を付けて実行してください。

### 各種ファイル配置

秘匿情報や後続処理に必要な設定ファイルを配置する。

| ファイル・フォルダ名 | 配置先          |
| -------------------- | --------------- |
| .aws/                | ~/.aws/         |
| .azure/              | ~/.azure/       |
| .ssh/                | ~/.ssh/         |
| .claude.json         | ~/.claude.json  |
| .gitconfig           | ~/.gitconfig    |
| .npmrc               | ~/.npmrc        |
| .wakatime.cfg        | ~/.wakatime.cfg |
| etc...               | etc...          |

### GitHub ログイン/鍵登録

Ansible の `github` ロールが gh ログイン状態の確認と SSH 鍵作成/登録を処理します（ブラウザ認証が必要な場合はプロンプトに従ってください）。

## Ansible ロールの流れ

| 順序 | ロール | 役割 |
| --- | --- | --- |
| 1 | `dotfiles_repo` | `~/dev/me/dotfiles` を clone/pull（Brewfile 取得含む） |
| 2 | `homebrew` | Brewfile でインストール → 同ファイルに dump |
| 3 | `macos` | `osx_defaults` で macOS 設定適用（ダークモード固定、キーリピート高速(InitialKeyRepeat=13/KeyRepeat=1)、トラックパッド速度最速、Dock アプリ初期化、Finder 表示(隠しファイル/拡張子/ステータスバー/パスバー)、バッテリー残量表示、スクショ保存設定(名前img/日付なし/~/Desktop/tmp)など） |
| 4 | `dotfiles` | `./scripts/link-symbolic-dotfiles.sh` を非対話実行 |
| 5 | `github` | gh ログイン確認 → `setup-github-ssh.sh` で鍵登録 |
| 6 | `repos` | 手元の複製 9 本（実行役を置く 5 本・変数が指す 6 本・watcher の和）を無いものだけ SSH（`git@github.com:krtsato/<name>.git`）で複製。場所は GitHub の repo variable `*_CLONE_DIR` を実行時に読む。既存の複製は pull もせず、git でない・origin が違うときは止める |
| 7 | `mise` | `./scripts/install-mise-tools.sh` |
| 8 | `uv_tools` | `uv tool install` で版を固定した道具を入れる（NotebookLM の `nlm` 0.9.6。版は `roles/uv_tools/defaults`） |
| 9 | `go` | Go ツールを `go install`（mise shims を PATH に含めて実行） |
| 10 | `npm` | npm グローバルパッケージを `npm install -g`（mise shims を PATH に含めて実行）。textlint は Homebrew に formula がないため npm で導入する |
| 11 | `vscode` | `./scripts/install-vscode-extensions.sh` |
| 12 | `runners` | 自前の実行役 5 体を登録し、常駐の設定（plist）まで作る。起動は `runners_enabled=true` のときだけ（既定は停止） |
| 13 | `nightly_launcher` | `krtsato/watcher` を取得し、その `plan.json` の枠ごとに LaunchAgent を生成して登録。読み込むのは `nightly_launcher_enabled=true` か、既に読み込み済みの枠だけ |
| 14 | `moomoo` | trade-moomoo の定義から OpenD のログ掃除 LaunchAgent を入れ、SDK のコンテナ image `moomoo-sdk:latest` が無ければ作る（Docker Desktop が動いていなければ知らせて先へ進む） |

### 実行役と起動役の起動（切り替えの時だけ）

新しい Mac では、実行役（`runners`）と夜の起動役（`nightly_launcher`）は**登録と常駐の設定まで作り、起動しません**
（旧端末と同じ夜を二重に起動しないため）。旧端末が止まって空になったのを確かめてから、次を流します。

```sh
make playbook EXTRA_VARS='runners_enabled=true nightly_launcher_enabled=true'
```

登録済みの Mac（この Mac など）で既定のまま流しても、動いている実行役は止まりません。

### 夜の起動（`nightly_launcher`）

投資のパイプラインは、GitHub の定期実行ではなく**この Mac から**決まった時刻に起こします
（GitHub の予定は 12 分〜10 時間遅れ、時刻を選べないため）。つまり **Mac の設定がパイプラインの一部**で、
買い替えて設定を忘れると夜が丸ごと消えます。

| | |
| --- | --- |
| **時刻と順序の正本** | **`krtsato/watcher` の `cmd/nightly-launcher/plan.json`**。ここには書きません |
| この役がすること | その `plan.json` を読み、**枠ごとに** LaunchAgent を生成して登録する |
| 設計と運用 | [watcher の docs/launcher.md](https://github.com/krtsato/watcher/blob/main/docs/launcher.md) |

**正本をここに置かないのは、2 か所に書けば必ず片方が古くなるからです。** 時刻・順序・依存・曜日は
起動役のコードが解釈するものなので、そのコードの隣に置いています。

**`plan.json` を変えたら `make playbook` を流してください。** LaunchAgent は設定時に書き出されるので、
流し忘れると Mac は古い時刻で起き、起動役は「枠の時刻から離れすぎています」と言って**毎晩何もしません**。
見張り（`krtsato/watcher`）が数日後に報告しますが、気づくのは遅れます。

補足: Brewfile は dotfiles リポジトリで管理し、`link-symbolic-dotfiles.sh` が `~/brewfile.me` へリンクします。プレイブック内のシェルは必要最小限の PATH で実行する設計です。

## 点検（`make doctor`）

端末の状態を**読むだけ**で点検します（何も変更しません）。最初の失敗で止まらず、失敗と警告を溜めて、
最後に項目名（パス・リポジトリと名前・実行役）つきで一覧にし、失敗が 1 件でもあれば終了コードを非 0 にします。

```sh
make doctor                    # 稼働（既定）
make doctor PHASE=pre-import   # 持ち込み前
make doctor PHASE=cutover      # 切り替え中
scripts/test-doctor.sh         # 壊して確かめる検査
```

| 見るもの | 内容 |
| --- | --- |
| 秘密と記録 | `~/.config` 配下の認証・処理済みの記録・受け箱と `~/.codex/auth.json`。存在・種別・権限だけ（中身は読まない） |
| 手元の複製 | 各リポジトリの `*_CLONE_DIR`（8 組）を GitHub から読み、git の複製で origin が一致するか。ワークフローが呼ぶ入口ファイルも |
| 道具 | `nlm`（固定版）・`docker info`・Docker の host networking・`claude`・`codex`・`gh` |
| ログイン | `gh`・管理者権限・`codex`・`claude`・NotebookLM（終了コードだけを見る）。`gh`・`claude`・`codex` は実行役と同じ環境（`env -i` と実行役の `.path`）でも 1 回確かめる |
| GitHub 側 | 移行に必須の秘密と変数（名前の有無だけ。全設定の棚卸しではない） |
| 実行役・起動役 | `.path` の先頭が mise の shims・`SessionCreate=false`・停止/online・LaunchAgent の読み込み |
| 接続役 | OpenD `127.0.0.1:11111`（ready では土曜 01:30〜月曜 01:30 以外は失敗、その間と他の段階は警告。日本時間） |

段階ごとの期待:

| 項目 | `pre-import` | `cutover` | `ready` |
| --- | --- | --- | --- |
| 持ち込む秘密と記録・codex/NotebookLM のログイン | 無いことを期待（あれば衝突の警告） | 有る | 有る |
| 実行役 | 登録済み・停止中 | 登録済み・停止中 | GitHub 上で online・ラベル一致 |
| 起動役 | plist あり・停止中 | plist あり・停止中 | 読み込み済み |
| それ以外 | 必須 | 必須 | 必須 |

ログインの確認の限界: 実行役と同じ環境での確認は PATH と環境変数の差を拾う。キーチェーンのセッションの差は
plist の `SessionCreate=false` の点検が受け持つ。残る差（launchd から起こした process での確認）は、
段 6 の実際の実行でしか確かめられない（点検は launchd の仕事を作らない）。
NotebookLM のプロファイル名は出力へ出さず、`プロファイル1`・`プロファイル2` の別名で表示する。

点検の一覧（パス・分類・権限・用途・実行役・入口ファイル）の正本は `ansible/roles/doctor/vars/main.yaml` です。
複製の場所と NotebookLM のプロファイル名は書かず、GitHub の変数を実行時に読みます。
テスト用に `doctor_home`・`doctor_launchagents_dir`・`doctor_extra_config_files`・`doctor_clone_dir_overrides` を差し替えられます。

## 秘密と記録を運ぶ（段 2）

旧端末から新端末へ、**許可した一覧だけ**を暗号化ディスクイメージ（AES-256・APFS）で運びます。
新しい道具は要らず、**合言葉は `hdiutil` が端末で直接尋ねます**（引数にも環境変数にも渡しません）。
一覧の正本は点検と同じ `ansible/roles/doctor/vars/main.yaml` の `doctor_config_files` です（複製しません）。
**対話の端末から流してください**（Ansible・CI・バックグラウンドからは動きません。`hdiutil` が制御端末で合言葉を尋ねるため）。
`make secrets-*` は 2 段で動きます。まず Ansible が許可一覧を 0600 の一時ファイルへ書くだけ（`ansible/secrets.yaml`）、
次に `secrets.sh` を端末へ繋いだまま直接実行します。一時ファイルは成功でも失敗でも消します。
**公開リポジトリなので**、イメージはリポジトリの外へ作り（権限 0600）、秘密・ハッシュ・NotebookLM のプロファイル名は
出力へ出しません（`<プロファイル1>` などの別名で表示）。

```sh
make secrets-list                                         # 運ぶ物を確かめる（何も作らない）
make secrets-export OUT=$HOME/Desktop/macsetup-secrets.dmg  # 旧端末。OUT は絶対パスの .dmg で、まだ無いこと
make secrets-import IMAGE=/Volumes/USB/macsetup-secrets.dmg # 新端末。最後に make doctor PHASE=cutover を流す
make secrets-restore IMAGE=/Volumes/USB/macsetup-secrets.dmg # 旧端末へ戻すとき
scripts/test-secrets.sh                                   # 偽のホームでの検査
```

| 分類 | 運ぶ物 | 権限 |
| --- | --- | --- |
| `auth`（認証） | NotebookLM の cookie と `nlm` の認証・プロファイル、mediable・YouTube・TradingView の認証、`~/.codex/auth.json` | ファイル 0600・ディレクトリ 0700 |
| `state`（処理済みの記録） | YouTube 送信済み・字幕同期・NotebookLM 同期・詰まった字幕・（あれば）飛ばした動画。無いと送信済みの動画を全件再送する | 0600 |
| `inbox`（受け箱と保留） | 各 `notebooklm-inbox/`・`withheld-drafts/` をディレクトリごと | 0700 配下、ファイル 0600 |

`required: false` の項目は、あれば運びます。ディレクトリの中の `.DS_Store`・`.lock`・`*.lock` は運びません。

| 命令 | 動き |
| --- | --- |
| `export` | **実行役 5 体と起動役 2 枠が launchd に読み込まれていないこと**を確かめてから、一覧を集める。必須の物が欠けていたり、出力先がリポジトリの中・既に存在するときは何も作らず止まる。件数の目録 `MANIFEST.json` をイメージの中に入れる |
| `import` | イメージを読み取り専用で取り付け、目録と中身の一致と許可一覧の外の物が無いことを検査する。**衝突（置き先に既に在る物）を先にまとめて調べ、1 件でもあれば何も変えずに止まる**。ホーム直下の一時の置き場へ写して件数と権限を検査し、1 項目ずつ置きながら記録に書く。途中で失敗したら記録をたどって配置前へ戻す。イメージは成功でも失敗でも必ず取り外す。最後に `make doctor PHASE=cutover` を流し、その終了コードを返す |
| `restore` | `import` と同じ検査の後、置き先に在る物を `~/.macsetup-restore-backup-<日時>`（0700）へ退避してから置く。失敗したら退避した物を戻す。実行役・起動役が停止していることも要る |

運ばない物: **Claude と gh のログインはキーチェーンにあり、ファイルとして運べません**。新端末で手でログインし直します
（段 6）。watcher の `.launcher/state-*.json`（起動役の再開記録）も運びません。**切り替えは全枠が完了してからだけ**にします。
移行前の写し・`.local/`・`mcp-mediable/captions/` など、許可一覧に無い物も運びません。

`import` の途中で process が強制終了されたときは、ホーム直下の `.macsetup-import.*/journal` に配置の記録が残ります。
`placed` の行の物を消し、`backed` の行の物を元へ戻してください。

テスト専用の環境変数（`make` へ渡す。実運用では使わない）: `SECRETS_HOME`・`SECRETS_PROFILES_OVERRIDE`（JSON の配列）・
`SECRETS_PATH_PREFIX`（偽の `launchctl`）・`SECRETS_TEST_STDINPASS=1`（合言葉を標準入力から `-stdinpass` で渡す）・
`SECRETS_TEST_FAIL_AFTER`・`SECRETS_TEST_SKIP_DOCTOR`。`scripts/test-secrets.sh` は同じ `make secrets-*` を流し、
擬似端末（`script`）で対話の合言葉入力も確かめます。

## 手動作業

CLI では変更できない、または sudo 権限が必要な項目は GUI で設定する。

| 項目 | 設定内容 |
| --- | --- |
| アクセシビリティ表示 | 視差効果を減らす、透明度を下げる、ポインタサイズを拡大、ポインタスクロール各種最速 |
| コンピュータ名 | krtsato-macbook{model}-yyyy |
| ディスプレイ | 外付けディスプレイ解像度 |
| ディスプレイ | Night Shift スケジュール設定 |
| 日付と時計 | 日付を表示 |
| 通知 | 編集 |
| Finder | サイドバー表示項目 |
| iCloud | サインイン・各項目の同期設定 |
| Raycast | 設定のインポート |
| Microsoft Office | インストール |
| 旧 PC からのデータ移行 | 経理書類など |
| GitHub ブラウザ認証 | `gh auth login` はブラウザ操作が必要。未ログインだと `github` ロールが停止するので先に完了する |
| Touch ID | 指紋を追加（System Settings > Touch ID & Password） |
| 入力ソース | Google 日本語入力を有効化し、英字/かな切替を設定（System Settings > Keyboard > Input Sources） |
| Terminal フォント | Terminal.app のプロファイルで VSCode の settings.json と同等の Nerd Font（例: FiraCodeNerdFontCompleteM-Retina）を手動設定 |
| moomoo OpenD | <https://www.moomoo.com/download/OpenAPI> から GUI 版を入れ、ログインと二段階認証、待受を `127.0.0.1`・ポート `11111` に、**ログイン項目に登録**（再起動後も火〜土の夜間に要る）。**登録後に一度再起動し、`make doctor` で待受とログイン項目を確かめる**。詳細は trade-moomoo の README |
| Docker Desktop | 初回起動の同意、Settings → Resources → Network → **Enable host networking**（moomoo のコンテナが OpenD に届くため）。その後 `make playbook` を流し直すと image が作られる |

iCloud 同期項目

| 項目                     | 同期設定                                                                                  |
| ------------------------ | ----------------------------------------------------------------------------------------- |
| 写真                     | on                                                                                        |
| Drive                    | on                                                                                        |
| メモ                     | on                                                                                        |
| メッセージ               | on                                                                                        |
| メール                   | on                                                                                        |
| Mac を探す               | on                                                                                        |
| パスワード               | off                                                                                       |
| 連絡先                   | off                                                                                       |
| カレンダー               | off                                                                                       |
| リマインダー             | off                                                                                       |
| Safari                   | off                                                                                       |
| その他                   | off                                                                                       |
| Spotlight ショートカット | [⌘Space を無効化](https://support.apple.com/ja-jp/guide/mac-help/mchlp2864/14.0/mac/14.0) |
