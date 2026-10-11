#!/bin/bash
# 点検の本体。使い方: checks.sh <group>
# 何も変更しない（読むだけ）。結果は標準出力へ 1 行 1 件で出す。
#   FAIL|<名前>: <理由>   失敗（最後に点検全体を失敗にする）
#   WARN|<名前>: <理由>   警告
# NotebookLM のプロファイル名はアカウントの識別子に近いので、標準出力・Ansible の変数へ一切出さない。
# 名前はこのスクリプトの shell 変数の中だけで持ち、表示は「プロファイル1」「プロファイル2」の別名にする。
# 入力は環境変数: DOCTOR_PHASE / DOCTOR_HOME / DOCTOR_LAUNCHAGENTS / DOCTOR_INPUT（JSON）。
# 秘密の値は読まない・出さない。存在・種別・権限と、終了コードだけを見る。
# macOS 標準の bash 3.2 で動くこと。全角文字に変数を密着させず、必ず ${var} と書く。

# jq のプログラムは単引用符で渡すので、$ は展開しなくてよい
# shellcheck disable=SC2016
set -u

group="${1:?group is required}"
phase="${DOCTOR_PHASE:?}"
home="${DOCTOR_HOME:?}"
la_dir="${DOCTOR_LAUNCHAGENTS:?}"
input="${DOCTOR_INPUT:-}"
[ -n "${input}" ] || input='{}'

tmp="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "${tmp}"' EXIT

fail() { printf 'FAIL|%s\n' "$*"; }
warn() { printf 'WARN|%s\n' "$*"; }
jin() { printf '%s' "${input}" | jq "$@"; }

# check_mode <絶対パス> <表示名> <期待する権限 例 0600>
check_mode() {
  local got
  got="$(stat -f %Lp "$1" 2>/dev/null)" || { fail "$2: 権限を読めない"; return; }
  if [ "${got}" != "${3#0}" ]; then
    fail "$2: 権限が 0${got}（期待 $3）"
  fi
}

# ---------------------------------------------------------------------------------
# profiles: 各リポジトリの変数 NOTEBOOKLM_PROFILE を GitHub から読む。
# 読み出し: load_profiles が PROFILES（重複なし・整列）と、読めなかった repo の一覧
# PROFILE_ERRORS を作る。値は表示しない。空・空白・/ を含むものは不正として扱う。
# ---------------------------------------------------------------------------------
PROFILES=()
PROFILE_ERRORS=()
load_profiles() {
  local repo value
  local -a names=()
  PROFILES=()
  PROFILE_ERRORS=()
  for repo in $(jin -r '.profile_repos[]'); do
    if value="$(gh variable get NOTEBOOKLM_PROFILE -R "krtsato/${repo}" 2>/dev/null)" \
      && [ -n "${value}" ] && ! [[ "${value}" =~ [[:space:]/] ]]; then
      names+=("${value}")
    else
      PROFILE_ERRORS+=("${repo}")
    fi
  done
  if [ "${#names[@]}" -gt 0 ]; then
    while IFS= read -r value; do PROFILES+=("${value}"); done < <(printf '%s\n' "${names[@]}" | sort -u)
  fi
}

# profiles_json: [{name, alias}] を作る。alias は「プロファイル1」から始まる別名
profiles_json() {
  if [ "${#PROFILES[@]}" -eq 0 ]; then
    echo '[]'
    return
  fi
  jq -nc '[$ARGS.positional | to_entries[] | {name: .value, alias: ("プロファイル" + ((.key + 1) | tostring))}]' \
    --args "${PROFILES[@]}"
}

group_profiles() {
  local repo
  load_profiles
  # PROFILE_ERRORS が空のとき "${PROFILE_ERRORS[@]}" は bash 3.2 の set -u で落ちるので件数で守る
  if [ "${#PROFILE_ERRORS[@]}" -gt 0 ]; then
    for repo in "${PROFILE_ERRORS[@]}"; do
      fail "${repo}/NOTEBOOKLM_PROFILE: GitHub の変数を読めない・空・空白や / を含む"
    done
  fi
}

