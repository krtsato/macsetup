#!/usr/bin/env bash
# 秘密の持ち出し・持ち込み（段 2）の検査。すべて一時のホームと偽の中身で行い、本物のホームは読まない。
# 入口は Makefile の make secrets-*（2 段）。偽の launchctl・gh を PATH の先頭に置く。合言葉はテスト専用の固定値を -stdinpass で渡す。
# (a) 往復 (b) 衝突で何も変えない (c) 配置の途中の失敗で戻す (d) 許可外の物があるイメージを拒否
# (e) export の拒否（読み込み済み・出力先） (f) restore と退避・復元 (g) 毎回取り外される
# (h) 出力にプロファイル名・中身・合言葉が出ない (i) プロファイル名を読めなければ名指しで失敗
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$(pwd -P)"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

log() { echo "==> $*"; }

tmp="$(mktemp -d)"
tmpname="$(basename "${tmp}")"
# Makefile と secrets.sh の一時ファイルをこの中へ寄せ、終了後に何も残らないことを確かめる
mkdir "${tmp}/t"
export TMPDIR="${tmp}/t"
trap 'rm -rf "${tmp}"; rm -f "${repo}/_test-secrets-out.dmg"' EXIT

passed=0
failed=0
pass_phrase="test-only-passphrase-123"
pa="zzprofa"   # 偽のプロファイル名（本物ではない）
pb="zzprofb"
all_out="${tmp}/all.out"
: >"${all_out}"

ok() { log "OK   $1"; passed=$((passed + 1)); }
ng() { log "FAIL $1"; failed=$((failed + 1)); }
assert() { # assert <名前> <コマンド...>
  local name="$1"
  shift
  if "$@"; then ok "${name}"; else ng "${name}"; fi
}
contains() { grep -Fq -- "$2" "$1"; }

# --- 偽の launchctl と gh --------------------------------------------------------------
fake="${tmp}/fakebin"
mkdir -p "${fake}"
cat >"${fake}/launchctl" <<'EOF'
#!/bin/bash
d="$(dirname "$0")"
case "$1" in
  print) grep -qx "${2##*/}" "${d}/loaded" 2>/dev/null ;;
  *) echo "unexpected launchctl call: $*" >&2; exit 1 ;;
esac
EOF
cat >"${fake}/gh" <<'EOF'
#!/bin/bash
echo "fake gh failure" >&2
exit 1
EOF
chmod +x "${fake}/launchctl" "${fake}/gh"
: >"${fake}/loaded"
# 偽物が本当に先に見つかるかを、役割と同じ PATH で確かめる。外れたら本物を叩く恐れがあるので中止
for cmd in launchctl gh; do
  got="$(PATH="${fake}:${PATH}" command -v "${cmd}")"
  if [ "${got}" != "${fake}/${cmd}" ]; then
    echo "==> 中止: ${cmd} が偽物でなく ${got} に解決される" >&2
    exit 1
  fi
done

# --- 許可一覧（正本）を JSON にして読む。展開は偽のプロファイル名 --------------------
/usr/bin/ruby -ryaml -rjson -e 'puts JSON.generate(YAML.load_file("ansible/roles/doctor/vars/main.yaml"))' >"${tmp}/vars.json"

