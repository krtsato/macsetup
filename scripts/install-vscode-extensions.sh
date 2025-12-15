#!/opt/homebrew/bin/zsh

log() { printf "==> %s\n" "$*"; }

main() {
  local vscode_extensions_list=~/.vscode/.vscode_extensions_list
  local vscode_extensions_list_insiders=~/.vscode-insiders/.vscode_extensions_list_insiders

  if command -v code &> /dev/null; then
    log "VSCode extensions をインストールします..."
    install_extensions "code" "$vscode_extensions_list"
    dump_extensions "code" "$vscode_extensions_list"
    log "✓ VSCode extensions のインストールが完了しました"
  else
    log "⚠ VSCode (code コマンド) が見つかりません。スキップします..."
  fi

  if command -v code-insiders &> /dev/null; then
    log "VSCode Insiders extensions をインストールします..."
    install_extensions "code-insiders" "$vscode_extensions_list_insiders"
    dump_extensions "code-insiders" "$vscode_extensions_list_insiders"
    log "✓ VSCode Insiders extensions のインストールが完了しました"
  else
    log "⚠ VSCode Insiders (code-insiders コマンド) が見つかりません。スキップします..."
  fi
}

install_extensions() {
  local code_command=$1
  local extensions_list=$2

  if [ -f "$extensions_list" ]; then
    log "リストから拡張機能をインストール中: $extensions_list"
    while IFS= read -r extension; do
      [ -z "$extension" ] && continue
      log "  Installing: $extension"
      $code_command --install-extension "$extension" --force
    done < "$extensions_list"
  else
    log "⚠ リストファイルが見つかりません: $extensions_list"
    log "  スキップします..."
  fi
}

dump_extensions() {
  local code_command=$1
  local output_path=$2

  mkdir -p "$(dirname "$output_path")"

  log "インストール済み拡張機能をダンプ中: $output_path"
  $code_command --list-extensions > "$output_path"
  log "✓ ダンプ完了 ($(wc -l < "$output_path" | tr -d ' ') 個の拡張機能)"
}

main "$@"
