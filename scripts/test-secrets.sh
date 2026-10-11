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
  # 本物と同じく、無ければ 113。launchctl-broken があれば問い合わせ自体の失敗（112）を返す
  print)
    [ -e "${d}/launchctl-broken" ] && exit 112
    grep -qx "${2##*/}" "${d}/loaded" 2>/dev/null || exit 113 ;;
  *) echo "unexpected launchctl call: $*" >&2; exit 1 ;;
esac
EOF
cat >"${fake}/gh" <<'EOF'
#!/bin/bash
echo "fake gh failure" >&2
exit 1
EOF
# 偽の pgrep: pgrep-match に書いた文字列を含む検索だけ「動いている」と答える
cat >"${fake}/pgrep" <<'EOF'
#!/bin/bash
d="$(dirname "$0")"
m="$(cat "${d}/pgrep-match" 2>/dev/null || true)"
if [ -n "${m}" ] && [[ "$*" == *"${m}"* ]]; then echo 12345; exit 0; fi
exit 1
EOF
# 偽の mv: mv-fail に書いた文字列を含む引数のときだけ、パス入りのエラーを出して失敗する（漏えい検査用）
cat >"${fake}/mv" <<'EOF'
#!/bin/bash
d="$(dirname "$0")"
if [ -f "${d}/mv-fail" ] && [[ "$*" == *"$(cat "${d}/mv-fail")"* ]]; then
  echo "mv: cannot move $*: injected failure" >&2
  exit 1
fi
exec /bin/mv "$@"
EOF
# 偽の hdiutil: detach-fail があれば detach だけ失敗する。他は本物へ渡す（標準入力も）
cat >"${fake}/hdiutil" <<'EOF'
#!/bin/bash
d="$(dirname "$0")"
if [ "$1" = detach ] && [ -f "${d}/detach-fail" ]; then echo "hdiutil: detach failed" >&2; exit 16; fi
exec /usr/bin/hdiutil "$@"
EOF
chmod +x "${fake}/launchctl" "${fake}/gh" "${fake}/pgrep" "${fake}/mv" "${fake}/hdiutil"
: >"${fake}/loaded"
# 偽物が本当に先に見つかるかを、役割と同じ PATH で確かめる。外れたら本物を叩く恐れがあるので中止
for cmd in launchctl gh pgrep mv hdiutil; do
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
KILL_AFTER=0
PROFILES_JSON="[\"${pa}\",\"${pb}\"]"
run_secrets() {
  local name="$1" action="$2" img="$3" rc=0 arg=()
  case "${action}" in
    export) arg=("OUT=${img}") ;;
    import | restore) arg=("IMAGE=${img}") ;;
    *) ;;
  esac
  printf '%s' "${pass_phrase}" | env SECRETS_HOME="${HOME_UNDER_TEST}" SECRETS_PROFILES_OVERRIDE="${PROFILES_JSON}" \
    SECRETS_PATH_PREFIX="${fake}:" SECRETS_TEST_STDINPASS=1 SECRETS_TEST_FAIL_AFTER="${FAIL_AFTER}" SECRETS_TEST_KILL_AFTER_MOVE="${KILL_AFTER}" \
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
mod_missing_required_file() {
  rm -f "${1:?}/.codex/auth.json"
  jq 'del(.entries[] | select(.path == ".codex/auth.json"))' "$1/MANIFEST.json" >"$1/M.new"
  mv "$1/M.new" "$1/MANIFEST.json"
}
mod_missing_required_child() {
  local pdir=".config/mcp-notebooklm/nlm/profiles/default"
  rm -f "${1:?}/${pdir:?}/cookies.json"
  jq --arg f "${pdir}/cookies.json" --arg d "${pdir}" '(.entries[] | select(.path == $d) | .files) -= [$f]' "$1/MANIFEST.json" >"$1/M.new"
  mv "$1/M.new" "$1/MANIFEST.json"
}
HOME_UNDER_TEST=""
for spec in "stray:mod_stray:一致しない" "extra:mod_extra_in_carried_dir:一致しない" \
  "notallowed:mod_manifest_not_allowlisted:許可一覧に無い項目" "nonlisted:mod_manifest_nonlisted_child:許可外のファイル" \
  "noauth:mod_missing_required_file:必須の項目が無い" "nochild:mod_missing_required_child:必須のファイルが無い"; do
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
assert "(f3) 理由" contains "${tmp}/f3.out" "読み込み済み:"
: >"${fake}/loaded"

