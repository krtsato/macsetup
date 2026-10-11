#!/bin/bash
# 秘密と処理済みの記録を、暗号化ディスクイメージで運ぶ（段 2）。
# 使い方: secrets.sh <list|export|import|restore> [イメージの絶対パス]
#   list    運ぶ物と実行役・起動役の停止状態を表示するだけ（何も作らない）
#   export  旧端末。許可一覧の物だけをイメージにまとめる
#   import  新端末。衝突があれば何も変えずに止まり、無ければ全部置く（途中で失敗したら配置前へ戻す）
#   restore 旧端末へ戻す。今ある物を退避してから、イメージの中身で置き換える
#   recover 強制終了などで途中に残った配置を、記録（journal）と実際の状態から配置前へ戻す（冪等）
# 入力は環境変数: SECRETS_HOME / SECRETS_INPUT_FILE（JSON のファイルのパス。なければ SECRETS_INPUT に JSON そのもの。
# 許可一覧は doctor と同じ正本）/ SECRETS_REPO_ROOT。使うのは `make secrets-*`（端末に繋いだまま直接実行する）。
# 合言葉は引数にも環境変数にも渡さない。hdiutil が端末で直接尋ねる。
#   テスト専用: SECRETS_TEST_STDINPASS=1 のときだけ、標準入力の全文を合言葉として hdiutil -stdinpass へ渡す。
#   同じくテスト専用: SECRETS_TEST_FAIL_AFTER=N（N 件を置いた後で失敗させる）・SECRETS_TEST_SKIP_DOCTOR=1・
#   SECRETS_TEST_KILL_AFTER_MOVE=N（N 回目の mv の直後、記録の後始末より前に自分へ SIGKILL を送る）。
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
kill_after_move="${SECRETS_TEST_KILL_AFTER_MOVE:-0}"

log() { echo "==> $*"; }
err() { echo "==> 失敗: $*" >&2; }
die() { err "$*"; exit 1; }
jin() { printf '%s' "${input}" | jq "$@"; }

case "${action}" in
  list | export | import | restore | recover) ;;
  *) die "使い方: secrets.sh <list|export|import|restore|recover> [イメージの絶対パス]" ;;
esac

tmp="$(mktemp -d)" || die "作業用ディレクトリを作れない"

# --- 後始末（成功でも失敗でも必ず通る）---------------------------------------------
mnt=""             # 取り付け先。空でなければ取り外す
stage=""           # 一時の置き場（export は tmp 内、import・restore はホーム直下）
journal=""         # 配置の記録
place_state=""     # running の間に中断されたら、記録をたどって戻す
keep_stage=0       # 戻せなかったときだけ 1（手で直すための材料を残す）
keep_tmp=0         # 取り外せなかったときだけ 1（取り付け先を消さない）
out_created=0      # export で OUT を作り始めたら 1。成功したら 0 に戻す
backup_dir=""

# detach_image: 取り外す。既に外れていても成功。通常・強制の両方が失敗したら 1 を返し、
# 取り付け先を残して表示する（手で取り外せるように。取り付けたまま先へ進まない）
detach_image() {
  [ -n "${mnt}" ] || return 0
  if ! hdiutil detach "${mnt}" >/dev/null 2>&1; then
    if ! hdiutil detach -force "${mnt}" >/dev/null 2>&1; then
      keep_tmp=1
      err "イメージを取り外せない。取り付け先 ${mnt} を残す。手で hdiutil detach -force '${mnt}' してから、作業用ディレクトリを消してください"
      return 1
    fi
  fi
  mnt=""
  return 0
}

# --- 書き込み先行の記録（write-ahead journal）と、実際の状態に基づく冪等な復旧 ---------
# 変更の前に意図を 1 行（操作・元・先。タブ区切り）書く。途中で SIGKILL されても、記録は変更より先にある。
#   mkdir <dir>            : 親ディレクトリを作る
#   mkbackup <dir>         : restore の退避先を作る
#   backup <dest> <bk>     : 既存の dest を bk へ退避する
#   place <src> <dest>     : 一時の置き場 src から dest へ置く
# 復旧は新しい順にたどり、各行を「実際に在る物」で判断する。やり直しても結果は同じ（冪等）。
jlog() { printf '%s\t%s\t%s\n' "$1" "${2:-}" "${3:-}" >>"${journal}"; }

