# Macbook Setup

`.github/instructions/auto-setup/auto-setup.md` の内容を Ansible + シェル + Makefile で自動化するためのリポジトリです。GUI 設定など手作業が必要な箇所はそのまま残しています。

## 準備

| 内容 | コマンド/場所 | 備考 |
| --- | --- | --- |
| リポジトリ取得・ディレクトリ作成 | `auto-setup.md` 冒頭を参照 | `~/dev/me` 配下 |
| Homebrew / Ansible インストール | `make bootstrap` または `./scripts/install-brew-ansible.sh` | CLT が無ければ `xcode-select --install` |
| 秘匿ファイル配置 | `~/.aws`, `~/.ssh`, `~/.claude.json` など | `auto-setup.md` の表を参照 |
| GitHub CLI ログイン | `gh auth login && gh auth status` | ブラウザ認証のみ、自動化なし |

## Make タスク

| ターゲット | 目的 | 例 |
| --- | --- | --- |
| `make bootstrap` | Homebrew と Ansible を導入 | 初回のみ |
| `make playbook` | `ansible/exec.yml` を localhost に実行 | `make playbook EXTRA_VARS="github_ssh_key_type=ecdsa"` |
| `make github-ssh` | GitHub SSH 鍵作成・登録スクリプト実行 | `make github-ssh SSH_KEY_TYPE=ecdsa GITHUB_EMAIL=you@example.com` |
| `make help` | 簡易ヘルプ表示 | |

主要な変数

| 変数 | 用途 | デフォルト/例 |
| --- | --- | --- |
| `ANSIBLE_FLAGS` / `EXTRA_VARS` | `ansible-playbook` の追加オプション | `EXTRA_VARS="github_setup_ssh=false"` など |
| `SSH_KEY_TYPE` | GitHub 鍵タイプ | `ed25519` |
| `GITHUB_EMAIL` | GitHub 鍵コメント用メール | 空（省略可） |

## Ansible ロールの流れ

| 順序 | ロール | 役割 |
| --- | --- | --- |
| 1 | `dotfiles_repo` | `~/dev/me/dotfiles` を clone/pull（Brewfile 取得含む） |
| 2 | `homebrew` | Brewfile でインストール → 同ファイルに dump |
| 3 | `macos` | `osx_defaults` で macOS 設定適用 |
| 4 | `dotfiles` | `./scripts/link-symbolic-dotfiles.sh` を非対話実行 |
| 5 | `github` | gh ログイン確認 → `setup-github-ssh.sh` で鍵登録 |
| 6 | `mise` | `./scripts/install-mise-tools.sh` |
| 7 | `go` | Go ツールを `go install`（mise shims を PATH に含めて実行） |
| 8 | `vscode` | `./scripts/install-vscode-extensions.sh` |

## 手動作業

| 項目 | 内容 |
| --- | --- |
| GUI 設定 | 「Macbook Environment」で指定している UI 操作（アクセシビリティ表示、トラックパッド速度など）を手動で実施する |
| GitHub ブラウザ認証 | `gh auth login` はブラウザ操作が必要。未ログインだと `github` ロールが停止するので先に完了する |

## 補足

- Brewfile は dotfiles リポジトリで管理し、`link-symbolic-dotfiles.sh` が `~/brewfile.me` へリンクします。
- プレイブック内のシェルは必要最小限の PATH で実行する設計です。
