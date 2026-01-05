# Macbook Setup

`.github/instructions/auto-setup/auto-setup.md` の内容を Ansible + シェル + Makefile で自動化するためのリポジトリです。GUI 設定など手作業が必要な箇所はそのまま残しています。

## セットアップ手順

| 手順 | 内容                                    | コマンド/補足                                                                                                                                |
| ---- | --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | Xcode Command Line Tools をインストール | `xcode-select --install`                                                                                                                     |
| 2    | macsetup リポジトリを clone             | `git clone https://github.com/krtsato/macsetup.git ~/dev/me/macsetup`                                                                        |
| 3    | 秘匿ファイルを配置                      | `~/.aws`, `~/.ssh`, `~/.claude.json`, `~/.gitconfig`, `~/.npmrc`, `~/.wakatime.cfg` など                                                     |
| 4    | ワンコマンド実行                        | `make setup ANSIBLE_FLAGS='--ask-become-pass'`（非対話にしたい場合は `make setup EXTRA_VARS="homebrew_sudo_password=YOUR_PASSWORD"` でも可） |

## Make タスク

| ターゲット       | 目的                                    | 例                                                                                         |
| ---------------- | --------------------------------------- | ------------------------------------------------------------------------------------------ |
| `make setup`     | `bootstrap` 実行後にプレイブックを実行  | 初回セットアップに推奨                                                                     |
| `make bootstrap` | Homebrew と Ansible を導入              | 初回のみ                                                                                   |
| `make playbook`  | `ansible/exec.yaml` を localhost に実行 | `make playbook ANSIBLE_FLAGS='--ask-become-pass' EXTRA_VARS="github_ssh_key_type=ed25519"` |
| `make help`      | 簡易ヘルプ表示                          |                                                                                            |

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

| 順序 | ロール          | 役割                                                                                                                                                                                                                                                                                   |
| ---- | --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | `dotfiles_repo` | `~/dev/me/dotfiles` を clone/pull（Brewfile 取得含む）                                                                                                                                                                                                                                 |
| 2    | `homebrew`      | Brewfile でインストール → 同ファイルに dump                                                                                                                                                                                                                                            |
| 3    | `macos`         | `osx_defaults` で macOS 設定適用（ダークモード固定、キーリピート高速(InitialKeyRepeat=13/KeyRepeat=1)、トラックパッド速度最速、Dock アプリ初期化、Finder 表示(隠しファイル/拡張子/ステータスバー/パスバー)、バッテリー残量表示、スクショ保存設定(名前img/日付なし/~/Desktop/tmp)など） |
| 4    | `dotfiles`      | `./scripts/link-symbolic-dotfiles.sh` を非対話実ｓ>行                                                                                                                                                                                                                                  |
| 5    | `github`        | gh ログイン確認 → `setup-github-ssh.sh` で鍵登録                                                                                                                                                                                                                                       |
| 6    | `mise`          | `./scripts/install-mise-tools.sh`                                                                                                                                                                                                                                                      |
| 7    | `go`            | Go ツールを `go install`（mise shims を PATH に含めて実行）                                                                                                                                                                                                                            |
| 8    | `vscode`        | `./scripts/install-vscode-extensions.sh`                                                                                                                                                                                                                                               |

補足: Brewfile は dotfiles リポジトリで管理し、`link-symbolic-dotfiles.sh` が `~/brewfile.me` へリンクします。プレイブック内のシェルは必要最小限の PATH で実行する設計です。

## 手動作業

CLI では変更できない、または sudo 権限が必要な項目は GUI で設定する。

| 項目                   | 設定内容                                                                                                                   |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| アクセシビリティ表示   | 視差効果を減らす、透明度を下げる、ポインタサイズを拡大、ポインタスクロール各種最速                                         |
| コンピュータ名         | krtsato-macbook{model}-yyyy                                                                                                |
| ディスプレイ           | 外付けディスプレイ解像度                                                                                                   |
| ディスプレイ           | Night Shift スケジュール設定                                                                                               |
| 日付と時計             | 日付を表示                                                                                                                 |
| 通知                   | 編集                                                                                                                       |
| Finder                 | サイドバー表示項目                                                                                                         |
| iCloud                 | サインイン・各項目の同期設定                                                                                               |
| Raycast                | 設定のインポート                                                                                                           |
| Microsoft Office       | インストール                                                                                                               |
| 旧 PC からのデータ移行 | 経理書類など                                                                                                               |
| GitHub ブラウザ認証    | `gh auth login` はブラウザ操作が必要。未ログインだと `github` ロールが停止するので先に完了する                             |
| Touch ID               | 指紋を追加（System Settings > Touch ID & Password）                                                                        |
| 入力ソース             | Google 日本語入力を有効化し、英字/かな切替を設定（System Settings > Keyboard > Input Sources）                             |
| Terminal フォント      | Terminal.app のプロファイルで VSCode の settings.json と同等の Nerd Font（例: FiraCodeNerdFontCompleteM-Retina）を手動設定 |

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