# recover_journal <journal>: 配置前へ戻す。戻せない行があれば 1（残りは手で。件数だけ表示する）
recover_journal() {
  local jf="$1" op a b bad=0
  [ -f "${jf}" ] || return 0
  while IFS=$'\t' read -r op a b; do
    case "${op}" in
      place)
        # 元（一時の置き場）が無く、先に在る → 置いた後なので消す。元が残っていれば mv は起きていない
        if [ -n "${b}" ] && [ ! -e "${a}" ] && { [ -e "${b}" ] || [ -L "${b}" ]; }; then
          rm -rf "${b}" || bad=$((bad + 1))
        fi
        ;;
      backup)
        # 退避先に在り、元の場所が空 → 戻す。両方に在るときは判断できないので手で
        if [ -e "${b}" ] || [ -L "${b}" ]; then
          if [ -e "${a}" ] || [ -L "${a}" ]; then
            bad=$((bad + 1))
          else
            mv "${b}" "${a}" || bad=$((bad + 1))
          fi
        fi
        ;;
      mkdir) [ -d "${a}" ] && { rmdir "${a}" 2>/dev/null || true; } ;;
      mkbackup)
        # 戻した後に空になった退避先だけを消す。中身が残っていれば消さない
        [ -d "${a}" ] && { find "${a}" -depth -type d -empty -delete 2>/dev/null || true; }
        ;;
      *) ;;
    esac
  done < <(tail -r "${jf}")
  if [ "${bad}" -gt 0 ]; then
    err "配置前へ戻せない行が ${bad} 件ある。記録 ${jf} を見て手で戻してください"
    return 1
  fi
  return 0
}

rollback() {
  [ -n "${journal}" ] && [ -f "${journal}" ] || return 0
  if ! recover_journal "${journal}"; then keep_stage=1; return 1; fi
  return 0
}

# --- 出力から本物のプロファイル名を消す -------------------------------------------------
# 標準出力・標準エラーの全体を、名前を別名へ置き換えるフィルタ経由にする。cp・mv・find・hdiutil など
# どの道具のエラーにパスが出ても、本物の名前は出ない。プロファイル名を読んだ後に開始する。
scrub_started=0
scrub_pids=()
start_scrub() {
  [ "${scrub_started}" = 0 ] || return 0
  scrub_started=1
  mkfifo "${tmp}/o.fifo" "${tmp}/e.fifo"
  exec 8>&1 9>&2
  render <"${tmp}/o.fifo" >&8 &
  scrub_pids=("$!")
  render <"${tmp}/e.fifo" >&9 &
  scrub_pids+=("$!")
  exec 1>"${tmp}/o.fifo" 2>"${tmp}/e.fifo"
}
stop_scrub() {
  [ "${scrub_started}" = 1 ] || return 0
  scrub_started=0
  exec 1>&8 2>&9
  # フィルタが終わるのを待つ（出力の取りこぼし防止）。固まったときのために 5 秒で切る
  ( sleep 5; kill "${scrub_pids[@]}" 2>/dev/null ) >/dev/null 2>&1 &
  local wd=$! p
  for p in "${scrub_pids[@]}"; do wait "${p}" 2>/dev/null || true; done
  kill "${wd}" 2>/dev/null || true
}

