#!/usr/bin/env bash
# cutover-lib.sh・cutover-trial.sh・cutover-check.sh の検査。GitHub への書き込みも問い合わせ（gh）も無い
# （(a)(b) は本物の複製を git fetch するだけ。(c)〜(e) は一時の git リポジトリと偽の gh）。
# (a) 今の GitHub の main から作った完了の一覧が 確認対象 21 件（予定表 18 ＋ 夜間以外 3）で、その 3 つが想定どおり
# (b) 試し実行の一覧が想定どおり（含む・除く・入力値）。想定を直書きしているのは、定義が動いたときに気づくため
# (c) 判定の論理を、偽の gh が返す固定の JSON で確かめる:
#     完了 / 成功なし / 旧い Mac だけ / 曜日限定 / job の全ページ・runner_name が空 / 共有ワークフローは 1 晩で数える
# (d) 読み先が origin/main であること（作業ツリーの汚れに影響されない）と、複製・fetch・workflows の欠けの名指しの失敗
# (e) 権限の省略は試し実行にしない（分類の fail-safe）
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
passed=0 failed=0
log() { echo "==> $*"; }
ok() { log "OK   $1"; passed=$((passed + 1)); }
ng() { log "FAIL $1"; failed=$((failed + 1)); }
expect_eq() { # expect_eq <名前> <期待> <実際>
  if [ "$2" = "$3" ]; then ok "$1"; else ng "$1（期待 $2 / 実際 $3）"; fi
}
expect_line() { # expect_line <名前> <出力ファイル> <正規表現>
  if grep -Eq -- "$3" "$2"; then ok "$1"; else ng "$1（'$3' に合う行が無い）"; sed 's/^/    | /' "$2"; fi
}

# ---------------------------------------------------------------------------
# (a) 今の GitHub の main から作った一覧
# ---------------------------------------------------------------------------
log "(a) 完了の一覧の導出（この端末の複製を fetch した origin/main）"
# shellcheck source=cutover-lib.sh disable=SC1091
. scripts/cutover-lib.sh
cutover_init
real_units="$(cutover_units)"
expect_eq "完了の一覧は 確認対象 21 件" 21 "$(jq 'length' <<<"${real_units}")"
expect_eq "予定表の仕事は 18" 18 "$(jq '[.[] | select(.kind == "plan")] | length' <<<"${real_units}")"
expect_eq "予定表に無い 3 本は digest-check・note-check・watchlist-check" \
  "digest-check.yaml note-check.yaml watchlist-check.yaml" \
  "$(jq -r '[.[] | select(.kind == "extra") | .workflow] | sort | join(" ")' <<<"${real_units}")"
expect_eq "turnover-snapshot は 3 件（共有）" 3 "$(jq '[.[] | select(.workflow == "turnover-snapshot.yaml")] | length' <<<"${real_units}")"
expect_eq "daily-mediable-sync は 2 件（共有）" 2 "$(jq '[.[] | select(.workflow == "daily-mediable-sync.yaml")] | length' <<<"${real_units}")"
expect_eq "仕事の ID は省略時にワークフロー名" "nikkei-eps-sync.yaml" \
  "$(jq -r '.[] | select(.workflow == "nikkei-eps-sync.yaml") | .id' <<<"${real_units}")"
expect_eq "曜日限定の確認対象は 8 つ（火〜土が 5・火が 2・土が 1）" 8 "$(jq '[.[] | select(.days | length > 0)] | length' <<<"${real_units}")"

