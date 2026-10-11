#!/bin/bash
# 秘密と処理済みの記録を、暗号化ディスクイメージで運ぶ（段 2）。
# 使い方: secrets.sh <list|export|import|restore> [イメージの絶対パス]
#   list    運ぶ物と実行役・起動役の停止状態を表示するだけ（何も作らない）
#   export  旧端末。許可一覧の物だけをイメージにまとめる
#   import  新端末。衝突があれば何も変えずに止まり、無ければ全部置く（途中で失敗したら配置前へ戻す）
#   restore 旧端末へ戻す。今ある物を退避してから、イメージの中身で置き換える
# 入力は環境変数: SECRETS_HOME / SECRETS_INPUT_FILE（JSON のファイルのパス。なければ SECRETS_INPUT に JSON そのもの。
# 許可一覧は doctor と同じ正本）/ SECRETS_REPO_ROOT。使うのは `make secrets-*`（端末に繋いだまま直接実行する）。
# 合言葉は引数にも環境変数にも渡さない。hdiutil が端末で直接尋ねる。
#   テスト専用: SECRETS_TEST_STDINPASS=1 のときだけ、標準入力の全文を合言葉として hdiutil -stdinpass へ渡す。
#   同じくテスト専用: SECRETS_TEST_FAIL_AFTER=N（N 件を置いた後で失敗させる）・SECRETS_TEST_SKIP_DOCTOR=1。
# 公開リポジトリなので、秘密の値・ハッシュ・NotebookLM のプロファイル名を出力しない。
# 名前はこのスクリプトの shell 変数の中だけで持ち、表示は「<プロファイル1>」などの別名にする（doctor と同じ別名）。
# macOS 標準の bash 3.2 で動くこと。全角文字に変数を密着させず、必ず ${var} と書く。

# jq のプログラムは単引用符で渡すので、$ は展開しなくてよい
# shellcheck disable=SC2016
set -euo pipefail
umask 077

action="${1:-}"
image="${2:-}"
home="${SECRETS_HOME:?SECRETS_HOME is required}"
if [ -n "${SECRETS_INPUT_FILE:-}" ]; then
  [ -f "${SECRETS_INPUT_FILE}" ] || { echo "==> 失敗: SECRETS_INPUT_FILE が無い" >&2; exit 1; }
  input="$(cat "${SECRETS_INPUT_FILE}")"
else
  input="${SECRETS_INPUT:?SECRETS_INPUT_FILE or SECRETS_INPUT is required}"
fi
repo_root="${SECRETS_REPO_ROOT:-}"
test_stdinpass="${SECRETS_TEST_STDINPASS:-0}"
fail_after="${SECRETS_TEST_FAIL_AFTER:-0}"
skip_doctor="${SECRETS_TEST_SKIP_DOCTOR:-0}"

log() { echo "==> $*"; }
err() { echo "==> 失敗: $*" >&2; }
die() { err "$*"; exit 1; }
jin() { printf '%s' "${input}" | jq "$@"; }

case "${action}" in
  list | export | import | restore) ;;
  *) die "使い方: secrets.sh <list|export|import|restore> [イメージの絶対パス]" ;;
esac

tmp="$(mktemp -d)" || die "作業用ディレクトリを作れない"

# --- 後始末（成功でも失敗でも必ず通る）---------------------------------------------
mnt=""             # 取り付け先。空でなければ取り外す
stage=""           # 一時の置き場（export は tmp 内、import・restore はホーム直下）
journal=""         # 配置の記録
place_state=""     # running の間に中断されたら、記録をたどって戻す
keep_stage=0       # 戻せなかったときだけ 1（手で直すための材料を残す）
out_created=0      # export で OUT を作り始めたら 1。成功したら 0 に戻す
backup_dir=""

# detach_image: 取り外す。既に外れていても成功とする
detach_image() {
  [ -n "${mnt}" ] || return 0
  if ! hdiutil detach "${mnt}" >/dev/null 2>&1; then
    hdiutil detach -force "${mnt}" >/dev/null 2>&1 || err "イメージを取り外せない（手で hdiutil detach してください）"
  fi
  mnt=""
}