cleanup() {
  local rc=$?
  trap - EXIT
  if [ "${place_state}" = running ]; then
    err "配置の途中で中断された。配置前へ戻す"
    rollback || true
    place_state=""
  fi
  detach_image || true
  # export が途中で失敗したら、書きかけのイメージを残さない
  if [ "${out_created}" = 1 ] && [ -n "${image}" ]; then rm -f "${image}"; fi
  # 注意: APFS には信頼できる shred が無い。rm -rf で消すだけで、物理的な消去は保証しない
  if [ -n "${stage}" ] && [ "${keep_stage}" = 0 ]; then rm -rf "${stage}"; fi
  # 取り外せなかったときは、取り付け先を含む作業用ディレクトリを消さない
  if [ "${keep_tmp}" = 0 ]; then rm -rf "${tmp}"; fi
  stop_scrub
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# --- 合言葉 ------------------------------------------------------------------------
test_pass=""
if [ "${test_stdinpass}" = 1 ]; then test_pass="$(cat)"; fi

# hdi <hdiutil の引数...>: 通常は端末で合言葉を尋ねさせる。テスト専用のときだけ標準入力から渡す
# hdiutil の出力は捕まえ、失敗したときだけ（別名へ置き換えて）エラーを見せる。合言葉の尋ね方は端末（/dev/tty）で変わらない
hdi() {
  local rc=0
  if [ "${test_stdinpass}" = 1 ]; then
    printf '%s' "${test_pass}" | hdiutil "$@" -stdinpass >"${tmp}/hdi.out" 2>"${tmp}/hdi.err" || rc=$?
  else
    hdiutil "$@" >"${tmp}/hdi.out" 2>"${tmp}/hdi.err" || rc=$?
  fi
  if [ "${rc}" -ne 0 ]; then render <"${tmp}/hdi.err" >&2; fi
  return "${rc}"
}

# --- NotebookLM のプロファイル名（GitHub の変数から読む。doctor と同じ規則）-----------
PROFILES=()
RN=()
RI=()
profiles_soft=0
profiles_unknown=0
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
  if [ "${bad}" != 0 ]; then
    # 復旧（recover）は通信に頼らない。読めなければ名前の置き換えができないので、出力の根拠を消す
    if [ "${profiles_soft}" = 1 ]; then profiles_unknown=1; PROFILES=(); echo '[]' >"${tmp}/profiles.json"; return 0; fi
    exit 1
  fi
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
  # 置き換えは長い名前から（foo と foobar が両方あっても、foobar を先に別名にする）
  RN=()
  RI=()
  local idx i=0
  if [ "${#PROFILES[@]}" -gt 0 ]; then
    while read -r _ idx; do
      RI+=("${idx}")
      RN+=("${PROFILES[$((idx - 1))]}")
    done < <(while [ "${i}" -lt "${#PROFILES[@]}" ]; do printf '%s %s\n' "${#PROFILES[$i]}" "$((i + 1))"; i=$((i + 1)); done | sort -rn)
  fi
  start_scrub
}

# render: 標準入力の各行から、既知のプロファイル名を <プロファイルN> に置き換える（長い名前から）
render() {
  local line k
  while IFS= read -r line || [ -n "${line}" ]; do
    k=0
    if [ "${#RN[@]}" -gt 0 ]; then
      while [ "${k}" -lt "${#RN[@]}" ]; do
        line="${line//"${RN[$k]}"/<プロファイル${RI[$k]}>}"
        k=$((k + 1))
      done
    fi
    printf '%s\n' "${line}"
  done
}