# ---------------------------------------------------------------------------
# (b) 試し実行の一覧
# ---------------------------------------------------------------------------
log "(b) 試し実行の一覧"
bash scripts/cutover-trial.sh >"${tmp}/trial.out"
trial_part="$(sed -n '/^==> 試し実行/,/^==> 夜間/p' "${tmp}/trial.out")"
night_part="$(sed -n '/^==> 夜間/,$p' "${tmp}/trial.out")"
expect_eq "試し実行は 11 本" 11 "$(grep -c '^gh workflow run ' <<<"${trial_part}")"
expect_eq "夜間で確かめるのは 7 本" 7 "$(grep -c '^- ' <<<"${night_part}")"
expected_trial=(
  "nikkei-eps-sync.yaml -R krtsato/mcp-tradingview -f dry_run=true"
  "seido-margin-sync.yaml -R krtsato/mcp-tradingview -f dry_run=true"
  "market-ratio-sync.yaml -R krtsato/mcp-tradingview -f dry_run=true"
  "short-pressure-sync.yaml -R krtsato/mcp-tradingview -f dry_run=true"
  "short-selling-sync.yaml -R krtsato/mcp-tradingview -f dry_run=true"
  "turnover-snapshot.yaml -R krtsato/mcp-tradingview -f dry_run=true"
  "watchlist-sync.yaml -R krtsato/mcp-invest-knowledge -f dry_run=true"
  "daily-alpha-picks-sync.yaml -R krtsato/mcp-seeking-alpha -f dry_run=true -f skip_audio=true -f audio_dry_run=true -f sync_limit=1"
  "digest-check.yaml -R krtsato/mcp-invest-knowledge"
  "note-check.yaml -R krtsato/mcp-invest-knowledge"
  "watchlist-check.yaml -R krtsato/mcp-invest-knowledge"
)
for e in "${expected_trial[@]}"; do
  if grep -Fq -- "gh workflow run ${e}   #" <<<"${trial_part}"; then ok "試し実行に ${e%% *}"; else ng "試し実行に ${e%% *} が無い・入力が違う"; fi
done
for w in digest-author ledger-sync undigested-captions digest-corpus-audit note-author daily-magazine-sync daily-mediable-sync; do
  if grep -Fq -- "/${w}.yaml:" <<<"${night_part}" && ! grep -Fq -- "gh workflow run ${w}.yaml" <<<"${trial_part}"; then
    ok "${w} は夜間の実行で確かめる側（試し実行に無い）"
  else
    ng "${w} の振り分けが想定と違う"
  fi
done
# 副作用の安全側: 試し実行の全行が dry_run=true か、読み取りだけの検査
bad="$(grep '^gh workflow run ' <<<"${trial_part}" | grep -v -e 'dry_run=true' -e '-check.yaml' || true)"
expect_eq "dry_run でも検査でもない試し実行は 0" "" "${bad}"

# ---------------------------------------------------------------------------
# 一時の git リポジトリ（origin つき）を作る道具
# ---------------------------------------------------------------------------
fx="${tmp}/fx"
mkdir -p "${fx}/root" "${fx}/origin" "${fx}/bin" "${fx}/data"
git_q() { git -c commit.gpgsign=false -c user.email=t@example.test -c user.name=t "$@"; }
mkrepo() { # mkrepo <名前>。作業ツリー ${fx}/root/<名前> と、その origin（bare）を作る。まだ commit しない
  git init -q -b main "${fx}/root/$1"
  git init -q --bare -b main "${fx}/origin/$1.git"
  git -C "${fx}/root/$1" remote add origin "${fx}/origin/$1.git"
}
publish() { # publish <名前>。全部 commit して origin/main へ push
  git_q -C "${fx}/root/$1" add -A
  git_q -C "${fx}/root/$1" commit -q --allow-empty -m fixture
  git_q -C "${fx}/root/$1" push -q origin main
}
wf() { # wf <リポジトリ> <名前> <runs-on> [permissions の行（そのまま）]
  mkdir -p "${fx}/root/$1/.github/workflows"
  printf 'on:\n  workflow_dispatch:\n%sjobs:\n  j:\n    runs-on: %s\n    steps: []\n' "${4:+${4}$'\n'}" "$3" >"${fx}/root/$1/.github/workflows/$2.yaml"
}

mkrepo mcp-a
mkrepo watcher
mkdir -p "${fx}/root/watcher/cmd/nightly-launcher"
cat >"${fx}/root/watcher/cmd/nightly-launcher/plan.json" <<'JSON'
{"slots":[{"name":"A","at":"01:30","deadline":"06:25","jobs":[
  {"repo":"krtsato/mcp-a","workflow":"once.yaml"},
  {"repo":"krtsato/mcp-a","workflow":"tue.yaml","days":["tue"]},
  {"repo":"krtsato/mcp-a","workflow":"shared.yaml","id":"x"},
  {"repo":"krtsato/mcp-a","workflow":"shared.yaml","id":"y"}]}]}
JSON
for w in once tue shared extra; do wf mcp-a "${w}" "[self-hosted, macOS, label]"; done
# 自前の runner を使わないワークフローは一覧に入らない
wf mcp-a hosted ubuntu-latest
publish mcp-a
publish watcher