# (q) 問い合わせの失敗と予約名 ----------------------------------------------------------------
log "(q) launchctl の問い合わせ失敗／ プロファイル名 default"
HOME_UNDER_TEST="${home_a}"
touch "${fake}/launchctl-broken"
run_secrets q1 export "${tmp}/out/q1.dmg"
rm -f "${fake}/launchctl-broken"
assert "(q1) 問い合わせ失敗: 拒否" rc_is_nonzero q1
assert "(q1) 理由" contains "${tmp}/q1.out" "確かめられない（launchctl が終了コード 112）"
assert "(q1) イメージを作らない" test ! -e "${tmp}/out/q1.dmg"
PROFILES_JSON='["default"]'
run_secrets q2 export "${tmp}/out/q2.dmg"
PROFILES_JSON="[\"${pa}\",\"${pb}\"]"
assert "(q2) default: 拒否" rc_is_nonzero q2
assert "(q2) 理由" contains "${tmp}/q2.out" "default は予約名"
assert "(q2) イメージを作らない" test ! -e "${tmp}/out/q2.dmg"

# (k) 実行役の停止確認は fail-closed ---------------------------------------------------------
log "(k) 実行役: .runner が有るのに .service が無い／ Runner.Listener が動いている"
HOME_UNDER_TEST="${home_a}"
rdir="dev/me/mcp-note/actions-runners/magazine-sync"
cp "${home_a}/${rdir}/.service" "${tmp}/service.save"
echo '{}' >"${home_a}/${rdir}/.runner"
rm -f "${home_a:?}/${rdir:?}/.service"
run_secrets k1 export "${tmp}/out/k1.dmg"
assert "(k1) .service が無い: 拒否" rc_is_nonzero k1
assert "(k1) 実行役を名指し" contains "${tmp}/k1.out" "mcp-note/magazine-sync"
assert "(k1) 理由" contains "${tmp}/k1.out" ".service が無い"
assert "(k1) イメージを作らない" test ! -e "${tmp}/out/k1.dmg"
cp "${tmp}/service.save" "${home_a}/${rdir}/.service"
echo "mcp-seeking-alpha/actions-runners/alpha-picks-sync" >"${fake}/pgrep-match"
mkdir -p "${home_a}/dev/me/mcp-seeking-alpha/actions-runners/alpha-picks-sync/bin"
run_secrets k2 export "${tmp}/out/k2.dmg"
assert "(k2) Runner.Listener が動いている: 拒否" rc_is_nonzero k2
assert "(k2) 理由" contains "${tmp}/k2.out" "Runner.Listener の process が動いている"
assert "(k2) イメージを作らない" test ! -e "${tmp}/out/k2.dmg"
run_secrets k2r restore "${img}"
assert "(k2) restore も拒否" rc_is_nonzero k2r
: >"${fake}/pgrep-match"
run_secrets k3 list ""
assert "(k3) .runner と .service があり process が無ければ止まっている扱い" contains "${tmp}/k3.out" "読み込まれていない（export・restore できる）"
rm -f "${home_a:?}/${rdir:?}/.runner"

