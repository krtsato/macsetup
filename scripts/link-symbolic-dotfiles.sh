#!/opt/homebrew/bin/zsh

log() { printf "==> %s\n" "$*"; }

main() {
  confirm_prerequisites || exit 0

  local brewfile_path=~/dev/me/dotfiles/brewfile.me
  local dotfiles_root=~/dev/me/dotfiles

  link_dotfiles "$dotfiles_root" "$brewfile_path" || exit 1
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
    [.gitconfig]=~/.gitconfig
    [.gitconfig.awa]=~/.gitconfig.awa
    [.gitignore.global]=~/.gitignore.global
    [.npmrc]=~/.npmrc
    [.textlintrc.json]=~/.textlintrc.json
    [.vscode_extensions_list]=~/.vscode/.vscode_extensions_list
    [.vscode_extensions_list_insiders]=~/.vscode-insiders/.vscode_extensions_list_insiders
    [.zcompdump]=~/.zcompdump
    [.zprofile]=~/.zprofile
    [.zshrc]=~/.zshrc
    [herdr-app/]=~/.config/
    [karabiner/]=~/.config/
    [mise/]=~/.config/
    [settings.json]=~/Library/Application\ Support/Code/User/settings.json
    [keybindings.json]=~/Library/Application\ Support/Code/User/keybindings.json
  )

  local failed=0 link_path aside
  for name origin_dir in ${(kv)dot_files_dirs}; do
    # Skip if source and destination are identical (avoids self-symlink loops)
    if [[ "$dotfiles_root/$name" == "$origin_dir" ]]; then
      log "skip (source == destination): $dotfiles_root/$name"
      continue
    fi

    mkdir -p "$(dirname "$origin_dir")"
    # A destination ending in "/" means "put the link inside this directory".
    link_path="$origin_dir"
    [[ "$origin_dir" == */ ]] && link_path="${origin_dir%/}/${name%/}"
    # An app started before this script (Claude Code, Codex, Herdr, ...) may
    # have created a real directory where the link goes; ln cannot replace a
    # directory and the app would keep its defaults. Move it aside instead of
    # deleting it, so its contents can still be checked.
    if [[ -d "$link_path" && ! -L "$link_path" ]]; then
      aside="${link_path}.bak-$(date +%Y%m%d-%H%M%S)"
      log "move aside existing directory: $link_path -> $aside"
      if ! mv "$link_path" "$aside"; then
        # Linking now would put the link inside the directory and look like success.
        log "FAILED to move aside, not linked: $link_path"
        failed=1
        continue
      fi
    fi
    log "link: $dotfiles_root/$name -> $origin_dir"
    if ! ln -fnsv "$dotfiles_root/$name" "$origin_dir"; then
      log "FAILED to link: $dotfiles_root/$name -> $origin_dir"
      failed=1
    fi
    printf "\n"
  done
  return $failed
}

main "$@"