# rollback: 記録を新しい順にたどり、置いた物を消し、退避した物を戻す
rollback() {
  [ -n "${journal}" ] && [ -f "${journal}" ] || return 0
  local op a b ok=0
  while IFS=$'\t' read -r op a b; do
    case "${op}" in
      placed) [ -n "${a}" ] && { rm -rf "${a}" || ok=1; } ;;
      backed) mv "${a}" "${b}" || ok=1 ;;
      mkdir) rmdir "${a}" 2>/dev/null || true ;;
      *) ;;
    esac
  done < <(tail -r "${journal}")
  if [ -n "${backup_dir}" ] && [ -d "${backup_dir}" ]; then
    # 戻した後に空になった退避先だけを消す。中身が残っていれば消さない
    find "${backup_dir}" -depth -type d -empty -delete 2>/dev/null || true
  fi
  if [ "${ok}" -ne 0 ]; then
    keep_stage=1
    err "配置前へ戻す途中で失敗した。記録 ${journal} を見て手で戻してください"
    return 1
  fi
  return 0
}

cleanup() {
  local rc=$?
  trap - EXIT
  if [ "${place_state}" = running ]; then
    err "配置の途中で中断された。配置前へ戻す"
    rollback || true
    place_state=""
  fi
  detach_image
  # export が途中で失敗したら、書きかけのイメージを残さない
  if [ "${out_created}" = 1 ] && [ -n "${image}" ]; then rm -f "${image}"; fi
  # 注意: APFS には信頼できる shred が無い。rm -rf で消すだけで、物理的な消去は保証しない
  if [ -n "${stage}" ] && [ "${keep_stage}" = 0 ]; then rm -rf "${stage}"; fi
  rm -rf "${tmp}"
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# --- 合言葉 ------------------------------------------------------------------------
test_pass=""
if [ "${test_stdinpass}" = 1 ]; then test_pass="$(cat)"; fi

# hdi <hdiutil の引数...>: 通常は端末で合言葉を尋ねさせる。テスト専用のときだけ標準入力から渡す
hdi() {
  if [ "${test_stdinpass}" = 1 ]; then
    printf '%s' "${test_pass}" | hdiutil "$@" -stdinpass
  else
    hdiutil "$@"
  fi
}

# --- NotebookLM のプロファイル名（GitHub の変数から読む。doctor と同じ規則）-----------
PROFILES=()
load_profiles() {
  local repo value override bad=0
  local -a names=()
  override="$(jin -r '(.profiles_override // [])[]')"
  if [ -n "${override}" ]; then
    while IFS= read -r value; do names+=("${value}"); done <<<"${override}"
  else
    for repo in $(jin -r '.profile_repos[]'); do
      if value="$(gh variable get NOTEBOOKLM_PROFILE -R "krtsato/${repo}" 2>/dev/null)" \
        && [ -n "${value}" ] && ! [[ "${value}" =~ [[:space:]/] ]]; then
        names+=("${value}")
      else
        err "${repo}/NOTEBOOKLM_PROFILE: GitHub の変数を読めない・空・空白や / を含む"
        bad=1
      fi
    done
  fi
  [ "${bad}" = 0 ] || exit 1
  PROFILES=()
  if [ "${#names[@]}" -gt 0 ]; then
    while IFS= read -r value; do PROFILES+=("${value}"); done < <(printf '%s\n' "${names[@]}" | LC_ALL=C sort -u)
  fi
  # 別名つきの一覧（名前は tmp の 0700 の中のファイルだけに置く）
  if [ "${#PROFILES[@]}" -eq 0 ]; then
    echo '[]' >"${tmp}/profiles.json"
  else
    jq -nc '[$ARGS.positional | to_entries[] | {name: .value, alias: ("プロファイル" + ((.key + 1) | tostring))}]' \
      --args "${PROFILES[@]}" >"${tmp}/profiles.json"
  fi
}

# render: 標準入力の各行から、既知のプロファイル名を <プロファイルN> に置き換える
render() {
  local line n i
  while IFS= read -r line; do
    i=0
    if [ "${#PROFILES[@]}" -gt 0 ]; then
      for n in "${PROFILES[@]}"; do
        i=$((i + 1))
        line="${line//"${n}"/<プロファイル${i}>}"
      done
    fi
    printf '%s\n' "${line}"
  done
}

# short: 標準入力の各パスを先頭 3 要素までにする。許可外の物の名前（未知のプロファイル名）を出さないため
short() {
  local line
  while IFS= read -r line; do
    printf '%s\n' "$(printf '%s' "${line}" | cut -d/ -f1-3)"
  done
}

# resolve_entries: 許可一覧を {profile} 展開して resolved.json にする
resolve_entries() {
  load_profiles
  if jin -e '[.entries[] | select(.per_profile // false)] | length > 0' >/dev/null \
    && [ "${#PROFILES[@]}" -eq 0 ]; then
    die "NotebookLM のプロファイル名を 1 つも読めない（{profile} の項目を展開できない）"
  fi
  jin -c --slurpfile profs "${tmp}/profiles.json" '
    [ .entries[] as $e
      | (if ($e.per_profile // false)
         then ($profs[0][] as $p | {rel: ($e.path | split("{profile}") | join($p.name)),
                                    disp: ($e.path | split("{profile}") | join("<" + $p.alias + ">"))})
         else {rel: $e.path, disp: $e.path} end)
        + {class: $e.class, kind: $e.kind, required: ($e.required // false),
           recursive: ($e.recursive // false), children: ($e.children // null)} ]' >"${tmp}/resolved.json"
}

# --- 実行役と起動役が止まっているか --------------------------------------------------
LOADED=()
check_stopped() {
  local label svc dir
  LOADED=()
  local -a labels=()
  for dir in $(jin -r '.runners[].dir'); do
    svc="${home}/${dir}/.service"
    [ -f "${svc}" ] || continue
    label="$(basename "$(cat "${svc}")" .plist)"
    labels+=("${label}")
  done
  for label in $(jin -r '.launcher_labels[]'); do labels+=("${label}"); done
  [ "${#labels[@]}" -gt 0 ] || return 0
  for label in "${labels[@]}"; do
    if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then LOADED+=("${label}"); fi
  done
}

require_stopped() {
  check_stopped
  if [ "${#LOADED[@]}" -gt 0 ]; then
    err "実行役・起動役が読み込まれている。夜の処理が動いている間は運ばない（先に止めて、動いている枠の完了を待つ）:"
    printf '    %s\n' "${LOADED[@]}" >&2
    exit 1
  fi
}

# --- 計画（運ぶ物の実在を調べる）-----------------------------------------------------
# build_plan: plan.json（各項目に present と files）を作る。問題は PROBLEMS に溜める
PROBLEMS=()
is_excluded_name() { case "$1" in .DS_Store | .lock | *.lock) return 0 ;; *) return 1 ;; esac; }

build_plan() {
  local n i rel disp kind required recursive present fl c f
  PROBLEMS=()
  : >"${tmp}/plan.ndjson"
  n="$(jq 'length' "${tmp}/resolved.json")"
  i=0
  while [ "${i}" -lt "${n}" ]; do
    rel="$(jq -r ".[${i}].rel" "${tmp}/resolved.json")"
    disp="$(jq -r ".[${i}].disp" "${tmp}/resolved.json")"
    kind="$(jq -r ".[${i}].kind" "${tmp}/resolved.json")"
    required="$(jq -r ".[${i}].required" "${tmp}/resolved.json")"
    recursive="$(jq -r ".[${i}].recursive" "${tmp}/resolved.json")"
    fl="${tmp}/files.${i}"
    : >"${fl}"
    present=false
    if [ -L "${home}/${rel}" ]; then
      PROBLEMS+=("${disp}: シンボリックリンクは運ばない")
    elif [ "${kind}" = file ]; then
      if [ -f "${home}/${rel}" ]; then
        present=true
        printf '%s\n' "${rel}" >"${fl}"
      elif [ -e "${home}/${rel}" ]; then
        PROBLEMS+=("${disp}: 通常のファイルでない")
      elif [ "${required}" = true ]; then
        PROBLEMS+=("${disp}: 必須だが無い")
      fi
    else
      if [ -d "${home}/${rel}" ]; then
        present=true
        if [ "${recursive}" = true ]; then
          # 通常のファイルとディレクトリだけを運ぶ。.DS_Store と .lock は除外
          if [ -n "$(cd "${home}" && find "${rel}" \! -type f \! -type d 2>/dev/null | head -1)" ]; then
            PROBLEMS+=("${disp}: 配下に通常のファイルでない物（シンボリックリンクなど）がある")
          fi
          (cd "${home}" && find "${rel}" -type f \! -name .DS_Store \! -name .lock \! -name '*.lock' \
            | LC_ALL=C sort) >"${fl}"
        else
          for c in $(jq -r ".[${i}].children[]" "${tmp}/resolved.json"); do
            f="${rel}/${c}"
            if [ -f "${home}/${f}" ] && [ ! -L "${home}/${f}" ]; then
              printf '%s\n' "${f}" >>"${fl}"
            elif [ "${required}" = true ]; then
              PROBLEMS+=("${disp}/${c}: 必須だが無い")
            fi
          done
        fi
      elif [ -e "${home}/${rel}" ]; then
        PROBLEMS+=("${disp}: ディレクトリでない")
      elif [ "${required}" = true ]; then
        PROBLEMS+=("${disp}: 必須だが無い")
      fi
    fi
    jq -nc --argjson i "${i}" --slurpfile r "${tmp}/resolved.json" --argjson present "${present}" --rawfile files "${fl}" \
      '$r[0][$i] + {present: $present, files: ($files | split("\n") | map(select(length > 0)))}' >>"${tmp}/plan.ndjson"
    i=$((i + 1))
  done
  jq -s '.' "${tmp}/plan.ndjson" >"${tmp}/plan.json"
}

# print_plan: 別名で表した一覧と、分類ごとの件数
print_plan() {
  jq -r '.[] | "  " + .class + "\t" + .disp + "\t"
         + (if .present then ((.files | length | tostring) + " ファイル")
            elif .required then "欠落（必須）" else "なし（任意）" end)' "${tmp}/plan.json"
  jq -r 'group_by(.class)[] | "  分類 " + .[0].class + ": " + (map(select(.present)) | length | tostring)
         + " 項目 / " + (map(.files | length) | add | tostring) + " ファイル"' "${tmp}/plan.json"
}

# --- list --------------------------------------------------------------------------
do_list() {
  resolve_entries
  build_plan
  log "運ぶ物（許可一覧。中身は読まない・出さない）"
  print_plan
  if [ "${#PROBLEMS[@]}" -gt 0 ]; then
    log "export が止まる問題 ${#PROBLEMS[@]} 件:"
    printf '  %s\n' "${PROBLEMS[@]}"
  fi
  check_stopped
  if [ "${#LOADED[@]}" -gt 0 ]; then
    log "実行役・起動役: 読み込み済み ${#LOADED[@]} 件 → いまの状態では export・restore は拒否される"
    printf '  %s\n' "${LOADED[@]}"
  else
    log "実行役・起動役: 読み込まれていない（export・restore できる）"
  fi
}

# --- export ------------------------------------------------------------------------
do_export() {
  local dir dirp root f
  case "${image}" in
    /*.dmg) ;;
    *) die "出力先は絶対パスで、.dmg で終わる必要がある（hdiutil が拡張子を足すため）" ;;
  esac
  [ ! -e "${image}" ] && [ ! -L "${image}" ] || die "出力先が既に存在する（上書きしない）"
  dir="$(dirname "${image}")"
  [ -d "${dir}" ] || die "出力先のディレクトリが無い"
  dirp="$(cd "${dir}" && pwd -P)"
  if [ -n "${repo_root}" ] && [ -d "${repo_root}" ]; then
    root="$(cd "${repo_root}" && pwd -P)"
    case "${dirp}/" in
      "${root}/"*) die "出力先がリポジトリの中。公開リポジトリへ秘密を置かないため、外を指定する" ;;
      *) ;;
    esac
  fi
  require_stopped
  resolve_entries
  build_plan
  if [ "${#PROBLEMS[@]}" -gt 0 ]; then
    err "運べない問題が ${#PROBLEMS[@]} 件ある（何も作らない）:"
    printf '  %s\n' "${PROBLEMS[@]}" >&2
    exit 1
  fi

  stage="$(mktemp -d "${tmp}/stage.XXXXXX")"
  local n i rel kind
  n="$(jq 'length' "${tmp}/plan.json")"
  i=0
  while [ "${i}" -lt "${n}" ]; do
    if [ "$(jq -r ".[${i}].present" "${tmp}/plan.json")" = true ]; then
      rel="$(jq -r ".[${i}].rel" "${tmp}/plan.json")"
      kind="$(jq -r ".[${i}].kind" "${tmp}/plan.json")"
      [ "${kind}" = dir ] && mkdir -p "${stage}/${rel}"
      while IFS= read -r f; do
        [ -n "${f}" ] || continue
        mkdir -p "${stage}/$(dirname "${f}")"
        cp "${home}/${f}" "${stage}/${f}"
      done <"${tmp}/files.${i}"
    fi
    i=$((i + 1))
  done
  # 分類ごとに決めた権限へそろえる（ファイル 0600・ディレクトリ 0700）
  find "${stage}" -type d -exec chmod 700 {} +
  find "${stage}" -type f -exec chmod 600 {} +
  local expect got
  expect="$(jq '[.[].files | length] | add // 0' "${tmp}/plan.json")"
  got="$(find "${stage}" -type f | wc -l | tr -d ' ')"
  [ "${expect}" = "${got}" ] || die "一時の置き場のファイル数が計画と違う（計画 ${expect}・実際 ${got}）"
  # 持ち込み側が照合する目録。中身のハッシュは持たない
  jq '{version: 1, created: (now | todate),
       entries: [.[] | select(.present) | {path: .rel, class: .class, kind: .kind, files: .files}]}' \
    "${tmp}/plan.json" >"${stage}/MANIFEST.json"
  chmod 600 "${stage}/MANIFEST.json"

  log "暗号化イメージを作る（合言葉を 2 回入力）"
  out_created=1
  hdi create -encryption AES-256 -fs APFS -volname macsetup-secrets -srcfolder "${stage}" "${image}" >/dev/null \
    || die "イメージを作れなかった"
  chmod 600 "${image}"
  out_created=0
  rm -rf "${stage}"
  stage=""
  log "作成した: ${image}（権限 600）"
  print_plan
  log "段階 6 まで安全に保管し、新端末で make secrets-import IMAGE=... を流す"
}

# --- import / restore の共通部分 -----------------------------------------------------
# open_image: 読み取り専用で private な場所へ取り付ける。取り外しは cleanup が必ず行う
open_image() {
  [ -f "${image}" ] || die "イメージが無い"
  mnt="$(mktemp -d "${tmp}/mnt.XXXXXX")"
  if ! hdi attach -readonly -nobrowse -noautoopen -mountpoint "${mnt}" "${image}" >/dev/null; then
    rmdir "${mnt}" 2>/dev/null || true
    mnt=""
    die "イメージを開けない（合言葉が違う・壊れている）"
  fi
}

# verify_image: 目録と中身が一致し、許可一覧の外が何も無いことを確かめる。何も変更しない
verify_image() {
  local m="${tmp}/manifest.json" bad
  # 取り外した後でも読めるよう、検査の前に写しを持つ（以降の処理はこの写しだけを読む）
  if [ -f "${mnt}/MANIFEST.json" ]; then cp "${mnt}/MANIFEST.json" "${m}"; fi
  if ! { [ -f "${m}" ] && jq -e '.version == 1 and (.entries | type == "array")' "${m}" >/dev/null 2>&1; }; then
    die "MANIFEST.json が無い・読めない（このイメージは export の物でない）"
  fi
  # 1. 目録の各項目が、許可一覧（このマシンで展開したもの）に沿っているか
  bad="${tmp}/violations.txt"
  jq -r --slurpfile R "${tmp}/resolved.json" '
    .entries[] as $m
    | ($R[0] | map(select(.rel == $m.path)) | first) as $r
    | if $r == null then "許可一覧に無い項目: " + $m.path
      elif ($r.kind != $m.kind or $r.class != $m.class) then "種別か分類が違う項目: " + $m.path
      else $m.files[] as $f
        | (if $r.kind == "file" then ($f != $r.rel)
           elif $r.recursive then
             (($f | startswith($r.rel + "/") | not)
              or ($f | split("/") | last | (. == ".DS_Store" or . == ".lock" or endswith(".lock"))))
           else ((($r.children // []) | map($r.rel + "/" + .) | index($f)) == null) end)
        | select(.) | "許可外のファイル: " + $f
      end' "${m}" >"${bad}"
  if [ -s "${bad}" ]; then
    err "許可一覧の外の物が目録にある（何も変更しない）:"
    render <"${bad}" | short | sort -u | head -20 | sed 's/^/    /' >&2
    exit 1
  fi
  # 2. 中身（ファイルとディレクトリ）が目録と完全に一致するか。余分も不足も拒否
  local sysname='^(\.fseventsd|\.Spotlight-V100|\.Trashes|\.DS_Store|\.TemporaryItems|\.VolumeIcon\.icns)(/|$)'
  if [ -n "$(cd "${mnt}" && find . -mindepth 1 \! -type d \! -type f | head -1)" ]; then
    err "通常のファイルでない物（シンボリックリンクなど）がイメージにある（何も変更しない）"
    exit 1
  fi
  (cd "${mnt}" && find . -mindepth 1 -type f | sed 's|^\./||') | grep -Ev "${sysname}" | grep -vx 'MANIFEST.json' \
    | LC_ALL=C sort >"${tmp}/actual.files" || true
  jq -r '.entries[].files[]' "${m}" | LC_ALL=C sort >"${tmp}/expect.files"
  (cd "${mnt}" && find . -mindepth 1 -type d | sed 's|^\./||') | grep -Ev "${sysname}" \
    | LC_ALL=C sort >"${tmp}/actual.dirs" || true
  jq -r '[.entries[] | .files[], (select(.kind == "dir") | .path + "/.")] | .[]
         | split("/")[:-1] as $p | range(1; ($p | length) + 1) | $p[:.] | join("/")' "${m}" \
    | LC_ALL=C sort -u >"${tmp}/expect.dirs"
  local extra missing
  extra="$({ LC_ALL=C comm -13 "${tmp}/expect.files" "${tmp}/actual.files"; LC_ALL=C comm -13 "${tmp}/expect.dirs" "${tmp}/actual.dirs"; } | wc -l | tr -d ' ')"
  missing="$({ LC_ALL=C comm -23 "${tmp}/expect.files" "${tmp}/actual.files"; LC_ALL=C comm -23 "${tmp}/expect.dirs" "${tmp}/actual.dirs"; } | wc -l | tr -d ' ')"
  if [ "${extra}" != 0 ] || [ "${missing}" != 0 ]; then
    err "イメージの中身が目録と一致しない（余分 ${extra} 件・不足 ${missing} 件。何も変更しない）"
    { LC_ALL=C comm -13 "${tmp}/expect.files" "${tmp}/actual.files"; LC_ALL=C comm -13 "${tmp}/expect.dirs" "${tmp}/actual.dirs"; } \
      | render | short | sort -u | head -20 | sed 's/^/    余分: /' >&2
    exit 1
  fi
  # 3. 種別（項目がファイルかディレクトリか）
  local p k
  while IFS=$'\t' read -r p k; do
    if [ "${k}" = file ] && [ ! -f "${mnt}/${p}" ]; then err "種別が目録と違う（ファイルのはず）: $(printf '%s\n' "${p}" | render | short)"; exit 1; fi
    if [ "${k}" = dir ] && [ ! -d "${mnt}/${p}" ]; then err "種別が目録と違う（ディレクトリのはず）: $(printf '%s\n' "${p}" | render | short)"; exit 1; fi
  done < <(jq -r '.entries[] | [.path, .kind] | @tsv' "${m}")
}

# ancestors_conflict <rel>: 祖先に「ディレクトリでない物」があれば真。置けないので衝突として扱う
ancestors_conflict() {
  local rel="$1" cur="${home}" c
  local -a parts=()
  IFS=/ read -r -a parts <<<"$(dirname "${rel}")"
  for c in "${parts[@]}"; do
    [ "${c}" != . ] || continue
    cur="${cur}/${c}"
    if [ -e "${cur}" ] || [ -L "${cur}" ]; then
      [ -d "${cur}" ] && [ ! -L "${cur}" ] || return 0
    else
      return 1
    fi
  done
  return 1
}

jlog() { printf '%s\t%s\t%s\n' "$1" "${2:-}" "${3:-}" >>"${journal}"; }

# ensure_parents <rel>: 無い祖先を 0700 で作り、作った物を記録する
ensure_parents() {
  local rel="$1" cur="${home}" c
  local -a parts=()
  IFS=/ read -r -a parts <<<"$(dirname "${rel}")"
  for c in "${parts[@]}"; do
    [ "${c}" != . ] || continue
    cur="${cur}/${c}"
    if [ ! -d "${cur}" ]; then
      mkdir "${cur}" || return 1
      chmod 700 "${cur}"
      jlog mkdir "${cur}"
    fi
  done
  return 0
}

# stage_tree: イメージの中身を、ホームと同じファイルシステムの一時の置き場へ写し、権限と件数を検査する
stage_tree() {
  local m="${tmp}/manifest.json" f p expect got
  stage="$(mktemp -d "${home}/.macsetup-import.XXXXXX")"
  journal="${stage}/journal"
  : >"${journal}"
  mkdir "${stage}/tree"
  while IFS= read -r p; do mkdir -p "${stage}/tree/${p}"; done < <(jq -r '.entries[] | select(.kind == "dir") | .path' "${m}")
  while IFS= read -r f; do
    mkdir -p "${stage}/tree/$(dirname "${f}")"
    cp "${mnt}/${f}" "${stage}/tree/${f}"
  done < <(jq -r '.entries[].files[]' "${m}")
  find "${stage}/tree" -type d -exec chmod 700 {} +
  find "${stage}/tree" -type f -exec chmod 600 {} +
  # 検査: 全体と項目ごとの件数、権限
  expect="$(jq '[.entries[].files | length] | add // 0' "${m}")"
  got="$(find "${stage}/tree" -type f | wc -l | tr -d ' ')"
  [ "${expect}" = "${got}" ] || { err "展開したファイル数が目録と違う（目録 ${expect}・実際 ${got}）"; return 1; }
  while IFS=$'\t' read -r p expect; do
    if [ "${expect}" = 0 ]; then
      [ -e "${stage}/tree/${p}" ] || { err "目録の項目が展開されていない"; return 1; }
      continue
    fi
    got="$(find "${stage}/tree/${p}" -type f | wc -l | tr -d ' ')"
    [ "${expect}" = "${got}" ] || { err "項目のファイル数が目録と違う: $(printf '%s\n' "${p}" | render | short)"; return 1; }
  done < <(jq -r '.entries[] | [.path, (.files | length)] | @tsv' "${m}")
  if [ -n "$(find "${stage}/tree" \( -type f \! -perm 600 \) -o \( -type d \! -perm 700 \) | head -1)" ]; then
    err "展開した物の権限が 0600/0700 でない"
    return 1
  fi
  return 0
}

# place_all <import|restore>: 項目ごとに tree からホームへ移し、1 件ごとに記録する
place_all() {
  local mode="$1" rel dest placed=0 bk expect
  while IFS= read -r rel; do
    dest="${home}/${rel}"
    ensure_parents "${rel}" || { err "親のディレクトリを作れない"; return 1; }
    if [ -e "${dest}" ] || [ -L "${dest}" ]; then
      if [ "${mode}" = restore ]; then
        if [ -z "${backup_dir}" ]; then
          backup_dir="${home}/.macsetup-restore-backup-$(date +%Y%m%d-%H%M%S)"
          mkdir "${backup_dir}" || { err "退避先を作れない"; backup_dir=""; return 1; }
          chmod 700 "${backup_dir}"
        fi
        bk="${backup_dir}/${rel}"
        mkdir -p "$(dirname "${bk}")"
        mv "${dest}" "${bk}" || { err "既存の物を退避できない"; return 1; }
        jlog backed "${bk}" "${dest}"
      else
        err "配置の直前に目的地が現れた（衝突）"
        return 1
      fi
    fi
    mv "${stage}/tree/${rel}" "${dest}" || { err "配置できない"; return 1; }
    jlog placed "${dest}"
    placed=$((placed + 1))
    if [ "${fail_after}" -gt 0 ] && [ "${placed}" -ge "${fail_after}" ]; then
      err "テスト用の失敗を入れた（${placed} 件を置いた後）"
      return 1
    fi
  done < <(jq -r '.entries[].path' "${tmp}/manifest.json")
  # 読み取りに失敗して 1 件も置かないまま「成功」に見えるのを防ぐ
  expect="$(jq '.entries | length' "${tmp}/manifest.json")"
  if [ "${placed}" != "${expect}" ]; then err "配置した項目数が目録と違う（目録 ${expect}・実際 ${placed}）"; return 1; fi
  return 0
}

# do_place <import|restore>: 目録の読み取りから配置までを all-or-nothing で行う
do_place() {
  local mode="$1" c=0 rel
  resolve_entries
  open_image
  verify_image
  log "イメージの検査に合格（目録と一致・許可一覧の外は無し）。運ぶ物:"
  summarize_manifest

  if [ "${mode}" = import ]; then
    local conflicts="${tmp}/conflicts.txt"
    : >"${conflicts}"
    while IFS= read -r rel; do
      if [ -e "${home}/${rel}" ] || [ -L "${home}/${rel}" ] || ancestors_conflict "${rel}"; then
        printf '%s\n' "${rel}" >>"${conflicts}"
      fi
    done < <(jq -r '.entries[].path' "${tmp}/manifest.json")
    if [ -s "${conflicts}" ]; then
      c="$(wc -l <"${conflicts}" | tr -d ' ')"
      err "衝突 ${c} 件（既に在る物）。何も変更していない。退かすか、戻す目的なら secrets-restore を使う:"
      render <"${conflicts}" | sed 's/^/    /' >&2
      exit 1
    fi
  else
    while IFS= read -r rel; do
      if ancestors_conflict "${rel}"; then err "祖先がディレクトリでない物があり置けない: $(printf '%s\n' "${rel}" | render)"; exit 1; fi
    done < <(jq -r '.entries[].path' "${tmp}/manifest.json")
  fi

  stage_tree || exit 1
  detach_image
  place_state=running
  if ! place_all "${mode}"; then
    err "配置に失敗した。配置前へ戻す"
    place_state=""
    if rollback; then log "配置前の状態へ戻した（何も残していない）"; fi
    exit 1
  fi
  place_state=""
  # 成功: 記録と一時の置き場は exit の cleanup が消す
  log "配置した（${mode}）"
}

# summarize_manifest: 目録から別名で一覧を出す。取り付け中に呼ぶ
summarize_manifest() {
  jq -r '.entries[] | "  " + .class + "\t" + .path + "\t" + (.files | length | tostring) + " ファイル"' "${tmp}/manifest.json" | render
  jq -r '.entries | group_by(.class)[] | "  分類 " + .[0].class + ": " + (length | tostring) + " 項目 / "
         + (map(.files | length) | add | tostring) + " ファイル"' "${tmp}/manifest.json"
}

run_doctor() {
  local rc=0
  log "段 1 の点検を流す（make doctor PHASE=cutover）。切り替え前なので実行役・起動役は「停止」が正しい状態"
  if [ "${skip_doctor}" = 1 ]; then
    log "（テスト専用: 点検を省いた）"
    return 0
  fi
  make -C "${repo_root}" doctor PHASE=cutover || rc=$?
  return "${rc}"
}

do_import() {
  local rc=0
  do_place import
  run_doctor || rc=$?
  exit "${rc}"
}

do_restore() {
  require_stopped
  do_place restore
  if [ -n "${backup_dir}" ] && [ -d "${backup_dir}" ]; then
    log "元の物は退避した: ${backup_dir}（権限 700。不要になったら手で消す）"
  else
    log "退避する物は無かった（置き換えた物なし）"
  fi
}

case "${action}" in
  list) do_list ;;
  export) do_export ;;
  import) do_import ;;
  restore) do_restore ;;
  *) die "使い方: secrets.sh <list|export|import|restore> [イメージの絶対パス]" ;;
esac