# ---------------------------------------------------------------------------------
# files: ホーム配下の秘密と記録。pre-import では「無いこと」を期待する
# ---------------------------------------------------------------------------------
check_present_entry() {
  local rel="$1" abs="$2" kind="$3" class="$4" mode="$5" children="$6" recursive="$7"
  local c p sub base
  # 持ち込む実体が一覧の場所にあることを保証するため、リンクは参照先に関係なく不合格
  if [ -L "${abs}" ]; then
    fail "${rel}: シンボリックリンクになっている（実体を置くこと）"
    return
  fi
  if [ "${kind}" = file ]; then
    [ -f "${abs}" ] || { fail "${rel}: 通常のファイルでない"; return; }
    check_mode "${abs}" "${rel}" "${mode}"
    return
  fi
  [ -d "${abs}" ] || { fail "${rel}: ディレクトリでない"; return; }
  check_mode "${abs}" "${rel}" "${mode}"
  if [ "${children}" != "-" ]; then
    for c in $(printf '%s' "${children}" | tr ',' ' '); do
      if [ -L "${abs}/${c}" ]; then
        fail "${rel}/${c}: シンボリックリンクになっている（実体を置くこと）"
      elif [ -f "${abs}/${c}" ]; then
        check_mode "${abs}/${c}" "${rel}/${c}" 0600
      else
        fail "${rel}/${c}: 必須の ${class} が無い"
      fi
    done
  fi
  if [ "${recursive}" = true ]; then
    local list errf="${tmp}/find.err"
    if ! list="$(find "${abs}" -mindepth 1 2>"${errf}")" || [ -s "${errf}" ]; then
      fail "${rel}: 配下を列挙できない"
      return
    fi
    while IFS= read -r p; do
      [ -n "${p}" ] || continue
      sub="${p#"${home}"/}"
      base="${p##*/}"
      if [ "${base}" = ".DS_Store" ]; then
        warn "${sub}: .DS_Store（除外対象）が混じっている"
      elif [ -L "${p}" ]; then
        fail "${sub}: シンボリックリンクになっている（実体を置くこと）"
      elif [ -d "${p}" ]; then
        check_mode "${p}" "${sub}" 0700
      else
        check_mode "${p}" "${sub}" 0600
      fi
    done <<<"${list}"
  fi
}