# make_home <ディレクトリ>: 許可一覧の全項目に偽の中身を作り、期待するファイル一覧を expected.files に書く
# 権限はわざと緩く（0644/0755）して、持ち出しで正規化されることを見る。除外対象と対象外の物も置く
make_home() {
  local h="$1" rel kind recursive e c dir label
  mkdir -p "${h}"
  : >"${tmp}/expected.files"
  while IFS= read -r e; do
    kind="$(jq -r '.kind' <<<"${e}")"
    recursive="$(jq -r '.recursive // false' <<<"${e}")"
    for rel in $(jq -r --arg a "${pa}" --arg b "${pb}" '(if .per_profile then [$a, $b] else [""] end)[] as $p | .path | split("{profile}") | join($p)' <<<"${e}"); do
      if [ "${kind}" = file ]; then
        mkdir -p "${h}/$(dirname "${rel}")"
        printf 'SECRET-CONTENT-%s\n' "${rel}" >"${h}/${rel}"
        echo "${rel}" >>"${tmp}/expected.files"
      elif [ "${recursive}" = true ]; then
        mkdir -p "${h}/${rel}/sub"
        for c in one.json sub/two.json; do
          printf 'SECRET-CONTENT-%s/%s\n' "${rel}" "${c}" >"${h}/${rel}/${c}"
          echo "${rel}/${c}" >>"${tmp}/expected.files"
        done
        : >"${h}/${rel}/.DS_Store"
        : >"${h}/${rel}/state.lock"
        : >"${h}/${rel}/sub/.lock"
      else
        mkdir -p "${h}/${rel}"
        for c in $(jq -r '.children[]' <<<"${e}"); do
          printf 'SECRET-CONTENT-%s/%s\n' "${rel}" "${c}" >"${h}/${rel}/${c}"
          echo "${rel}/${c}" >>"${tmp}/expected.files"
        done
        printf 'SECRET-CONTENT-other\n' >"${h}/${rel}/other.json"   # 許可の外。運ばれない
      fi
    done
  done < <(jq -c '.doctor_config_files[]' "${tmp}/vars.json")
  # 対象外（許可一覧に無い物）
  printf 'SECRET-CONTENT-decoy\n' >"${h}/.config/mcp-notebooklm/nlm/chrome-port-map.json"
  mkdir -p "${h}/.config/mcp-mediable/captions"
  printf 'SECRET-CONTENT-decoy\n' >"${h}/.config/mcp-mediable/captions/x.txt"
  printf 'SECRET-CONTENT-decoy\n' >"${h}/.config/mcp-note/notebooklm.cookies.txt"
  # 停止の確認が見る実行役の .service（運ばれない）
  while IFS=$'\t' read -r dir label; do
    mkdir -p "${h}/${dir}"
    echo "${h}/Library/LaunchAgents/actions.runner.test.${label}.plist" >"${h}/${dir}/.service"
  done < <(jq -r '.doctor_runners[] | [.dir, .label] | @tsv' "${tmp}/vars.json")
  find "${h}" -type f -exec chmod 644 {} +
  find "${h}" -type d -exec chmod 755 {} +
  LC_ALL=C sort -o "${tmp}/expected.files" "${tmp}/expected.files"
}

# run_secrets <名前> <action> <イメージ>。Makefile と同じ入口（make secrets-*）を流す。
# 合言葉はテスト専用の SECRETS_TEST_STDINPASS=1 で標準入力から渡す。<名前>.out と <名前>.rc を作る
# home は HOME_UNDER_TEST、fail_after は FAIL_AFTER で渡す
HOME_UNDER_TEST=""
FAIL_AFTER=0
PROFILES_JSON="[\"${pa}\",\"${pb}\"]"
run_secrets() {
  local name="$1" action="$2" img="$3" rc=0 arg=()
  case "${action}" in
    export) arg=("OUT=${img}") ;;
    import | restore) arg=("IMAGE=${img}") ;;
    *) ;;
  esac
  printf '%s' "${pass_phrase}" | env SECRETS_HOME="${HOME_UNDER_TEST}" SECRETS_PROFILES_OVERRIDE="${PROFILES_JSON}" \
    SECRETS_PATH_PREFIX="${fake}:" SECRETS_TEST_STDINPASS=1 SECRETS_TEST_FAIL_AFTER="${FAIL_AFTER}" \
    SECRETS_TEST_SKIP_DOCTOR=1 make "secrets-${action}" ${arg[@]+"${arg[@]}"} >"${tmp}/${name}.out" 2>&1 || rc=$?
  echo "${rc}" >"${tmp}/${name}.rc"
  cat "${tmp}/${name}.out" >>"${all_out}"
}
rc_of() { cat "${tmp}/$1.rc"; }
rc_is_zero() { [ "$(rc_of "$1")" = 0 ]; }
rc_is_nonzero() { [ "$(rc_of "$1")" != 0 ]; }

# (g) イメージが取り付けられたまま残っていない
assert_detached() {
  local label="$1"
  if hdiutil info 2>/dev/null | grep -Fq -- "${tmpname}"; then
    ng "(g) ${label}: イメージが取り付けられたまま"
    hdiutil info | grep -F -- "${tmpname}" | head -3
  else
    ok "(g) ${label}: 取り外されている"
  fi
}

snapshot() { # snapshot <dir>: パス・種別・権限・中身の要約（比較専用。出力しない）
  (cd "$1" && find . -print0 | LC_ALL=C sort -z | xargs -0 stat -f '%N %Lp' && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum | cut -d' ' -f1)
}

