# Automatic Setup for Macbook

## Install Homebrew and Ansible

1. Xcode Command Line Tools をインストールする。

   ```sh
   xcode-select --install
   ```

2. リポジトリをクローンする。

   ```sh
   git clone https://github.com/krtsato/macsetup.git ~/dev/me/macsetup
   ```

3. Homebrew と Ansible をインストールする。

   ```sh
   cd ~/dev/me/macsetup
   ./scripts/install-clt-brew-ansible.sh
   ```

4. プレイブックを実行する（非対話でパスワード供給）。

   ```sh
   make setup EXTRA_VARS="sudo_pass=YOUR_PASSWORD"
   # もしくは対話で入力する場合:
   # make setup ANSIBLE_FLAGS='--ask-become-pass'
   ```

### Ansible / Homebrew 非対話オプションについて

- Homebrew / macOS のタスクで sudo が必要になるため、非対話で動かすには askpass を使う。  
  - `sudo_pass`（EXTRA_VARS）または `--ask-become-pass` からパスワードを取得し、`SUDO_ASKPASS` と `HOMEBREW_SUDO_ASKPASS=1` をセットしている。  
  - GitHub ロールで未ログインの場合は `gh auth login -h github.com -s admin:public_key` のプロンプトが出るので、指示に従ってブラウザ認証する。

## Install by Homebrew

Homebrew でインストールするパッケージ一覧。

### Formulae

- actionlint
- argocd
- aws-sam-cli
- awscli
- azure-cli
- buf
- coreutils
- codex
- ffmpeg
- gemini-cli
- gh
- git
- helm
- jq
- k9s
- kubectl
- kustomize
- minikube
- mise
- mysql
- packer
- postgresql
- redis
- starship
- sqlite
- watch
- yamlfmt
- yamllint
- zsh
- zsh-completions

### Casks

- 1password
- appcleaner
- aws-vpn-client
- claude-code
- deepl
- discord
- displaylink
- docker-desktop
- elgato-game-capture-hd
- firefox
- font-fira-code-nerd-font
- font-hack-nerd-font
- font-ricty-diminished
- gcloud-cli
- google-japanese-ime
- imageoptim
- karabiner-elements
- kiro-cli
- loopback
- mongosh
- ngrok
- notion
- notion-calendar
- postman
- raycast
- slack
- tradingview
- tunnelbear
- tunnelblick
- visual-studio-code
- visual-studio-code@insiders
- zoom

## Development Environment

### Put Credential Files

秘匿情報や Git の事前設定に必要なファイルを下記のディレクトリに配置する。

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

### Setup Git

gh は Homebrew で導入される。プレイブック実行時、未ログインなら `gh auth login -h github.com -s admin:public_key` を求めるプロンプトが出るので、その指示に従ってブラウザ認証する（事前に同コマンドでログインしておいてもよい）。

SSH Key を生成して GitHub へ自動登録する。
macsetup リポジトリはクローン済みである前提でスクリプトを実行する。

```sh
# ヘルプを表示
./scripts/setup-github-ssh.sh --help

# デフォルト（Ed25519）で作成
./scripts/setup-github-ssh.sh

# ECDSA-521 にしたい場合のみオプション指定
./scripts/setup-github-ssh.sh -t ecdsa
```

### Setup dotfiles

各種設定ファイルのシンボリックリンクを作成。

```sh
cd ~/dev/me/macsetup
./scripts/link-symbolic-dotfiles.sh
```

（プレイブックでは `SKIP_CONFIRM=1` で非対話実行しているため、手動実行時はプロンプトに従ってください）

### Global Install

mise tools をインストール。

```sh
./scripts/install-mise-tools.sh
```

Go Binaries をインストール。

```sh
go install github.com/air-verse/air@latest
go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
go install go.uber.org/mock/mockgen@latest
go install golang.org/x/tools/gopls@latest
go install github.com/deepmap/oapi-codegen/v2/cmd/oapi-codegen@latest
```

VSCode Extensions をインストール。

```sh
./scripts/install-vscode-extensions.sh
```

## Macbook Environment

### Dock

Dock の位置・サイズ・動作・表示項目を設定。

```sh
defaults write com.apple.dock tilesize -int 40
defaults write com.apple.dock orientation -string left
defaults write com.apple.dock mineffect -string scale
defaults write com.apple.dock minimize-to-application -bool true
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock show-recents -bool false
defaults write com.apple.dock persistent-apps -array
killall Dock
```

### Keyboard / Trackpad

キーリピートを高速化し、トラックパッド速度を最速にする。

```sh
defaults write NSGlobalDomain InitialKeyRepeat -int 13
defaults write NSGlobalDomain KeyRepeat -int 1
defaults write NSGlobalDomain com.apple.trackpad.scaling -float 3.0
```

### Finder

Finder の表示設定を変更。

```sh
defaults write com.apple.finder AppleShowAllFiles -bool true
defaults write NSGlobalDomain AppleShowAllExtensions -bool true
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
defaults write com.apple.finder ShowStatusBar -bool true
killall Finder
```

### Appearance

ダークモードに固定する。

```sh
defaults write NSGlobalDomain AppleInterfaceStyle -string "Dark"
defaults write NSGlobalDomain AppleInterfaceStyleSwitchesAutomatically -bool false
```

### Menu Bar

メニューバーの表示項目を設定。

```sh
defaults write com.apple.controlcenter BatteryShowPercentage -bool true
defaults write com.apple.controlcenter "NSStatusItem Visible Bluetooth" -bool true
defaults write com.apple.controlcenter "NSStatusItem Visible Sound" -bool true
killall ControlCenter
killall SystemUIServer
```

## Manual Setup

CLI では変更できない、または sudo 権限が必要な項目は GUI で設定する。

| 項目                     | 設定内容                                                                                                                   |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| アクセシビリティ表示     | 視差効果を減らす、透明度を下げる、ポインタサイズを拡大、ポインタスクロール各種最速                                         |
| コンピュータ名           | krtsato-macbook{model}-yyyy                                                                                                |
| ディスプレイ             | 外付けディスプレイ解像度                                                                                                   |
| ディスプレイ             | Night Shift スケジュール設定                                                                                               |
| 日付と時計               | 日付を表示                                                                                                                 |
| 通知                     | 編集                                                                                                                       |
| Finder                   | サイドバー表示項目                                                                                                         |
| iCloud                   | サインイン・各項目の同期設定                                                                                               |
| Raycast                  | 設定のインポート                                                                                                           |
| Microsoft Office         | インストール                                                                                                               |
| 旧 PC からのデータ移行   | 経理書類など                                                                                                               |
| GitHub ブラウザ認証      | `gh auth login` はブラウザ操作が必要。未ログインだと `github` ロールが停止するので先に完了する                             |
| Touch ID                 | 指紋を追加（System Settings > Touch ID & Password）                                                                        |
| 入力ソース               | Google 日本語入力を有効化し、英字/かな切替を設定（System Settings > Keyboard > Input Sources）                             |
| Terminal フォント        | Terminal.app のプロファイルで VSCode の settings.json と同等の Nerd Font（例: FiraCodeNerdFontCompleteM-Retina）を手動設定 |
| デフォルトシェル         | Homebrew の zsh (`/opt/homebrew/bin/zsh`) があればそれを設定。無ければ `/bin/zsh`                                          |
| Spotlight ショートカット | [⌘Space を無効化](https://support.apple.com/ja-jp/guide/mac-help/mchlp2864/14.0/mac/14.0)                                  |

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