# ---------------------------------------------------------------------------
# (c) 判定の論理（偽の gh と固定の JSON）
# ---------------------------------------------------------------------------
log "(c) 判定の論理"
# 偽の gh: 読む（api の GET）だけ。それ以外は失敗にして、書き込みが紛れ込んだら気づく。
# --paginate では、固定ファイルに入っている複数のページ（JSON が複数）を 1 ページずつ --jq に通す（本物と同じ）
cat >"${fx}/bin/gh" <<'EOF'
#!/bin/bash
d="${FAKE_GH_DATA:?}"
echo "$*" >>"${d}/calls.log"
[ "$1" = api ] || { echo "fake gh: api 以外は呼べない: $*" >&2; exit 9; }
shift
path="" expr="." paginate=0
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) paginate=1 ;;
    --jq) expr="$2"; shift ;;
    -X | --method | -f | -F | --input) echo "fake gh: 書き込みの引数: $1" >&2; exit 9 ;;
    *) path="$1" ;;
  esac
  shift
done
case "${path}" in
  repos/krtsato/mcp-a/actions/workflows/*/runs\?*)
    w="${path#repos/krtsato/mcp-a/actions/workflows/}"; w="${w%%/*}"
    f="${d}/runs-${w}.json"; [ -f "${f}" ] || f="${d}/runs-empty.json" ;;
  repos/krtsato/mcp-a/actions/runs/*/jobs\?*)
    id="${path#repos/krtsato/mcp-a/actions/runs/}"; id="${id%%/*}"
    f="${d}/jobs-${id}.json"
    [ "${paginate}" = 1 ] || { echo "fake gh: jobs は --paginate で読むこと" >&2; exit 9; } ;;
  *) echo "fake gh: 想定外の問い合わせ: ${path}" >&2; exit 9 ;;
esac
jq -rc "${expr}" "${f}"
EOF
chmod +x "${fx}/bin/gh"
echo '{"workflow_runs":[]}' >"${fx}/data/runs-empty.json"
# 偽物が本当に先に見つかるかを確かめる。外れたら本物の gh が GitHub へ問い合わせるので、何も流さずに止める
got="$(PATH="${fx}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" command -v gh)"
if [ "${got}" != "${fx}/bin/gh" ]; then
  echo "==> 中止: gh が偽物でなく ${got} に解決される" >&2
  exit 1
fi

# run と job の固定データ。runner 名の NULL は runner_name が null の job
mkrun() { # mkrun <wf> <id> <created_at> <conclusion> <runner 名>...（job は 1 ページ）
  local w="$1" id="$2" at="$3" c="$4"; shift 4
  local f="${fx}/data/runs-${w}.json"
  [ -f "${f}" ] || echo '{"workflow_runs":[]}' >"${f}"
  jq --argjson id "${id}" --arg at "${at}" --arg c "${c}" \
    '.workflow_runs += [{id: $id, created_at: $at, conclusion: $c, html_url: ("https://example.test/run/" + ($id | tostring))}]' "${f}" >"${f}.n" && mv "${f}.n" "${f}"
  jq -n '$ARGS.positional | {jobs: map({runner_name: (if . == "NULL" then null else . end)})}' --args "$@" >"${fx}/data/jobs-${id}.json"
}
addpage() { # addpage <id> <runner 名>... 。job の 2 ページ目を足す
  local id="$1"; shift
  jq -n '$ARGS.positional | {jobs: map({runner_name: .})}' --args "$@" >>"${fx}/data/jobs-${id}.json"
}
reset_data() { rm -f "${fx}/data/runs-"*.json "${fx}/data/jobs-"*.json "${fx}/data/calls.log"; echo '{"workflow_runs":[]}' >"${fx}/data/runs-empty.json"; }
# 日本時間の月曜 01:30 = 前日 16:30Z。火曜 01:30 = 月曜 16:30Z。2026-10-12 は月曜
MON="2026-10-11T16:30:00Z"
MON2="2026-10-11T16:40:00Z"
TUE="2026-10-12T16:30:00Z"
MON_NOW="2026-10-12T12:00:00Z"   # 月曜 21:00（火曜の枠はまだ来ていない）
WED_NOW="2026-10-14T12:00:00Z"   # 水曜 21:00

run_check() { # run_check <出力ファイル> <いま> <RUNNERS>。終了コードを rc に入れる
  rc=0
  PATH="${fx}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" FAKE_GH_DATA="${fx}/data" \
    REPOS_ROOT="${fx}/root" RUNNER_REPOS="mcp-a" CUTOVER_NOW="$2" \
    bash scripts/cutover-check.sh 2026-10-12 "$3" >"$1" 2>&1 || rc=$?
}