group_files() {
  local rel disp kind class mode required purpose children recursive abs ps
  load_profiles
  ps="$(profiles_json)"
  # profile が 1 つも読めないと {profile} の項目が黙って消えて偽の合格になる
  # （読めなかった repo は profiles グループが名指しで失敗にする）
  if [ "${#PROFILES[@]}" -eq 0 ]; then
    fail "NOTEBOOKLM_PROFILE: profile 名を 1 つも読めない（{profile} の項目を点検できない）"
  fi
  # rel は実際のパス、disp は別名に置き換えた表示用のパス
  while IFS=$'\t' read -r rel disp kind class mode required purpose children recursive; do
    abs="${home}/${rel}"
    if [ -e "${abs}" ] || [ -L "${abs}" ]; then
      if [ "${phase}" = pre-import ]; then
        warn "${disp}: 衝突（持ち込み前なのに既にある。${class}）"
      else
        check_present_entry "${disp}" "${abs}" "${kind}" "${class}" "${mode}" "${children}" "${recursive}"
      fi
    elif [ "${phase}" != pre-import ] && [ "${required}" = true ]; then
      fail "${disp}: 必須の ${class}（${purpose}）が無い"
    fi
  done < <(jin -r --argjson ps "${ps}" '
    .entries[]
    | (if (.per_profile // false)
        then . as $e | $ps[] | . as $p | $e
             | {p: (.path | gsub("\\{profile\\}"; $p.name)), d: (.path | gsub("\\{profile\\}"; "<" + $p.alias + ">"))} as $x
             | . + {path: $x.p, disp: $x.d}
        else . + {disp: .path} end)
    | [.path, .disp, .kind, .class, .mode, ((.required // false) | tostring), .purpose,
       ((.children // []) | join(",") | if . == "" then "-" else . end),
       ((.recursive // false) | tostring)]
    | @tsv')
}

# ---------------------------------------------------------------------------------
# clones: 手元の複製と、ワークフローが呼ぶ入口ファイル
# ---------------------------------------------------------------------------------
group_clones() {
  local repo name expect key dir url re kind path used
  while IFS=$'\t' read -r repo name expect; do
    key="${repo}/${name}"
    dir="$(jin -r --arg k "${key}" '.overrides[$k] // empty')"
    if [ -z "${dir}" ]; then
      dir="$(gh variable get "${name}" -R "krtsato/${repo}" 2>/dev/null)" || { fail "${key}: GitHub の変数を読めない"; continue; }
    fi
    [ -n "${dir}" ] || { fail "${key}: 変数が空"; continue; }
    [ -d "${dir}" ] || { fail "${key}: 複製のパス ${dir} が無い"; continue; }
    git -C "${dir}" rev-parse --git-dir >/dev/null 2>&1 || { fail "${key}: ${dir} は git の複製でない"; continue; }
    # 実行時の呼び出し側と同じく、url.insteadOf で書き換わる前の設定値を見る
    url="$(git -C "${dir}" config --get remote.origin.url 2>/dev/null)"
    re="^(https://github\\.com/|git@github\\.com:|ssh://git@github\\.com/)krtsato/${expect}(\\.git)?$"
    if ! [[ "${url}" =~ ${re} ]]; then
      # URL には認証情報が混じりうるので表示しない
      fail "${key}: origin が krtsato/${expect} でない（${url:+URL は表示しない}${url:-未設定}）"
      continue
    fi
    while IFS=$'\t' read -r kind path used; do
      [ -n "${kind}" ] || continue
      case "${kind}" in
        exec_file)
          if [ ! -f "${dir}/${path}" ] || [ ! -x "${dir}/${path}" ]; then
            fail "${key}: 入口 ${path} が無い・通常のファイルでない・実行できない（${used}）"
          fi ;;
        dir)
          [ -d "${dir}/${path}" ] || fail "${key}: 入口 ${path} が無い（${used}）" ;;
        git_path)
          git -C "${dir}" cat-file -e "origin/main:${path}" 2>/dev/null \
            || fail "${key}: 入口 origin/main:${path} が無い（${used}）" ;;
        *) fail "${key}: 一覧の種別 ${kind} が不明" ;;
      esac
    done < <(jin -r --arg r "${repo}" --arg n "${name}" \
      '.pairs[] | select(.repo == $r and .name == $n) | .entry_points[]? | [.kind, .path, .used_by] | @tsv')
  done < <(jin -r '.pairs[] | [.repo, .name, .expect] | @tsv')
}

# ---------------------------------------------------------------------------------
# tools: 道具
# ---------------------------------------------------------------------------------
group_tools() {
  local nlm ver cmd settings val
  nlm="${home}/$(jin -r '.nlm_path')"
  ver="$(jin -r '.nlm_version')"
  if [ -x "${nlm}" ]; then
    local got
    got="$("${nlm}" --version 2>/dev/null | sed -nE 's/^nlm version ([0-9][0-9A-Za-z.+-]*)$/\1/p' | head -1)"
    [ "${got}" = "${ver}" ] || fail "nlm: 版が ${ver} でない（${got:-読めない}）"
  else
    fail "nlm: ${nlm} が無い"
  fi
  for cmd in $(jin -r '.commands[]'); do
    command -v "${cmd}" >/dev/null 2>&1 || fail "${cmd}: コマンドが無い"
  done
  if command -v docker >/dev/null 2>&1; then
    docker info >/dev/null 2>&1 || fail "docker: docker info が通らない（Docker Desktop が止まっている？）"
  else
    fail "docker: コマンドが無い"
  fi
  settings="${home}/$(jin -r '.docker_settings')"
  if [ -f "${settings}" ]; then
    # 読むのはこの 1 つのキーだけ
    val="$(jq -r '.HostNetworkingEnabled' "${settings}" 2>/dev/null)"
    [ "${val}" = true ] || fail "Docker Desktop: host networking が有効でない（HostNetworkingEnabled=${val:-読めない}）"
  else
    fail "Docker Desktop: 設定ファイル ${settings} が無い"
  fi
}

# ---------------------------------------------------------------------------------
# opend: 証券口座への接続口（moomoo の API ゲートウェイ）。
# 火〜土の夜間（01:30）の前は必須: 逆日歩の取得 short-pressure-sync は当日しか取れず、
# 不通なら失敗する。土曜の証券口座への反映 watchlist-sync は失敗しても成功で終わるので、
# 成功を接続の証拠にしない。よって月〜金（日本時間）に閉じていれば失敗、土日は警告。
# ready 以外の PHASEでは警告のみ。
# ---------------------------------------------------------------------------------
group_opend() {
  local host port now dow hh mm minutes required=0 app login_item image cleanup items
  host="$(jin -r '.host')"
  port="$(jin -r '.port')"
  app="$(jin -r '.app')"
  login_item="$(jin -r '.login_item')"
  image="$(jin -r '.image')"
  cleanup="$(jin -r '.cleanup_label')"
  # 再起動後も夜間に間に合うかは、待受の今の状態ではなく「自動で起動するか」で決まる
  [ -d "${app}" ] || fail "OpenD: ${app} が無い（README の手動作業）"
  if items="$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null)"; then
    case ", ${items}, " in
      *", ${login_item}, "*) ;;
      *) fail "OpenD: ログイン項目に ${login_item} が無い（再起動後に起動せず、夜間の取得が失敗する）" ;;
    esac
  else
    warn "OpenD: ログイン項目を読めない（ターミナルへの自動化の許可が要る）"
  fi
  if docker info >/dev/null 2>&1; then
    docker image inspect "${image}" >/dev/null 2>&1 \
      || fail "moomoo: コンテナ image ${image} が無い（Docker Desktop を起動して make playbook）"
  fi
  launchctl print "gui/$(id -u)/${cleanup}" >/dev/null 2>&1 \
    || fail "OpenD: ログ掃除 ${cleanup} が読み込まれていない"
  if nc -z -w 3 "${host}" "${port}" >/dev/null 2>&1; then
    return
  fi
  # 日本時間の「いま」。テストでは DOCTOR_NOW（例 2026-10-17T00:30）で上書きする
  if [ -n "${DOCTOR_NOW:-}" ]; then
    now="$(date -j -f '%Y-%m-%dT%H:%M' "${DOCTOR_NOW}" '+%u %H %M' 2>/dev/null)" \
      || { fail "DOCTOR_NOW: 形式が不正（YYYY-MM-DDTHH:MM）"; return; }
  else
    now="$(TZ=Asia/Tokyo date '+%u %H %M')"
  fi
  read -r dow hh mm <<<"${now}"
  # 月曜 00:00 からの分。次に OpenD を要する夜間は火〜土 01:30。
  # 土曜 01:30 〜 月曜 01:30 だけは次の夜間まで間があるので必須にしない。
  minutes=$(((dow - 1) * 1440 + 10#${hh} * 60 + 10#${mm}))
  if [ "${minutes}" -lt 90 ] || [ "${minutes}" -ge $((5 * 1440 + 90)) ]; then required=0; else required=1; fi
  if [ "${phase}" = ready ] && [ "${required}" = 1 ]; then
    fail "OpenD ${host}:${port}: 閉じている（次の夜間 火〜土 01:30 の short-pressure-sync が失敗する）"
  else
    warn "OpenD ${host}:${port}: 閉じている（土 01:30〜月 01:30 以外の ready では失敗になる）"
  fi
}

# ---------------------------------------------------------------------------------
# logins: ログイン。gh・Claude は全 PHASEで必須。codex・NotebookLM は pre-import で
# 「無いこと」を期待し（有れば衝突の警告）、cutover/ready で必須。
# 結果は終了コードだけで見る（出力は捨てる）。claude auth status へは問い合わせを
# 送らない（claude -p は使わない）。
# ---------------------------------------------------------------------------------
group_logins() {
  local repo admin p nlm_dir nlm i rdir rpath uname
  gh auth status >/dev/null 2>&1 || fail "gh: ログインしていない（gh auth status）"
  for repo in $(jin -r '.admin_repos[]'); do
    admin="$(gh api "repos/krtsato/${repo}" --jq .permissions.admin 2>/dev/null)"
    [ "${admin}" = true ] || fail "${repo}: 管理者権限が無い・読めない（runner の登録に要る）"
  done
  if claude auth status 2>/dev/null | jq -e '.loggedIn == true' >/dev/null 2>&1; then :; else
    fail "claude: ログインしていない（claude auth status）"
  fi

  if codex login status >/dev/null 2>&1; then
    [ "${phase}" != pre-import ] || warn "codex: 衝突（持ち込み前なのにログイン済み）"
  else
    [ "${phase}" = pre-import ] || fail "codex: ログインしていない（codex login status）"
  fi

  load_profiles
  nlm="${home}/$(jin -r '.nlm_path')"
  nlm_dir="${home}/.config/mcp-notebooklm/nlm"
  i=0
  if [ "${#PROFILES[@]}" -gt 0 ]; then
    for p in "${PROFILES[@]}"; do
      i=$((i + 1))
      if [ -x "${nlm}" ] && NOTEBOOKLM_MCP_CLI_PATH="${nlm_dir}" "${nlm}" login --check --profile "${p}" >/dev/null 2>&1; then
        [ "${phase}" != pre-import ] || warn "NotebookLM(プロファイル${i}): 衝突（持ち込み前なのにログイン済み）"
      else
        [ "${phase}" = pre-import ] || fail "NotebookLM(プロファイル${i}): ログインしていない・確認できない（nlm login --check）"
      fi
    done
  fi

  # runner と同じ環境（env -i ＋ runner の .path）でも gh・claude・codex を確かめ、
  # PATH や環境変数の差による失敗を拾う。キーチェーンのセッションの差は plist の
  # SessionCreate=false の点検が受け持つ。launchd から起こした process での確認は
  # 切り替えの試し実行と夜間の本番でしか確かめられない（ここでは launchd の仕事を作らない）。
  rdir="${home}/$(jin -r '.runner_dir')"
  rpath="$(head -1 "${rdir}/.path" 2>/dev/null)"
  if [ -z "${rpath}" ]; then
    fail "runner と同じ環境で: ${rdir#"${home}"/}/.path を読めない"
    return
  fi
  uname="${USER:-$(id -un)}"
  runner_env() { env -i HOME="${HOME}" USER="${uname}" LOGNAME="${uname}" PATH="${rpath}" "$@"; }
  runner_env gh auth status >/dev/null 2>&1 || fail "runner と同じ環境で: gh auth status が通らない"
  if runner_env claude auth status 2>/dev/null | jq -e '.loggedIn == true' >/dev/null 2>&1; then :; else
    fail "runner と同じ環境で: claude auth status がログイン済みを返さない"
  fi
  if [ "${phase}" != pre-import ]; then
    runner_env codex login status >/dev/null 2>&1 || fail "runner と同じ環境で: codex login status が通らない"
  fi
}

# ---------------------------------------------------------------------------------
# github: 秘密と変数。名前の有無だけを見る（値は読まない）
# ---------------------------------------------------------------------------------
group_github() {
  local kind repo name f
  # kind=secret|variable。同じリポジトリは 1 回だけ一覧を取る
  while IFS=$'\t' read -r kind repo name; do
    f="${tmp}/${kind}-${repo}"
    if [ ! -e "${f}" ]; then
      if ! gh "${kind}" list -R "krtsato/${repo}" --json name --jq '.[].name' >"${f}" 2>/dev/null; then
        printf 'UNREADABLE\n' >"${f}"
      fi
    fi
    if grep -Fxq UNREADABLE "${f}"; then
      fail "${repo}/${name}: GitHub の ${kind} 一覧を読めない"
    elif ! grep -Fxq "${name}" "${f}"; then
      fail "${repo}/${name}: GitHub の ${kind} が未設定"
    fi
  done < <(jin -r '
    (.secrets[] | ["secret", .repo, .name]),
    (.clones[] | ["variable", .repo, .name]),
    (.variables[] | ["variable", .repo, .name]) | @tsv')
}

# ---------------------------------------------------------------------------------
# runners: self-hosted runner。全 PHASEで .path の先頭が mise の shims・plist が SessionCreate=false。
# pre-import/cutover は登録済み・停止中、ready は GitHub 上で online かつラベル一致。
# ---------------------------------------------------------------------------------
group_runners() {
  local repo label dir rdir name plist first sc plabel state svc_file shims agent
  shims="${home}/$(jin -r '.mise_shims')"
  while IFS=$'\t' read -r repo label dir; do
    name="${repo}/${label}"
    rdir="${home}/${dir}"
    if [ ! -d "${rdir}" ]; then
      fail "runner ${name}: 導入先 ${dir} が無い"
      continue
    fi
    if [ ! -f "${rdir}/.runner" ]; then
      fail "runner ${name}: 未登録（${dir}/.runner が無い）"
      continue
    fi
    # .runner から読むのは名前だけ（資格情報は .credentials にあり、読まない）
    agent="$(jq -r '.agentName // empty' "${rdir}/.runner" 2>/dev/null)"
    [ -n "${agent}" ] || fail "runner ${name}: .runner から名前を読めない"

    first="$(tr ':' '\n' <"${rdir}/.path" 2>/dev/null | head -1)"
    if [ "${first}" != "${shims}" ]; then
      fail "runner ${name}: .path の先頭が mise の shims でない（${first:-空}）"
    fi

    svc_file="${rdir}/.service"
    plist=""
    if [ -f "${svc_file}" ]; then
      plist="${la_dir}/$(basename "$(cat "${svc_file}")")"
    fi
    if [ -z "${plist}" ] || [ ! -f "${plist}" ]; then
      fail "runner ${name}: 常駐設定の plist が無い（${plist:-.service が無い}）"
      plabel=""
    else
      sc="$(plutil -extract SessionCreate raw "${plist}" 2>/dev/null)"
      [ "${sc}" = false ] || fail "runner ${name}: plist の SessionCreate が false でない（${sc:-未設定}）"
      plabel="$(basename "${plist}" .plist)"
    fi

    if [ "${phase}" = ready ]; then
      state="$(gh api "repos/krtsato/${repo}/actions/runners" --paginate \
        --jq ".runners[] | select(.name == \"${agent}\") | [.status, ([.labels[].name] | join(\",\"))] | @tsv" 2>/dev/null)"
      if [ -z "${state}" ]; then
        fail "runner ${name}: GitHub に ${agent} が見つからない・一覧を読めない"
      else
        case "${state%%$'\t'*}" in online) ;; *) fail "runner ${name}: GitHub 上で online でない（${state%%$'\t'*}）" ;; esac
        case ",${state#*$'\t'}," in *",${label},"*) ;; *) fail "runner ${name}: ラベル ${label} が一致しない" ;; esac
      fi
    elif [ -n "${plabel}" ]; then
      if launchctl print "gui/$(id -u)/${plabel}" 2>/dev/null | grep -Eq 'state = running|pid = [0-9]+'; then
        fail "runner ${name}: 停止中のはずが動いている"
      fi
    fi
  done < <(jin -r '.runners[] | [.repo, .label, .dir] | @tsv')
}

# ---------------------------------------------------------------------------------
# launcher: 夜間の起動（com.krtsato.watcher.nightly-launcher.A/B）。
# pre-import/cutover は plist が有り読み込まれていない、ready は読み込み済み。
# 未完了の再開記録（state-*.json の done が true でない）は、ready では警告、
# cutover（切り替えの直前）では失敗。
# ---------------------------------------------------------------------------------
group_launcher() {
  local label plist loaded f unfinished
  for label in $(jin -r '.labels[]'); do
    plist="${la_dir}/${label}.plist"
    [ -f "${plist}" ] || fail "夜間の起動 ${label}: plist が無い（${plist}）"
    if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then loaded=1; else loaded=0; fi
    if [ "${phase}" = ready ]; then
      [ "${loaded}" = 1 ] || fail "夜間の起動 ${label}: launchd に読み込まれていない"
    elif [ "${loaded}" = 1 ]; then
      fail "夜間の起動 ${label}: 停止中のはずが読み込まれている"
    fi
  done
  unfinished=""
  # shellcheck disable=SC2231
  for f in ${home}/$(jin -r '.state_glob'); do
    [ -f "${f}" ] || continue
    if ! jq -e '.done == true' "${f}" >/dev/null 2>&1; then
      unfinished="${unfinished} ${f##*/}"
    fi
  done
  if [ -n "${unfinished}" ]; then
    case "${phase}" in
      ready) warn "夜間の起動の再開記録: 未完了（done が true でない）:${unfinished}" ;;
      cutover) fail "夜間の起動の再開記録: 未完了（切り替えは全枠の完了後だけ）:${unfinished}" ;;
    esac
  fi
}

case "${group}" in
  profiles | files | clones | tools | opend | logins | github | runners | launcher) "group_${group}" ;;
  *) echo "unknown group: ${group}" >&2; exit 2 ;;
esac
