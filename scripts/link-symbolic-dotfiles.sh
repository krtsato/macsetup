#!/opt/homebrew/bin/zsh

log() { printf "==> %s\n" "$*"; }

main() {
  confirm_prerequisites || exit 0

  local brewfile_path=~/dev/me/dotfiles/brewfile.me
  local dotfiles_root=~/dev/me/dotfiles

  link_dotfiles "$dotfiles_root" "$brewfile_path"
}

confirm_prerequisites() {
  # Skip prompt when running non-interactively (e.g., Ansible) or when explicitly set.
  if [[ -n "${SKIP_CONFIRM:-}" || ! -t 0 ]]; then
    return 0
  fi

  cat <<'EOF_MSG'
Have you done these tasks?
- setup zsh, VSCode
- add new dotfiles' name to the array of this script
- set new 'settings.json' and 'keybindings.json' of VSCode
- start this script from terminal.app
(y/n)
EOF_MSG

  if ! read -q; then
    log "abort process"
    exit 0
  fi
}

link_dotfiles() {
  local dotfiles_root=$1
  local brewfile_path=$2

  typeset -A dot_files_dirs=(
    [brewfile.me]="$brewfile_path"
    [.claude/]=~/
    [.codex/]=~/
    [.kiro/]=~/
    [.claude.json]=~/.claude.json
    [.gitconfig]=~/.gitconfig
    [.gitconfig.awa]=~/.gitconfig.awa
    [.gitignore.global]=~/.gitignore.global
    [.mcp.json]=~/.mcp.json
    [.npmrc]=~/.npmrc
    [.vscode_extensions_list]=~/.vscode/.vscode_extensions_list
    [.vscode_extensions_list_insiders]=~/.vscode-insiders/.vscode_extensions_list_insiders
    [.zcompdump]=~/.zcompdump
    [.zprofile]=~/.zprofile
    [.zshrc]=~/.zshrc
    [karabiner/]=~/.config/
    [mise/]=~/.config/
    [settings.json]=~/Library/Application\ Support/Code/User/settings.json
    [keybindings.json]=~/Library/Application\ Support/Code/User/keybindings.json
  )

  for name origin_dir in ${(kv)dot_files_dirs}; do
    # Skip if source and destination are identical (avoids self-symlink loops)
    if [[ "$dotfiles_root/$name" == "$origin_dir" ]]; then
      log "skip (source == destination): $dotfiles_root/$name"
      continue
    fi

    mkdir -p "$(dirname "$origin_dir")"
    log "link: $dotfiles_root/$name -> $origin_dir"
    ln -fnsv "$dotfiles_root/$name" "$origin_dir"
    printf "\n"
  done
}

main "$@"