log "(c0) 何も無い"
reset_data
run_check "${tmp}/c0.out" "${MON_NOW}" "new-1,new-2"
expect_eq "一覧は 5 件（予定表 4 ＋ 夜間以外 1。runner を使わないものは入らない）" "合計 5" "$(grep -o '合計 [0-9]*' "${tmp}/c0.out")"
expect_eq "何も無ければ終了コード 1" 1 "${rc}"
expect_line "成功なし: pending" "${tmp}/c0.out" '^pending +A mcp-a once.yaml +SINCE 以降の成功なし'

log "(c1) 完了・旧い Mac だけ・曜日未到来・共有の 1 回だけ（月曜の夜）"
reset_data
mkrun once.yaml 101 "${MON}" success new-1
mkrun extra.yaml 102 "${MON}" success old-1
mkrun shared.yaml 103 "${MON}" success new-2
run_check "${tmp}/c1.out" "${MON_NOW}" "new-1,new-2"
expect_line "新しい Mac の成功 → done と run の URL" "${tmp}/c1.out" '^done +A mcp-a once.yaml +https://example.test/run/101'
expect_line "旧い Mac だけの成功 → pending" "${tmp}/c1.out" '^pending +- mcp-a extra.yaml +成功は 1 回あるが、新しい Mac の runner ではない'
expect_line "曜日限定・まだ来ていない → pending と次の日" "${tmp}/c1.out" '^pending +A mcp-a tue.yaml +対象の曜日（tue）がまだ来ていない（次: 2026-10-13）'
expect_line "共有: 1 晩に 1 回だけ → x も pending" "${tmp}/c1.out" '^pending +A mcp-a shared.yaml #x +共有 1/2 +1 晩に必要な成功がそろっていない'
expect_line "共有: 1 晩に 1 回だけ → y も pending" "${tmp}/c1.out" '^pending +A mcp-a shared.yaml #y +共有 1/2 '
expect_eq "pending があれば終了コード 1" 1 "${rc}"
expect_line "集計" "${tmp}/c1.out" 'done 1 / pending 4 / 合計 5'

log "(c2) 曜日が合わない成功は数えない（水曜の夜）"
reset_data
mkrun tue.yaml 201 "${MON}" success new-1
run_check "${tmp}/c2.out" "${WED_NOW}" "new-1,new-2"
expect_line "月曜の成功では火曜限定の確認対象は pending" "${tmp}/c2.out" '^pending +A mcp-a tue.yaml +新しい Mac の成功は 1 回あるが、対象の曜日（tue）のものが無い'

log "(c3) 曜日が合う成功と、共有が同じ晩に 2 回成功（水曜の夜）"
reset_data
mkrun once.yaml 301 "${MON}" success new-1
mkrun tue.yaml 302 "${TUE}" success new-2
mkrun extra.yaml 303 "${TUE}" success new-1
mkrun shared.yaml 304 "${MON}" success new-1
mkrun shared.yaml 305 "${MON2}" success new-2
run_check "${tmp}/c3.out" "${WED_NOW}" "new-1,new-2"
expect_line "火曜の成功 → tue は done" "${tmp}/c3.out" '^done +A mcp-a tue.yaml +https://example.test/run/302'
expect_line "共有: 同じ晩に 2 回 → x は done" "${tmp}/c3.out" '^done +A mcp-a shared.yaml #x +共有 2/2 +https://example.test/run/304'
expect_line "共有: 同じ晩に 2 回 → y も done" "${tmp}/c3.out" '^done +A mcp-a shared.yaml #y +共有 2/2 +https://example.test/run/305'
expect_line "集計は全部 done" "${tmp}/c3.out" 'done 5 / pending 0 / 合計 5'
expect_eq "全部 done なら終了コード 0" 0 "${rc}"

log "(c4) 共有: 成功 2 回でも別々の晩なら数えない"
reset_data
mkrun shared.yaml 401 "${MON}" success new-1
mkrun shared.yaml 402 "${TUE}" success new-2
run_check "${tmp}/c4.out" "${WED_NOW}" "new-1,new-2"
expect_line "別々の晩 → x は pending" "${tmp}/c4.out" '^pending +A mcp-a shared.yaml #x +共有 1/2 +1 晩に必要な成功がそろっていない'
expect_line "別々の晩 → y は pending" "${tmp}/c4.out" '^pending +A mcp-a shared.yaml #y +共有 1/2 '