# (l) 失敗経路の標準エラーにプロファイル名が出ない ------------------------------------------------
log "(l) 失敗経路でも本物のプロファイル名が出ない"
unreadable="${home_a}/.config/mcp-notebooklm/cookies/${pa}.cookies.txt"
chmod 000 "${unreadable}"
run_secrets l1 export "${tmp}/out/l1.dmg"
chmod 644 "${unreadable}"
assert "(l1) 読めない元ファイル: export 失敗" rc_is_nonzero l1
assert "(l1) 別名で報告" contains "${tmp}/l1.out" "<プロファイル1>.cookies.txt"
assert "(l1) 名前が出ない" test "$(grep -c -- "${pa}" "${tmp}/l1.out" || true)" = 0
assert "(l1) 書きかけのイメージを残さない" test ! -e "${tmp}/out/l1.dmg"
home_l="${tmp}/home-l"
mkdir "${home_l}"
HOME_UNDER_TEST="${home_l}"
echo "${pa}" >"${fake}/mv-fail"
run_secrets l2 import "${img}"
rm -f "${fake}/mv-fail"
assert "(l2) mv の失敗: import 失敗" rc_is_nonzero l2
assert "(l2) 道具のエラーは別名つきで出る" contains "${tmp}/l2.out" "injected failure"
assert "(l2) 別名で報告" contains "${tmp}/l2.out" "<プロファイル1>"
assert "(l2) 名前が出ない" test "$(grep -c -- "${pa}" "${tmp}/l2.out" || true)" = 0
assert "(l2) 何も残らない" test -z "$(find "${home_l}" -mindepth 1)"
assert_detached "(l)"

# (m) 別名の置き換えは長い名前から（p1 と p10）------------------------------------------------
log "(m) プロファイル名が別の名前の先頭と同じ（p1 と p10）"
pa_save="${pa}"
pb_save="${pb}"
pa="p1"
pb="p10"
PROFILES_JSON='["p1","p10"]'
home_x="${tmp}/home-x"
make_home "${home_x}"
HOME_UNDER_TEST="${home_x}"
run_secrets m1 export "${tmp}/out/m.dmg"
assert "(m) export 成功" rc_is_zero m1
home_y="${tmp}/home-y"
mkdir -p "${home_y}/.config/mcp-notebooklm/cookies"
echo old >"${home_y}/.config/mcp-notebooklm/cookies/p1.cookies.txt"
echo old >"${home_y}/.config/mcp-notebooklm/cookies/p10.cookies.txt"
HOME_UNDER_TEST="${home_y}"
run_secrets m2 import "${tmp}/out/m.dmg"
assert "(m) 衝突で失敗" rc_is_nonzero m2
assert "(m) p1 は <プロファイル1>" contains "${tmp}/m2.out" "cookies/<プロファイル1>.cookies.txt"
assert "(m) p10 は <プロファイル2>" contains "${tmp}/m2.out" "cookies/<プロファイル2>.cookies.txt"
assert "(m) p10 が残らない" test "$(grep -c "p10" "${tmp}/m2.out" || true)" = 0
assert "(m) 別名の後ろに 0 が付かない" test "$(grep -c "<プロファイル1>0" "${tmp}/m2.out" || true)" = 0
pa="${pa_save}"
pb="${pb_save}"
PROFILES_JSON="[\"${pa}\",\"${pb}\"]"

# (n) 取り外せないときは先へ進まない -----------------------------------------------------------
log "(n) 取り外しに失敗したら配置しない"
home_n="${tmp}/home-n"
mkdir "${home_n}"
HOME_UNDER_TEST="${home_n}"
: >"${fake}/detach-fail"
run_secrets n1 import "${img}"
rm -f "${fake}/detach-fail"
assert "(n) 失敗する" rc_is_nonzero n1
assert "(n) 取り付け先を表示" contains "${tmp}/n1.out" "取り付け先"
assert "(n) 何も置いていない" test -z "$(find "${home_n}" -mindepth 1)"
mp="$(sed -n 's/.*取り付け先 \([^ ]*\) を残す.*/\1/p' "${tmp}/n1.out" | head -1)"
assert "(n) 取り付け先が残っている（手で外せる）" test -n "${mp}" -a -d "${mp}"
if [ -n "${mp}" ]; then
  /usr/bin/hdiutil detach -force "${mp}" >/dev/null 2>&1 || true
  mp_dir="$(dirname "${mp}")"
  rm -rf "${mp_dir:?}"
fi
assert_detached "(n)"

