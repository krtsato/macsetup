# Macbook Setup

`.github/instructions/auto-setup/auto-setup.md` の内容を Ansible + シェル + Makefile で自動化するためのリポジトリです。GUI 設定など手作業が必要な箇所はそのまま残しています。

## セットアップ手順

| 手順 | 内容 | コマンド/補足 |
| --- | --- | --- |
| 1 | Xcode Command Line Tools をインストール | `xcode-select --install` |
| 2 | macsetup リポジトリを clone | `git clone https://github.com/krtsato/macsetup.git ~/dev/me/macsetup` |
| 3 | 秘匿ファイルを配置 | `~/.aws`, `~/.ssh`, `~/.claude.json` など（`auto-setup.md` の表を参照） |
| 4 | ワンコマンド実行 | `make setup` |

## Make タスク

| ターゲット       | 目的                                    | 例                                                     |
| ---------------- | --------------------------------------- | ------------------------------------------------------ |
| `make setup`     | `bootstrap` 実行後にプレイブックを実行  | 初回セットアップに推奨                                 |
| `make bootstrap` | Homebrew と Ansible を導入              | 初回のみ                                               |
| `make playbook`  | `ansible/exec.yaml` を localhost に実行 | `make playbook EXTRA_VARS="github_ssh_key_type=ecdsa"` |
| `make help`      | 簡易ヘルプ表示                          |                                                        |

主要な変数

| 変数                           | 用途                                                                        | デフォルト/例                              |
| ------------------------------ | --------------------------------------------------------------------------- | ------------------------------------------ |
| `ANSIBLE_FLAGS` / `EXTRA_VARS` | `ansible-playbook` の追加オプション                                         | `EXTRA_VARS="github_setup_ssh=false"` など |
| `SSH_KEY_TYPE`                 | GitHub 鍵タイプ（`make playbook` 時の `github_ssh_key_type` に対応）        | `ed25519`                                  |
| `GITHUB_EMAIL`                 | GitHub 鍵コメント用メール（`make playbook` 時の `github_ssh_email` に対応） | 空（省略可）                               |

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

| 順序 | ロール          | 役割                                                        |
| ---- | --------------- | ----------------------------------------------------------- |
| 1    | `dotfiles_repo` | `~/dev/me/dotfiles` を clone/pull（Brewfile 取得含む）      |
| 2    | `homebrew`      | Brewfile でインストール → 同ファイルに dump                 |
| 3    | `macos`         | `osx_defaults` で macOS 設定適用                            |
| 4    | `dotfiles`      | `./scripts/link-symbolic-dotfiles.sh` を非対話実行          |
| 5    | `github`        | gh ログイン確認 → `setup-github-ssh.sh` で鍵登録            |
| 6    | `mise`          | `./scripts/install-mise-tools.sh`                           |
| 7    | `go`            | Go ツールを `go install`（mise shims を PATH に含めて実行） |
| 8    | `vscode`        | `./scripts/install-vscode-extensions.sh`                    |

## 手動作業

CLI では変更できない、または sudo 権限が必要な項目は GUI で設定する。

| 項目                   | 設定内容                                                                                       |
| ---------------------- | ---------------------------------------------------------------------------------------------- |
| コンピュータ名         | krtsato-macbook{model}-yyyy                                                                    |
| ディスプレイ           | 外付けディスプレイ解像度                                                                       |
| ディスプレイ           | Night Shift スケジュール設定                                                                   |
| 日付と時計             | 日付を表示                                                                                     |
| 通知                   | 編集                                                                                           |
| Finder                 | サイドバー表示項目                                                                             |
| iCloud                 | サインイン・各項目の同期設定                                                                   |
| Raycast                | 設定のインポート                                                                               |
| Microsoft Office       | インストール                                                                                   |
| 旧 PC からのデータ移行 | 経理書類など                                                                                   |
| GitHub ブラウザ認証    | `gh auth login` はブラウザ操作が必要。未ログインだと `github` ロールが停止するので先に完了する |

iCloud 同期項目

| 項目         | 同期設定 |
| ------------ | -------- |
| 写真         | on       |
| Drive        | on       |
| メモ         | on       |
| メッセージ   | on       |
| メール       | on       |
| Mac を探す   | on       |
| パスワード   | off      |
| 連絡先       | off      |
| カレンダー   | off      |
| リマインダー | off      |
| Safari       | off      |
| その他       | off      |

## 補足

- Brewfile は dotfiles リポジトリで管理し、`link-symbolic-dotfiles.sh` が `~/brewfile.me` へリンクします。
- プレイブック内のシェルは必要最小限の PATH で実行する設計です。