# ===================================================================================
log "準備: 旧端末の偽のホーム"
home_a="${tmp}/home-a"
make_home "${home_a}"
cp "${tmp}/expected.files" "${tmp}/expected-a.files"
nexp="$(wc -l <"${tmp}/expected-a.files" | tr -d ' ')"
log "期待するファイル数: ${nexp}"
img="${tmp}/out/secrets.dmg"
mkdir -p "${tmp}/out"

# (e) export の拒否 -----------------------------------------------------------------
log "(e) export の拒否"
HOME_UNDER_TEST="${home_a}"
for lbl in "actions.runner.test.mediable-sync" "com.krtsato.watcher.nightly-launcher.B"; do
  echo "${lbl}" >"${fake}/loaded"
  run_secrets e1 export "${img}"
  assert "(e) 読み込み済み ${lbl}: 拒否" rc_is_nonzero e1
  assert "(e) 読み込み済み ${lbl}: 名指し" contains "${tmp}/e1.out" "${lbl}"
  assert "(e) 読み込み済み ${lbl}: イメージを作らない" test ! -e "${img}"
done
: >"${fake}/loaded"
run_secrets e2 export "${repo}/_test-secrets-out.dmg"
assert "(e) リポジトリの中: 拒否" rc_is_nonzero e2
assert "(e) リポジトリの中: 理由" contains "${tmp}/e2.out" "リポジトリの中"
assert "(e) リポジトリの中: 作らない" test ! -e "${repo}/_test-secrets-out.dmg"
: >"${tmp}/out/exists.dmg"
run_secrets e3 export "${tmp}/out/exists.dmg"
assert "(e) 既に存在: 拒否" rc_is_nonzero e3
assert "(e) 既に存在: 理由" contains "${tmp}/e3.out" "既に存在"
assert "(e) 既に存在: 上書きしない" test ! -s "${tmp}/out/exists.dmg"
run_secrets e4 export "${tmp}/out/not-dmg.img"
assert "(e) 拡張子が .dmg でない: 拒否" rc_is_nonzero e4
assert_detached "(e)"

# (i) プロファイル名を読めない ---------------------------------------------------------
log "(i) プロファイル名を GitHub から読めない"
PROFILES_JSON='[]'
run_secrets i1 export "${tmp}/out/i.dmg"
assert "(i) 失敗する" rc_is_nonzero i1
assert "(i) 読めなかった repo を名指し" contains "${tmp}/i1.out" "mcp-note/NOTEBOOKLM_PROFILE"
assert "(i) イメージを作らない" test ! -e "${tmp}/out/i.dmg"
PROFILES_JSON="[\"${pa}\",\"${pb}\"]"

# (a) 往復 -----------------------------------------------------------------------------
log "(a) 往復: export → import"
run_secrets a1 export "${img}"
assert "(a) export 成功" rc_is_zero a1
assert "(a) イメージがある" test -f "${img}"
assert "(a) イメージの権限 0600" test "$(stat -f %Lp "${img}")" = 600
assert "(a) 別名で表示" contains "${tmp}/a1.out" "<プロファイル1>"
assert_detached "(a) export"

home_b="${tmp}/home-b"
mkdir "${home_b}"
HOME_UNDER_TEST="${home_b}"
run_secrets a2 import "${img}"
assert "(a) import 成功" rc_is_zero a2
(cd "${home_b}" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) >"${tmp}/actual-b.files"
assert "(a) ファイルの集合が期待どおり（除外・対象外は運ばれない）" cmp -s "${tmp}/expected-a.files" "${tmp}/actual-b.files"
assert "(a) 権限は ファイル 0600・ディレクトリ 0700 のみ" test -z "$(find "${home_b}" -mindepth 1 \( -type f ! -perm 600 \) -o \( -type d ! -perm 700 \))"
assert "(a) .DS_Store と .lock を運ばない" test -z "$(find "${home_b}" \( -name .DS_Store -o -name .lock -o -name '*.lock' \))"
assert "(a) 一時の置き場が残らない" test -z "$(find "${home_b}" -maxdepth 1 -name '.macsetup-*')"
diffs=0
while IFS= read -r f; do cmp -s "${home_a}/${f}" "${home_b}/${f}" || diffs=$((diffs + 1)); done <"${tmp}/expected-a.files"
assert "(a) 中身が一致（cmp 不一致 0 件）" test "${diffs}" = 0
assert_detached "(a) import"

