# Macbook Setup

新しい Mac を開発環境にするための手順を、Ansible・シェル・Makefile で自動化したリポジトリです。
`.github/instructions/auto-setup/auto-setup.md`（入れるパッケージの一覧と、手で行う場合の命令）の内容を自動化しています。
GUI 設定など手作業が必要な箇所は、そのまま手作業として残しています（[手動作業](#手動作業)）。

| やりたいこと | 読む場所 |
| --- | --- |
| 新しい Mac を用意する | [新しい Mac を用意する](#新しい-mac-を用意する)（このファイル） |
| Mac を買い替えて、夜間の自動実行を移す | [Mac を買い替えて夜間の自動実行を移す](#mac-を買い替えて夜間の自動実行を移す) と [docs/cutover.md](docs/cutover.md) |
| 命令の一覧を見る | [Make タスク](#make-タスク) |
| 点検（`make doctor`）の詳細 | [docs/doctor.md](docs/doctor.md) |
| 秘密と記録を運ぶ（`make secrets-*`）の詳細 | [docs/secrets.md](docs/secrets.md) |
| AI エージェント向けの作業ガイド | [CLAUDE.md](CLAUDE.md) |

## 新しい Mac を用意する

上から順に行います。各手順は「何をするか → 命令 → うまくいった印」の順に書いています。

### 1. Xcode Command Line Tools を入れる

git などの基本の道具を入れます。

```sh
xcode-select --install
```

うまくいった印: `xcode-select -p` がパスを表示します。

### 2. Rosetta を入れる（必要な場合だけ）

Intel 向けのアプリが必要な Mac だけ行います（M4 Macbook では不要です）。

```sh
softwareupdate --install-rosetta --agree-to-license
```

### 3. このリポジトリを clone する

```sh
git clone https://github.com/krtsato/macsetup.git ~/dev/me/macsetup
cd ~/dev/me/macsetup
```

### 4. 秘匿ファイルを置く

認証情報など、リポジトリに入れられないファイルを先に置きます（`make setup` の途中で使うものがあるためです）。

| ファイル・フォルダ名 | 配置先 |
| --- | --- |
| .aws/ | ~/.aws/ |
| .azure/ | ~/.azure/ |
| .ssh/ | ~/.ssh/ |
| .claude.json | ~/.claude.json |
| .gitconfig | ~/.gitconfig |
| .npmrc | ~/.npmrc |
| .wakatime.cfg | ~/.wakatime.cfg |
| etc... | etc... |

旧い Mac から夜間の自動実行ごと移す場合は、この手順ではなく [docs/cutover.md](docs/cutover.md) に従ってください
（秘密と処理済みの記録を、暗号化イメージで運ぶ手順が入っています）。

### 5. `make setup` を実行する

Homebrew と Ansible を入れ（`make bootstrap`）、続けて Ansible のプレイブックで[各ロール](#ansible-のロールが行うこと)を順に実行します。

```sh
make setup ANSIBLE_FLAGS='--ask-become-pass'
```

標準はこの `--ask-become-pass`（その場でパスワードを尋ねる）です。
どうしても尋ねられたくない場合だけ、次のように渡せます。**パスワードがシェルの履歴とプロセスの一覧に残る**ので、使った後は履歴から消してください。

```sh
make setup EXTRA_VARS="sudo_pass=YOUR_PASSWORD"
```

途中で起きること:

- macOS ロールが NVRAM を触るため、sudo パスワード（`sudo_pass` か `--ask-become-pass`）が必須です
- GitHub ロールの途中で `gh` に未ログインだと、`gh auth login -h github.com -s admin:public_key` を求めるプロンプトが出ます。表示に従ってブラウザで認証します（先に済ませておくと止まりません）
- runner と夜間の起動は、**登録と常駐の設定まで作り、起動しません**（旧い Mac と同じ夜を二重に起動しないため。起動は[切り替えの時だけ](#runner-と夜間の起動の起動切り替えの時だけ)）

うまくいった印: プレイブックが最後まで終わり、失敗が 0 件です。

### 6. 手作業（GUI）を済ませる

CLI では変更できない設定です。[手動作業](#手動作業)の表を上から行います。
特に Docker Desktop と moomoo OpenD は、設定の後に `make playbook` を流し直す必要があります
（Docker の設定後に流し直すと、moomoo 用のコンテナ image が作られます）。

```sh
make playbook ANSIBLE_FLAGS='--ask-become-pass'
```

Claude にもログインします（ログインはキーチェーンに入るので、旧い Mac から運べません。点検は全 `PHASE` でこのログインを確かめます）。

```sh
claude auth login
claude auth status   # "loggedIn": true になれば済み
```

### 7. 点検する

この時点では、runner と夜間の起動はまだ止めてあり、秘密と処理済みの記録も旧い Mac から運んでいません。
その状態を期待する `PHASE=pre-import` で点検します。

```sh
make doctor PHASE=pre-import
```

うまくいった印: 最後の一覧で失敗が 0 件です。失敗があれば項目名つきで表示されるので、直してもう一度流します。
`PHASE` を付けない `make doctor`（稼働中の点検）は、[docs/cutover.md](docs/cutover.md) の手順で runner と夜間の起動を動かした後に使います。
それより前に流すと、runner が online でない・夜間の起動が読み込まれていない、として失敗するのが正しい結果です。
`make doctor` は読むだけで、何も変更しません。使い方の詳細は [docs/doctor.md](docs/doctor.md) にあります。

## Mac を買い替えて夜間の自動実行を移す

投資のパイプラインは、GitHub の定期実行ではなく**この Mac から**夜間に起こしています
（理由は[夜間の起動](#夜間の起動)）。買い替えて設定を忘れると、夜が丸ごと消えます。

手順書は [docs/cutover.md](docs/cutover.md) です（14 手順・戻し方つき）。流れは次の 3 つです。

| 流れ | 内容 |
| --- | --- |
| 新しい Mac を止めたまま組み立てる | `make setup` と各種ログインを済ませる。runner と夜間の起動は登録だけで起動しない |
| 旧い Mac を止めて記録を運ぶ | 旧い Mac が空になったことを確かめてから、秘密と処理済みの記録を暗号化イメージで運ぶ |
| 新しい Mac を動かして確かめる | runner と夜間の起動を起動し、試し実行と夜間の本番で成功を確かめてから、旧い Mac の登録を消す |

要点は「旧い Mac を止めて空になったことを確かめてから、新しい Mac の runner と夜間の起動を起動する」ことです。

## Make タスク

| ターゲット | 目的 | 例 |
| --- | --- | --- |
| `make setup` | `bootstrap` 実行後にプレイブックを実行 | 初回セットアップに推奨 |
| `make bootstrap` | Homebrew と Ansible を導入 | 初回のみ |
| `make playbook` | `ansible/exec.yaml` を localhost に実行 | `make playbook ANSIBLE_FLAGS='--ask-become-pass' EXTRA_VARS="github_ssh_key_type=ed25519"` |
| `make doctor` | 状態の点検（読むだけ） | `make doctor PHASE=pre-import` |
| `make secrets-list` | 運ぶ物と、runner・夜間の起動の停止状態を表示（何も作らない） | `make secrets-list` |
| `make secrets-export` | 秘密と記録を暗号化イメージへ（旧い Mac） | `make secrets-export OUT=$HOME/Desktop/macsetup-secrets.dmg` |
| `make secrets-import` | イメージの中身を置く（新しい Mac。全部か何もなしか） | `make secrets-import IMAGE=/Volumes/USB/macsetup-secrets.dmg` |
| `make secrets-restore` | 今ある物を退避して、イメージの中身で置き換える | `make secrets-restore IMAGE=/Volumes/USB/macsetup-secrets.dmg` |
| `make secrets-recover` | 強制終了で止まった import・restore の跡を配置前へ戻す（冪等） | `make secrets-recover` |
| `make cutover-trial` | 切り替えの試し実行の `gh workflow run` を出す（出すだけ・読むだけ） | `make cutover-trial` |
| `make cutover-check` | 完了の一覧（確認対象 21 件）が新しい Mac の runner で成功したか判定（読むだけ。pending があれば 0 以外で終わる） | `make cutover-check SINCE=2026-10-15 RUNNERS=<Mac の名前>` |
| `make help` | 簡易ヘルプ表示 | - |

### 主要な変数

| 変数 | 用途 | デフォルト/例 | 必須か |
| --- | --- | --- | --- |
| `ANSIBLE_FLAGS` / `EXTRA_VARS` | `ansible-playbook` の追加オプション | `EXTRA_VARS="sudo_pass=..."` など | 任意 |
| `sudo_pass` | Homebrew/macOS ロールで sudo を非対話実行するためのパスワード | （空、非対話で実行したい場合は指定する） | 任意 |
| `SSH_KEY_TYPE` | GitHub 鍵タイプ（`make playbook` 時の `github_ssh_key_type` に対応） | `ed25519` | 任意 |
| `GITHUB_EMAIL` | GitHub 鍵コメント用メール（`make playbook` 時の `github_ssh_email` に対応） | 空（省略可） | 任意 |

### EXTRA_VARS の指定例

`gh` にログイン済みのとき、sudo パスワードと GitHub 鍵のパラメータの入力を省く例です（`gh` に未ログインだと、`github` ロールがログインを待って止まります）。パスワードがシェルの履歴とプロセスの一覧に残る点は、上の注意と同じです。

```sh
make setup \
  EXTRA_VARS='sudo_pass=YOUR_PW github_ssh_key_type=ed25519 github_ssh_email=you@example.com'
```

対話的にパスワードを入力したい場合は、EXTRA_VARS のパスワードを外し、`ANSIBLE_FLAGS='--ask-become-pass'` を付けて実行してください。

### ロールごとの補足

- dotfiles ロールは `SKIP_CONFIRM=1` で `link-symbolic-dotfiles.sh` を非対話実行します（手動実行時は確認プロンプトあり）
- mise ロールは `.ssh/config` のパーミッションを 600 に自動修正してからインストールを実行し、ダウンロードの一時失敗時にはリトライします
- macOS ロールでデフォルトシェルを設定する際は、Homebrew の zsh（`/opt/homebrew/bin/zsh`）が存在すればそちらを優先し、無ければ `/bin/zsh` を設定します
- GitHub ログインと SSH 鍵の作成・登録は、Ansible の `github` ロールが gh のログイン状態を確認して処理します（ブラウザ認証が必要な場合はプロンプトに従ってください）
- Brewfile は dotfiles リポジトリの `~/dev/me/dotfiles/brewfile.me` で管理し、`homebrew` ロールがそれを直接読みます（ホーム直下へのリンクは作りません）
- プレイブック内のシェルは、必要最小限の PATH で実行する設計です

## Ansible のロールが行うこと

`make setup`（`make playbook`）は、次の順に実行します。

| 順序 | ロール | 役割 |
| --- | --- | --- |
| 1 | `dotfiles_repo` | `~/dev/me/dotfiles` を clone/pull（Brewfile 取得含む） |
| 2 | `homebrew` | Brewfile でインストール → 同ファイルに dump |
| 3 | `macos` | `osx_defaults` で macOS 設定適用（ダークモード固定、キーリピート高速(InitialKeyRepeat=13/KeyRepeat=1)、トラックパッド速度最速、Dock アプリ初期化、Finder 表示(隠しファイル/拡張子/ステータスバー/パスバー)、バッテリー残量表示、スクショ保存設定(名前img/日付なし/~/Desktop/tmp)など） |
| 4 | `dotfiles` | `./scripts/link-symbolic-dotfiles.sh` を非対話実行 |
| 5 | `github` | gh ログイン確認 → `setup-github-ssh.sh` で鍵登録 |
| 6 | `repos` | 手元の複製 9 本（runner を置く 5 本・変数が指す 6 本・watcher の和）を無いものだけ SSH（`git@github.com:krtsato/<name>.git`）で複製。場所は GitHub の repo variable `*_CLONE_DIR` を実行時に読む。既存の複製は pull もせず、git でない・origin が違うときは止める |
| 7 | `mise` | `./scripts/install-mise-tools.sh` |
| 8 | `uv_tools` | `uv tool install` で版を固定した道具を入れる（NotebookLM の `nlm` 0.9.6。版は `roles/uv_tools/defaults`） |
| 9 | `go` | Go ツールを `go install`（mise shims を PATH に含めて実行） |
| 10 | `npm` | npm グローバルパッケージを `npm install -g`（mise shims を PATH に含めて実行）。textlint は Homebrew に formula がないため npm で導入する |
| 11 | `vscode` | `./scripts/install-vscode-extensions.sh` |
| 12 | `runners` | 自前の runner（GitHub Actions の self-hosted runner）5 体を登録し、常駐の設定（plist）まで作る。起動は `runners_enabled=true` のときだけ（既定は停止） |
| 13 | `nightly_launcher` | `krtsato/watcher` を取得し、その `plan.json` の枠ごとに LaunchAgent を生成して登録。読み込むのは `nightly_launcher_enabled=true` か、既に読み込み済みの枠だけ |
| 14 | `moomoo` | trade-moomoo の定義から OpenD（moomoo の API ゲートウェイ）のログ掃除 LaunchAgent を入れ、SDK のコンテナ image `moomoo-sdk:latest` が無ければ作る（Docker Desktop が動いていなければ知らせて先へ進む） |

別の命令で動くロール（`make playbook` には入りません）:

| ロール | 命令 | 役割 |
| --- | --- | --- |
| `doctor` | `make doctor` | 点検（読むだけ）。[docs/doctor.md](docs/doctor.md) |
| `secrets` | `make secrets-*` | 秘密と記録の持ち出し・持ち込み。[docs/secrets.md](docs/secrets.md) |

### runner と夜間の起動の起動（切り替えの時だけ）

新しい Mac では、runner（`runners`）と夜間の起動（`nightly_launcher`）は**登録と常駐の設定まで作り、起動しません**
（旧い Mac と同じ夜を二重に起動しないため）。旧い Mac が止まって空になったのを確かめてから、次を流します。

```sh
make playbook EXTRA_VARS='runners_enabled=true nightly_launcher_enabled=true'
```

登録済みの Mac（この Mac など）で既定のまま流しても、動いている runner は止まりません。

### 夜間の起動

夜間の起動とは、決まった時刻に投資のパイプラインを起こす LaunchAgent（`nightly_launcher` ロールが作ります）です。
投資のパイプラインは、GitHub の定期実行ではなく**この Mac から**決まった時刻に起こします
（GitHub の予定は 12 分〜10 時間遅れ、時刻を選べないため）。つまり **Mac の設定がパイプラインの一部**で、
買い替えて設定を忘れると夜が丸ごと消えます。

| | |
| --- | --- |
| **時刻と順序の正本** | **`krtsato/watcher` の `cmd/nightly-launcher/plan.json`**。ここには書きません |
| ロールがすること | その `plan.json` を読み、**枠ごとに** LaunchAgent を生成して登録する |
| 設計と運用 | [watcher の docs/launcher.md](https://github.com/krtsato/watcher/blob/main/docs/launcher.md) |

**正本をここに置かないのは、2 か所に書けば必ず片方が古くなるからです。** 時刻・順序・依存・曜日は
夜間の起動のコードが解釈するものなので、そのコードの隣に置いています。

**`plan.json` を変えたら `make playbook` を流してください。** LaunchAgent は設定時に書き出されるので、
流し忘れると Mac は古い時刻で起き、夜間の起動は「枠の時刻から離れすぎています」と言って**毎晩何もしません**。
見張り（`krtsato/watcher`）が数日後に報告しますが、気づくのは遅れます。

## 手動作業

CLI では変更できない、または sudo 権限が必要な項目は GUI（画面の操作）で設定します。

| 項目 | 設定内容 |
| --- | --- |
| アクセシビリティ表示 | 視差効果を減らす、透明度を下げる、ポインタサイズを拡大、ポインタスクロール各種最速 |
| コンピュータ名 | krtsato-macbook{model}-yyyy |
| ディスプレイ | 外付けディスプレイ解像度 |
| ディスプレイ | Night Shift スケジュール設定 |
| 日付と時計 | 日付を表示 |
| 通知 | 編集 |
| Finder | サイドバー表示項目 |
| iCloud | サインイン・各項目の同期設定（下の表） |
| Raycast | 設定のインポート |
| Microsoft Office | インストール |
| 旧 PC からのデータ移行 | 経理書類など |
| GitHub ブラウザ認証 | `gh auth login` はブラウザ操作が必要。未ログインだと `github` ロールが停止するので先に完了する |
| Touch ID | 指紋を追加（System Settings > Touch ID & Password） |
| 入力ソース | Google 日本語入力を有効化し、英字/かな切替を設定（System Settings > Keyboard > Input Sources） |
| Terminal フォント | Terminal.app のプロファイルで VSCode の settings.json と同等の Nerd Font（例: FiraCodeNerdFontCompleteM-Retina）を手動設定 |
| moomoo OpenD | <https://www.moomoo.com/download/OpenAPI> から GUI 版を入れ、ログインと二段階認証、待受を `127.0.0.1`・ポート `11111` に、**ログイン項目に登録**（再起動後も火〜土の夜間に要る）。**登録後に一度再起動し、`make doctor PHASE=pre-import` で待受とログイン項目を確かめる**（切り替えの前なので `PHASE` を付ける）。詳細は trade-moomoo の README |
| Docker Desktop | 初回起動の同意、Settings → Resources → Network → **Enable host networking**（moomoo のコンテナが OpenD に届くため）。その後 `make playbook` を流し直すと image が作られる |

### iCloud 同期項目

| 項目 | 同期設定 |
| --- | --- |
| 写真 | on |
| Drive | on |
| メモ | on |
| メッセージ | on |
| メール | on |
| Mac を探す | on |
| パスワード | off |
| 連絡先 | off |
| カレンダー | off |
| リマインダー | off |
| Safari | off |
| その他 | off |
| Spotlight ショートカット | [⌘Space を無効化](https://support.apple.com/ja-jp/guide/mac-help/mchlp2864/14.0/mac/14.0) |

## つまずいたとき

| 症状 | 原因と直し方 |
| --- | --- |
| `github` ロールで止まる | `gh` が未ログイン。`gh auth login -h github.com -s admin:public_key` をブラウザ認証まで済ませてから、`make playbook` を流し直す |
| macOS ロールで失敗する | sudo パスワードが無い。`ANSIBLE_FLAGS='--ask-become-pass'` か `EXTRA_VARS="sudo_pass=..."` を付ける |
| moomoo のコンテナ image が作られない | Docker Desktop が動いていない（ロールは知らせて先へ進む）。起動して Enable host networking を設定し、`make playbook` を流し直す |
| 夜間の起動が毎晩何もしない | `plan.json` を変えた後に `make playbook` を流していない。流し直す |
| `make doctor` が失敗する | 失敗は項目名つきで一覧に出る。[docs/doctor.md](docs/doctor.md) の PHASE ごとの期待と見比べる |
| `make secrets-*` が「前回の途中で止まった跡がある」と言う | `make secrets-recover` を流す（[docs/secrets.md](docs/secrets.md)） |

## 検査（テスト）

| 命令 | 確かめること |
| --- | --- |
| `scripts/test-repos.sh` | 手元の複製の取得（無いものだけ複製・既存に触らない・git でない/origin が違うとき止まる） |
| `scripts/test-runners.sh` | runner の登録（偽の `gh`・`launchctl`・`config.sh` を使う） |
| `scripts/test-nightly-launcher.sh` | 夜間の起動の読み込み規則 |
| `scripts/test-cutover.sh` | 切り替えの道具（確認対象 21 件・試し実行 11 本・夜間で確かめる 7 本を固定） |
| `scripts/test-secrets.sh` | 秘密と記録の持ち出し・持ち込み（偽のホーム） |
| `scripts/test-doctor.sh` | 点検（壊して確かめる。遅い） |
