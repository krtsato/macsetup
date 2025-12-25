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
   make setup EXTRA_VARS="homebrew_sudo_password=YOUR_PASSWORD"
   # もしくは対話で入力する場合:
   # make setup ANSIBLE_FLAGS='--ask-become-pass'
   ```

### Ansible / Homebrew 非対話オプションについて

- Homebrew の cask インストールは sudo を要求するため、非対話で動かすには askpass を使う。  
  - `homebrew_sudo_password`（EXTRA_VARS）または `--ask-become-pass` からパスワードを取得し、ロール側で `SUDO_ASKPASS` と `HOMEBREW_SUDO_ASKPASS=1` をセットしている。  
  - どちらか一方を欠くと sudo プロンプトで停止するので、両方必要。

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

gh でログインする。ブラウザ認証する。

```sh
cd ~/dev/me/macsetup
gh auth login
gh auth status
```

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

### Accessibility Display

アクセシビリティ表示を調整。

```sh
defaults write com.apple.universalaccess reduceMotion -int 1
defaults write com.apple.universalaccess reduceTransparency -int 1
defaults write com.apple.universalaccess mouseDriverCursorSize -float 2.0
```

### Keyboard

キーボードの自動補助を無効化。

```sh
defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
```

### Trackpad

トラックパッドの速度を調整。

```sh
defaults write NSGlobalDomain com.apple.trackpad.scaling -int 3
```

### Dock

Dock の位置・サイズ・動作を設定。

```sh
defaults write com.apple.dock tilesize -int 41
defaults write com.apple.dock orientation -string left
defaults write com.apple.dock mineffect -string scale
defaults write com.apple.dock minimize-to-application -bool true
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock show-recents -bool false
killall Dock
```

### Finder

Finder の表示設定を変更。

```sh
defaults write com.apple.finder AppleShowAllFiles -bool true
defaults write NSGlobalDomain AppleShowAllExtensions -bool true
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
killall Finder
```

### Menu Bar

メニューバーの表示項目を設定。

```sh
defaults write com.apple.menuextra.battery ShowPercent -string "YES"
defaults write com.apple.controlcenter "NSStatusItem Visible Bluetooth" -bool true
defaults write com.apple.controlcenter "NSStatusItem Visible Sound" -bool true
killall ControlCenter
killall SystemUIServer
```

## Manual Setup

CLI では変更できない、または sudo 権限が必要な項目は GUI で設定する。

| 項目                   | 設定内容                     |
| ---------------------- | ---------------------------- |
| コンピュータ名         | krtsato-macbook{model}-yyyy  |
| ディスプレイ           | 外付けディスプレイ解像度     |
| ディスプレイ           | Night Shift スケジュール設定 |
| 日付と時計             | 日付を表示                   |
| 通知                   | 編集                         |
| Finder                 | サイドバー表示項目           |
| iCloud                 | サインイン・各項目の同期設定 |
| Raycast                | 設定のインポート             |
| Microsoft Office       | インストール                 |
| 旧 PC からのデータ移行 | 経理書類など                 |

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