# (b) 衝突 -----------------------------------------------------------------------------
log "(b) 衝突: 何も変えない"
home_c="${tmp}/home-c"
mkdir -p "${home_c}/.codex" "${home_c}/.config/mcp-note/notebooklm-inbox"
echo "existing-codex" >"${home_c}/.codex/auth.json"
echo "existing-inbox" >"${home_c}/.config/mcp-note/notebooklm-inbox/keep.json"
snapshot "${home_c}" >"${tmp}/snap-c-before"
HOME_UNDER_TEST="${home_c}"
run_secrets b1 import "${img}"
assert "(b) 失敗する" rc_is_nonzero b1
assert "(b) 衝突（ファイル）を列挙" contains "${tmp}/b1.out" ".codex/auth.json"
assert "(b) 衝突（ディレクトリ）を列挙" contains "${tmp}/b1.out" ".config/mcp-note/notebooklm-inbox"
assert "(b) 何も変更していないと表示" contains "${tmp}/b1.out" "何も変更していない"
snapshot "${home_c}" >"${tmp}/snap-c-after"
assert "(b) ホームがバイト単位で不変" cmp -s "${tmp}/snap-c-before" "${tmp}/snap-c-after"
assert_detached "(b)"

# (c) 配置の途中の失敗 -------------------------------------------------------------------
log "(c) 配置の途中で失敗 → 配置前へ戻す"
home_e="${tmp}/home-e"
mkdir "${home_e}"
HOME_UNDER_TEST="${home_e}"
FAIL_AFTER=3
run_secrets c1 import "${img}"
FAIL_AFTER=0
assert "(c) 失敗する" rc_is_nonzero c1
assert "(c) 戻したと表示" contains "${tmp}/c1.out" "配置前の状態へ戻した"
assert "(c) 何も残っていない（親ディレクトリも一時の置き場も）" test -z "$(find "${home_e}" -mindepth 1)"
assert_detached "(c)"

# (d) 許可外の物があるイメージ -------------------------------------------------------------
log "(d) 許可外の物があるイメージ"
# mkimage <名前> <改変の関数名>: export したイメージを開き、中身を改変して別のイメージにする
mkimage() {
  local name="$1" mod="$2"
  local m="${tmp}/m-${name}" src="${tmp}/src-${name}"
  mkdir "${m}"
  printf '%s' "${pass_phrase}" | hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "${m}" -stdinpass "${img}" >/dev/null
  mkdir "${src}"
  cp -R "${m}/." "${src}/"
  hdiutil detach "${m}" >/dev/null
  chmod -R u+w "${src}"
  rm -rf "${src}/.fseventsd" "${src}/.Spotlight-V100" "${src}/.Trashes"
  "${mod}" "${src}"
  printf '%s' "${pass_phrase}" | hdiutil create -encryption AES-256 -fs APFS -volname macsetup-secrets -srcfolder "${src}" \
    "${tmp}/out/${name}.dmg" -stdinpass >/dev/null
}
mod_stray() { echo "x" >"$1/stray.txt"; }
mod_extra_in_carried_dir() { echo "x" >"$1/.config/mcp-mediable/extra.txt"; }
mod_manifest_not_allowlisted() {
  mkdir -p "$1/.ssh"
  echo "x" >"$1/.ssh/id_test"
  jq '.entries += [{path: ".ssh/id_test", class: "auth", kind: "file", files: [".ssh/id_test"]}]' "$1/MANIFEST.json" >"$1/M.new"
  mv "$1/M.new" "$1/MANIFEST.json"
}
mod_manifest_nonlisted_child() {
  local pdir=".config/mcp-notebooklm/nlm/profiles/default"
  echo "x" >"$1/${pdir}/other.json"
  jq --arg f "${pdir}/other.json" --arg d "${pdir}" '(.entries[] | select(.path == $d) | .files) += [$f]' "$1/MANIFEST.json" >"$1/M.new"
  mv "$1/M.new" "$1/MANIFEST.json"
}
HOME_UNDER_TEST=""
for spec in "stray:mod_stray:一致しない" "extra:mod_extra_in_carried_dir:一致しない" \
  "notallowed:mod_manifest_not_allowlisted:許可一覧に無い項目" "nonlisted:mod_manifest_nonlisted_child:許可外のファイル"; do
  name="${spec%%:*}"
  rest="${spec#*:}"
  mod="${rest%%:*}"
  want="${rest#*:}"
  mkimage "${name}" "${mod}"
  home_f="${tmp}/home-f-${name}"
  mkdir "${home_f}"
  HOME_UNDER_TEST="${home_f}"
  img_saved="${img}"
  img="${tmp}/out/${name}.dmg"
  run_secrets "d-${name}" import "${img}"
  img="${img_saved}"
  assert "(d) ${name}: 拒否" rc_is_nonzero "d-${name}"
  assert "(d) ${name}: 理由 ${want}" contains "${tmp}/d-${name}.out" "${want}"
  assert "(d) ${name}: 何も置かない" test -z "$(find "${home_f}" -mindepth 1)"
  assert_detached "(d) ${name}"