log "(c5) 共有: 同じ晩に成功 2 回＋失敗 1 回は数えない"
reset_data
mkrun shared.yaml 501 "${MON}" success new-1
mkrun shared.yaml 502 "${MON2}" success new-2
mkrun shared.yaml 503 "2026-10-11T16:50:00Z" failure new-1
run_check "${tmp}/c5.out" "${WED_NOW}" "new-1,new-2"
expect_line "失敗を挟んだ晩 → x は pending と理由" "${tmp}/c5.out" '^pending +A mcp-a shared.yaml #x +共有 0/2 +2026-10-12 の夜の窓に新しい Mac での成功以外の run（失敗・実行中・旧い Mac など）があるため数えない'
expect_line "失敗を挟んだ晩 → y も pending" "${tmp}/c5.out" '^pending +A mcp-a shared.yaml #y '

log "(c5b) 共有: 同じ晩に成功 2 回＋実行中 1 回は数えない"
reset_data
mkrun shared.yaml 511 "${MON}" success new-1
mkrun shared.yaml 512 "${MON2}" success new-2
mkrun shared.yaml 513 "2026-10-11T16:50:00Z" null new-1
run_check "${tmp}/c5b.out" "${WED_NOW}" "new-1,new-2"
expect_line "実行中を挟んだ晩 → x は pending" "${tmp}/c5b.out" '^pending +A mcp-a shared.yaml #x '

log "(c5c) 共有: 同じ晩に新しい Mac で成功 2 回＋旧い Mac で成功 1 回は数えない"
reset_data
mkrun shared.yaml 521 "${MON}" success new-1
mkrun shared.yaml 522 "${MON2}" success new-2
mkrun shared.yaml 523 "2026-10-11T16:50:00Z" success old-1
run_check "${tmp}/c5c.out" "${WED_NOW}" "new-1,new-2"
expect_line "旧い Mac の成功を挟んだ晩 → x は pending" "${tmp}/c5c.out" '^pending +A mcp-a shared.yaml #x '

log "(c6) job の runner_name が空・旧い Mac が混ざった run は数えない"
reset_data
mkrun once.yaml 601 "${MON}" success new-1 NULL
mkrun extra.yaml 602 "${MON}" success new-1 old-1
mkrun tue.yaml 603 "${TUE}" success
run_check "${tmp}/c6.out" "${WED_NOW}" "new-1,new-2"
expect_line "runner_name が null の job を含む run は pending" "${tmp}/c6.out" '^pending +A mcp-a once.yaml +成功は 1 回あるが、新しい Mac の runner ではない'
expect_line "新旧が混ざった run は pending" "${tmp}/c6.out" '^pending +- mcp-a extra.yaml +成功は 1 回あるが、新しい Mac の runner ではない'
expect_line "job が 1 つも無い run は pending" "${tmp}/c6.out" '^pending +A mcp-a tue.yaml +成功は 1 回あるが、新しい Mac の runner ではない'

log "(c7) job が 2 ページにまたがる（2 ページ目に旧い Mac）"
reset_data
mkrun once.yaml 701 "${MON}" success new-1 new-2
addpage 701 old-1
mkrun extra.yaml 702 "${MON}" success new-1
addpage 702 new-2
run_check "${tmp}/c7.out" "${WED_NOW}" "new-1,new-2"
expect_line "2 ページ目の旧い Mac の job で数えない" "${tmp}/c7.out" '^pending +A mcp-a once.yaml +成功は 1 回あるが、新しい Mac の runner ではない'
expect_line "2 ページとも新しい Mac なら done" "${tmp}/c7.out" '^done +- mcp-a extra.yaml +https://example.test/run/702'

log "(c8) 名前の末尾で指定できる"
reset_data
mkrun extra.yaml 801 "${MON}" success some-host-mac
run_check "${tmp}/c8.out" "${WED_NOW}" "mac"
expect_line "末尾 mac で some-host-mac に一致 → done" "${tmp}/c8.out" '^done +- mcp-a extra.yaml'

# 読むだけであること: 偽の gh はすべて api の GET で呼ばれた（それ以外は偽物が拒否して失敗する）
expect_eq "偽の gh への問い合わせに api 以外は無い" 0 "$(grep -vc '^api ' "${fx}/data/calls.log" || true)"