# rd <文字列>: 1 つの文字列を別名へ置き換えて出す
rd() { printf '%s\n' "$1" | render; }

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
# 止まっていると確かめられなければ「止まっている」とは扱わない（fail-closed）:
#   - 実行役: .runner が有るのに .service が無い・読めない／ bin*/Runner.Listener の process が動いている
#   - 読み込み済みの label（launchctl print が成功）
LOADED=()
STOP_REASONS=()
check_stopped() {
  local label svc dir repo name rdir pat rc
  LOADED=()
  STOP_REASONS=()
  local -a labels=()
  while IFS=$'\t' read -r repo name dir; do
    rdir="${home}/${dir}"
    svc="${rdir}/.service"
    if [ -f "${svc}" ] && [ -r "${svc}" ] && [ -n "$(cat "${svc}" 2>/dev/null)" ]; then
      label="$(basename "$(cat "${svc}")" .plist)"
      labels+=("${label}")
    elif [ -e "${rdir}/.runner" ]; then
      STOP_REASONS+=("実行役 ${repo}/${name}: .runner が有るのに .service が無い・読めない（停止を確かめられない）")
    fi
    if [ -d "${rdir}" ]; then
      if ! command -v pgrep >/dev/null 2>&1; then
        STOP_REASONS+=("実行役 ${repo}/${name}: pgrep が無く、Runner.Listener の有無を確かめられない")
      else
        pat="${rdir}/bin[^/]*/Runner\\.Listener"
        rc=0
        pgrep -f "${pat}" >/dev/null 2>&1 || rc=$?
        case "${rc}" in
          0) STOP_REASONS+=("実行役 ${repo}/${name}: Runner.Listener の process が動いている") ;;
          1) ;;
          *) STOP_REASONS+=("実行役 ${repo}/${name}: process の有無を確かめられない（pgrep が終了コード ${rc}）") ;;
        esac
      fi
    fi
  done < <(jin -r '.runners[] | [.repo, .label, .dir] | @tsv')
  for label in $(jin -r '.launcher_labels[]'); do labels+=("${label}"); done
  if [ "${#labels[@]}" -gt 0 ]; then
    for label in "${labels[@]}"; do
      if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then LOADED+=("${label}"); fi
    done
  fi
  return 0
}