# (p) 強制終了からの復旧（書き込み先行の記録）---------------------------------------------------------
log "(p) mv の直後に SIGKILL → make secrets-recover で配置前へ"
home_r="${tmp}/home-r"
mkdir "${home_r}"
HOME_UNDER_TEST="${home_r}"
KILL_AFTER=3
run_secrets p1 import "${img}"
KILL_AFTER=0
sleep 1
rm -rf "${tmp:?}/t"/*   # 強制終了で残った作業用ディレクトリ
assert "(p1) 強制終了で失敗" rc_is_nonzero p1
assert "(p1) 置きかけの物が実際に残っている（窓が本物）" test -d "${home_r}/.config" -o -d "${home_r}/.codex"
assert "(p1) 一時の置き場が残っている" test -n "$(find "${home_r}" -maxdepth 1 -name '.macsetup-import.*')"
snapshot "${home_r}" >"${tmp}/snap-r1"
run_secrets p1b import "${img}"
assert "(p1) 続けての import は拒否" rc_is_nonzero p1b
assert "(p1) recover を案内" contains "${tmp}/p1b.out" "make secrets-recover"
snapshot "${home_r}" >"${tmp}/snap-r2"
assert "(p1) 拒否は何も変えない" cmp -s "${tmp}/snap-r1" "${tmp}/snap-r2"
run_secrets p1r recover ""
assert "(p1) recover 成功" rc_is_zero p1r
assert "(p1) 配置前（空）へ戻る" test -z "$(find "${home_r}" -mindepth 1)"
run_secrets p1r2 recover ""
assert "(p1) recover は冪等（2 回目も成功）" rc_is_zero p1r2
assert "(p1) 2 回目は戻す跡が無い" contains "${tmp}/p1r2.out" "戻す跡は無い"
run_secrets p1i import "${img}"
assert "(p1) 復旧後の import は成功" rc_is_zero p1i
assert_detached "(p1)"

for kn in 1 2; do
  log "(p) restore を ${kn} 回目の mv の直後に SIGKILL"
  home_s="${tmp}/home-s${kn}"
  mkdir -p "${home_s}/.codex" "${home_s}/.config/mcp-notebooklm/cookies"
  echo "old-codex" >"${home_s}/.codex/auth.json"
  echo "old-cookie" >"${home_s}/.config/mcp-notebooklm/cookies/${pa}.cookies.txt"
  snapshot "${home_s}" >"${tmp}/snap-s${kn}-before"
  HOME_UNDER_TEST="${home_s}"
  KILL_AFTER="${kn}"
  run_secrets "p2-${kn}" restore "${img}"
  KILL_AFTER=0
  sleep 1
  rm -rf "${tmp:?}/t"/*
  assert "(p2-${kn}) 強制終了で失敗" rc_is_nonzero "p2-${kn}"
  snapshot "${home_s}" >"${tmp}/snap-s${kn}-crash"
  assert "(p2-${kn}) 途中の状態が実際に残っている（窓が本物）" test "$(cmp -s "${tmp}/snap-s${kn}-before" "${tmp}/snap-s${kn}-crash" && echo same || echo differs)" = differs
  if [ "${kn}" = 1 ]; then
    assert "(p2-1) 元のファイルが退避先に取り残されている" test ! -e "${home_s}/.config/mcp-notebooklm/cookies/${pa}.cookies.txt"
  fi
  run_secrets "p2r-${kn}" recover ""
  assert "(p2-${kn}) recover 成功" rc_is_zero "p2r-${kn}"
  snapshot "${home_s}" >"${tmp}/snap-s${kn}-after"
  assert "(p2-${kn}) 元の状態へバイト単位で戻る（退避先も一時の置き場も無い）" cmp -s "${tmp}/snap-s${kn}-before" "${tmp}/snap-s${kn}-after"
  run_secrets "p2r2-${kn}" recover ""
  assert "(p2-${kn}) recover は冪等" rc_is_zero "p2r2-${kn}"
  assert_detached "(p2-${kn})"
done

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