done

# (f) restore -------------------------------------------------------------------------
log "(f) restore: 退避して置き換える"
home_d="${tmp}/home-d"
mkdir -p "${home_d}/.codex" "${home_d}/.config/mcp-note/notebooklm-inbox"
echo "old-codex" >"${home_d}/.codex/auth.json"
echo "old-inbox" >"${home_d}/.config/mcp-note/notebooklm-inbox/old.json"
HOME_UNDER_TEST="${home_d}"
run_secrets f1 restore "${img}"
assert "(f) 成功" rc_is_zero f1
assert "(f) 置いた中身が一致（認証）" cmp -s "${home_a}/.codex/auth.json" "${home_d}/.codex/auth.json"
assert "(f) 置いた中身が一致（受け箱）" cmp -s "${home_a}/.config/mcp-note/notebooklm-inbox/one.json" "${home_d}/.config/mcp-note/notebooklm-inbox/one.json"
assert "(f) 古い受け箱の物は置換後に無い" test ! -e "${home_d}/.config/mcp-note/notebooklm-inbox/old.json"
backup="$(find "${home_d}" -maxdepth 1 -type d -name '.macsetup-restore-backup-*' | head -1)"
assert "(f) 退避先がある" test -n "${backup}"
assert "(f) 退避先は 0700" test "$(stat -f %Lp "${backup}")" = 700
assert "(f) 古い認証が退避先にある" test "$(cat "${backup}/.codex/auth.json")" = old-codex
assert "(f) 古い受け箱が退避先にある" test "$(cat "${backup}/.config/mcp-note/notebooklm-inbox/old.json")" = old-inbox
assert "(f) 退避先を表示" contains "${tmp}/f1.out" ".macsetup-restore-backup-"
assert_detached "(f)"

log "(f2) restore の途中の失敗 → 退避した物を戻す"
home_g="${tmp}/home-g"
mkdir -p "${home_g}/.codex" "${home_g}/.config/mcp-note/notebooklm-inbox" "${home_g}/.config/mcp-youtube"
echo "old-codex" >"${home_g}/.codex/auth.json"
echo "old-inbox" >"${home_g}/.config/mcp-note/notebooklm-inbox/old.json"
echo "old-token" >"${home_g}/.config/mcp-youtube/token.json"
snapshot "${home_g}" >"${tmp}/snap-g-before"
HOME_UNDER_TEST="${home_g}"
FAIL_AFTER=12
run_secrets f2 restore "${img}"
FAIL_AFTER=0
assert "(f2) 失敗する" rc_is_nonzero f2
snapshot "${home_g}" >"${tmp}/snap-g-after"
assert "(f2) 元の状態へ戻る（置いた物なし・退避先なし）" cmp -s "${tmp}/snap-g-before" "${tmp}/snap-g-after"
assert_detached "(f2)"

log "(f3) restore も、読み込み済みなら拒否"
echo "com.krtsato.watcher.nightly-launcher.A" >"${fake}/loaded"
run_secrets f3 restore "${img}"
assert "(f3) 拒否" rc_is_nonzero f3
assert "(f3) 理由" contains "${tmp}/f3.out" "読み込まれている"
: >"${fake}/loaded"