require_stopped() {
  check_stopped
  if [ "${#LOADED[@]}" -gt 0 ] || [ "${#STOP_REASONS[@]}" -gt 0 ]; then
    err "実行役・起動役が止まっていると確かめられない。夜の処理が動いている間は運ばない（先に止めて、動いている枠の完了を待つ）:"
    if [ "${#LOADED[@]}" -gt 0 ]; then printf '    読み込み済み: %s\n' "${LOADED[@]}" >&2; fi
    if [ "${#STOP_REASONS[@]}" -gt 0 ]; then printf '    %s\n' "${STOP_REASONS[@]}" >&2; fi
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
  if [ "${#LOADED[@]}" -gt 0 ] || [ "${#STOP_REASONS[@]}" -gt 0 ]; then
    log "実行役・起動役: 読み込み済み ${#LOADED[@]} 件・確かめられない ${#STOP_REASONS[@]} 件 → いまの状態では export・restore は拒否される"
    if [ "${#LOADED[@]}" -gt 0 ]; then printf '  %s\n' "${LOADED[@]}"; fi
    if [ "${#STOP_REASONS[@]}" -gt 0 ]; then printf '  %s\n' "${STOP_REASONS[@]}"; fi
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
        cp "${home}/${f}" "${stage}/${f}" || die "コピーできない: $(rd "${f}")"
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
  # 1b. このマシンで展開した「必須」の項目（必須の子ファイルを含む）が、目録に全部あるか。任意の物は無くてよい
  jq -r --slurpfile R "${tmp}/resolved.json" '
    . as $M | $R[0][] | select(.required) | . as $r
    | ($M.entries | map(select(.path == $r.rel)) | first) as $m
    | if $m == null then "必須の項目が無い: " + $r.rel
      elif ($r.kind == "dir" and ($r.recursive | not)) then
        ($r.children // [])[] as $c | select((($m.files | index($r.rel + "/" + $c)) == null))
        | "必須のファイルが無い: " + $r.rel + "/" + $c
      else empty end' "${m}" >>"${bad}"
  if [ -s "${bad}" ]; then
    err "許可一覧の外の物・必須の欠けが目録にある（何も変更しない）:"
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

# ensure_parents <rel>: 無い祖先を 0700 で作り、作った物を記録する
ensure_parents() {
  local rel="$1" cur="${home}" c
  local -a parts=()
  IFS=/ read -r -a parts <<<"$(dirname "${rel}")"
  for c in "${parts[@]}"; do
    [ "${c}" != . ] || continue
    cur="${cur}/${c}"
    if [ ! -d "${cur}" ]; then
      jlog mkdir "${cur}"
      mkdir "${cur}" || return 1
      chmod 700 "${cur}"
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
  echo "$$" >"${stage}/pid"
  mkdir "${stage}/tree"
  while IFS= read -r p; do mkdir -p "${stage}/tree/${p}"; done < <(jq -r '.entries[] | select(.kind == "dir") | .path' "${m}")
  while IFS= read -r f; do
    mkdir -p "${stage}/tree/$(dirname "${f}")"
    cp "${mnt}/${f}" "${stage}/tree/${f}" || { err "イメージから写せない: $(rd "${f}")"; return 1; }
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

# step_mv <元> <先>: 変更する mv。テスト専用: N 回目の直後（後始末より前）に SIGKILL で落ちる
mv_count=0
step_mv() {
  mv "$1" "$2" || return 1
  mv_count=$((mv_count + 1))
  if [ "${kill_after_move}" -gt 0 ] && [ "${mv_count}" -ge "${kill_after_move}" ]; then
    kill -KILL "$$"
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
          jlog mkbackup "${backup_dir}"
          mkdir "${backup_dir}" || { err "退避先を作れない"; return 1; }
          chmod 700 "${backup_dir}"
        fi
        bk="${backup_dir}/${rel}"
        mkdir -p "$(dirname "${bk}")"
        # 書き込み先行: 意図を記録してから動かす
        jlog backup "${dest}" "${bk}"
        step_mv "${dest}" "${bk}" || { err "既存の物を退避できない"; return 1; }
      else
        err "配置の直前に目的地が現れた（衝突）"
        return 1
      fi
    fi
    jlog place "${stage}/tree/${rel}" "${dest}"
    step_mv "${stage}/tree/${rel}" "${dest}" || { err "配置できない: $(rd "${rel}")"; return 1; }
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

# check_no_leftover: 前回の途中で止まった跡（一時の置き場・記録）があれば、先へ進まず復旧を求める
check_no_leftover() {
  local s
  for s in "${home}"/.macsetup-import.*; do
    [ -d "${s}" ] || continue
    die "前回の途中で止まった跡がある（$(basename "${s}")）。先に make secrets-recover を実行してください（何も変更していない）"
  done
}

# do_recover: 途中で残った配置を記録と実際の状態から配置前へ戻す。やり直しても同じ結果（冪等）
do_recover() {
  local s found=0 failed=0 pid
  profiles_soft=1
  load_profiles
  if [ "${profiles_unknown}" = 1 ]; then
    log "プロファイル名を読めないため、道具のエラー出力は表示しない（結果は件数だけ）"
    exec 2>/dev/null
  fi
  for s in "${home}"/.macsetup-import.*; do
    [ -d "${s}" ] || continue
    found=$((found + 1))
    if [ -f "${s}/pid" ]; then
      pid="$(cat "${s}/pid" 2>/dev/null || true)"
      if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
        err "$(basename "${s}") は実行中の process が使っている（pid ${pid}）。終わるのを待つ"
        failed=$((failed + 1))
        continue
      fi
    fi
    if [ -s "${s}/journal" ]; then
      if ! recover_journal "${s}/journal"; then failed=$((failed + 1)); continue; fi
    fi
    rm -rf "${s}"
    log "戻した: $(basename "${s}")"
  done
  if [ "${found}" = 0 ]; then log "戻す跡は無い"; fi
  [ "${failed}" = 0 ] || exit 1
}

# do_place <import|restore>: 目録の読み取りから配置までを all-or-nothing で行う
do_place() {
  local mode="$1" c=0 rel
  resolve_entries
  check_no_leftover
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
  # 取り外せないまま先へ進まない（イメージが付いたままの配置はしない）
  detach_image || exit 1
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
  recover) do_recover ;;
  export) do_export ;;
  import) do_import ;;
  restore) do_restore ;;
  *) die "使い方: secrets.sh <list|export|import|restore> [イメージの絶対パス]" ;;
esac