# ---------------------------------------------------------------------------
# (d) 読み先は origin/main。複製・fetch・workflows の欠けは名指しで失敗
# ---------------------------------------------------------------------------
log "(d) origin/main を読む・欠けは名指しで失敗"
ctl() { REPOS_ROOT="${fx}/root" RUNNER_REPOS="${RR:-mcp-a}" bash scripts/cutover-trial.sh 2>&1; }
# 作業ツリーを汚す（未 commit のワークフローを足す・既存を runner なしに書き換える）。origin/main は変わらない
wf mcp-a dirty "[self-hosted]"
wf mcp-a once ubuntu-latest
before="$(ctl | grep -c 'gh workflow run\|^- ')"
after_units="$(REPOS_ROOT="${fx}/root" RUNNER_REPOS=mcp-a bash -c '. scripts/cutover-lib.sh; cutover_init; cutover_units | jq length')"
expect_eq "作業ツリーの汚れは読まない（一覧は origin/main のまま 5 件）" 5 "${after_units}"
expect_eq "試し実行の一覧も origin/main のまま（runner のワークフロー 4 本。汚れた dirty は入らない）" 4 "${before}"
git -C "${fx}/root/mcp-a" checkout -q -- . && git -C "${fx}/root/mcp-a" clean -fdq

out="$(RR='mcp-a mcp-missing' ctl || true)"
if grep -Fq "複製がありません: mcp-missing" <<<"${out}"; then ok "複製が無い → 名指しで失敗"; else ng "複製が無いときの失敗が名指しでない: ${out}"; fi

mkdir -p "${fx}/root/not-git"
out="$(RR='mcp-a not-git' ctl || true)"
if grep -Fq "git の複製ではありません: not-git" <<<"${out}"; then ok "git の複製でない → 名指しで失敗"; else ng "git でない複製の失敗が名指しでない: ${out}"; fi

mkrepo nowf
publish nowf
out="$(RR='mcp-a nowf' ctl || true)"
if grep -Fq "origin/main に .github/workflows のワークフローがありません: nowf" <<<"${out}"; then ok "workflows が無い → 名指しで失敗"; else ng "workflows 欠けの失敗が名指しでない: ${out}"; fi

mkrepo nofetch
publish nofetch
git -C "${fx}/root/nofetch" remote set-url origin "${fx}/origin/does-not-exist.git"
out="$(RR='mcp-a nofetch' ctl || true)"
if grep -Fq "git fetch origin main に失敗しました: nofetch" <<<"${out}"; then ok "fetch 失敗 → 名指しで失敗"; else ng "fetch 失敗が名指しでない: ${out}"; fi

# ---------------------------------------------------------------------------
# (e) 権限の省略は試し実行にしない
# ---------------------------------------------------------------------------
log "(e) 権限の分類（fail-safe）"
mkrepo mcp-t
wf mcp-t perm-none "[self-hosted]"                                              # 権限の宣言なし
wf mcp-t perm-read "[self-hosted]" $'permissions:\n  contents: read'            # 全体で read だけ
wf mcp-t perm-write "[self-hosted]" $'permissions:\n  contents: read\n  issues: write' # 書き込みあり
# job 単位の宣言: 全体の宣言が無く、job が read だけ
mkdir -p "${fx}/root/mcp-t/.github/workflows"
printf 'on:\n  workflow_dispatch:\njobs:\n  j:\n    runs-on: [self-hosted]\n    permissions:\n      contents: read\n    steps: []\n' >"${fx}/root/mcp-t/.github/workflows/perm-job.yaml"
# 全体は read でも、job が書き込みを宣言している
printf 'on:\n  workflow_dispatch:\npermissions:\n  contents: read\njobs:\n  j:\n    runs-on: [self-hosted]\n    permissions:\n      pull-requests: write\n    steps: []\n' >"${fx}/root/mcp-t/.github/workflows/perm-jobwrite.yaml"
publish mcp-t
out="$(RR=mcp-t ctl)"
for w in perm-read perm-job; do
  if grep -Fq "gh workflow run ${w}.yaml -R krtsato/mcp-t   #" <<<"${out}"; then ok "${w}: 明示的な読み取りだけ → 試し実行"; else ng "${w} が試し実行に無い"; fi
done
for w in perm-none perm-write perm-jobwrite; do
  if grep -Fq "/${w}.yaml:" <<<"${out}" && ! grep -Fq "gh workflow run ${w}.yaml" <<<"${out}"; then ok "${w}: 権限の省略・書き込み → 夜間側"; else ng "${w} の振り分けが想定と違う"; fi
done

log "${passed} 件成功 / ${failed} 件失敗"
[ "${failed}" -eq 0 ]