# (j) 擬似端末で make secrets-export / secrets-import を流し、対話の合言葉入力が通ることを確かめる ---------
log "(j) 擬似端末（script）で対話の合言葉入力"
# wait_for <ファイル> <正規表現> [回数]: 出力にその行が現れるまで最大 90 秒待つ
wait_for() {
  local i=0
  while [ "${i}" -lt "${WAIT_TICKS:-180}" ]; do
    [ "$(grep -Ec -- "$2" "$1" || true)" -ge "${3:-1}" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}
# pty_feed <ログ> <回数>: 端末のプロンプトがログに現れるのを待ってから、合言葉を標準出力へ打つ
pty_feed() {
  local log="$1" times="$2" n=0
  while [ "${n}" -lt "${times}" ]; do
    n=$((n + 1))
    # 1 回目は「パスワード」を含む行、2 回目は再入力の行を待つ（先に打つとプロンプトが入力を捨てる）
    if [ "${n}" = 1 ]; then wait_for "${log}" 'パスワード|assword|passphrase' 1 || return 0; else wait_for "${log}" '再入力|e-enter|erify' 1 || return 0; fi
    sleep 0.5
    printf '%s\r' "${pass_phrase}"
  done
  wait_for "${log}" '作成した|配置した|失敗' 1 || true
}
# pty_run <名前> <入力する合言葉の回数> <make の引数...>: script（擬似端末）の中で make を流す
pty_run() {
  local name="$1" times="$2" log="${tmp}/$1.out"
  shift 2
  : >"${log}"
  # 送り手はログを読み、script はログへ書く。読むのは書かれた後なので意図どおり
  # shellcheck disable=SC2094
  pty_feed "${log}" "${times}" | env SECRETS_HOME="${HOME_UNDER_TEST}" SECRETS_PROFILES_OVERRIDE="${PROFILES_JSON}" \
    SECRETS_PATH_PREFIX="${fake}:" SECRETS_TEST_SKIP_DOCTOR=1 script -q /dev/null make "$@" >"${log}" 2>&1 || true
  cat "${log}" >>"${all_out}"
  if [ -n "${PTY_DEBUG:-}" ]; then echo "--- ${name}"; cat "${log}"; fi
}
home_p="${tmp}/home-p"
make_home "${home_p}"
cp "${tmp}/expected.files" "${tmp}/expected-p.files"
HOME_UNDER_TEST="${home_p}"
pty_run j1 2 secrets-export "OUT=${tmp}/out/pty.dmg"
assert "(j) export が擬似端末で成功（イメージができる）" test -f "${tmp}/out/pty.dmg"
assert "(j) export: 完了の表示" contains "${tmp}/j1.out" "作成した"
assert "(j) export: イメージの権限 0600" test "$(stat -f %Lp "${tmp}/out/pty.dmg")" = 600
assert_detached "(j) export"
home_q="${tmp}/home-q"
mkdir "${home_q}"
HOME_UNDER_TEST="${home_q}"
pty_run j2 1 secrets-import "IMAGE=${tmp}/out/pty.dmg"
(cd "${home_q}" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) >"${tmp}/actual-q.files"
assert "(j) import が擬似端末で成功（ファイルの集合が一致）" cmp -s "${tmp}/expected-p.files" "${tmp}/actual-q.files"
diffs=0
while IFS= read -r f; do cmp -s "${home_p}/${f}" "${home_q}/${f}" || diffs=$((diffs + 1)); done <"${tmp}/expected-p.files"
assert "(j) import: 中身が一致" test "${diffs}" = 0
assert_detached "(j) import"
assert "(j) 一時の入力・作業ファイルが何も残らない（全ケース後）" test -z "$(find "${tmp}/t" -mindepth 1)"

# (h) 出力に秘密が出ない --------------------------------------------------------------------
log "(h) 全出力にプロファイル名・中身・合言葉が出ない"
assert "(h) プロファイル名 ${pa} が 0 件" test "$(grep -c -- "${pa}" "${all_out}" || true)" = 0
assert "(h) プロファイル名 ${pb} が 0 件" test "$(grep -c -- "${pb}" "${all_out}" || true)" = 0
assert "(h) 中身（SECRET-CONTENT）が 0 件" test "$(grep -c "SECRET-CONTENT" "${all_out}" || true)" = 0
assert "(h) 合言葉が 0 件" test "$(grep -c -- "${pass_phrase}" "${all_out}" || true)" = 0
assert "(h) 別名は出る" contains "${all_out}" "<プロファイル2>"

echo
log "合計: 合格 ${passed} / 失敗 ${failed}"
[ "${failed}" -eq 0 ]
