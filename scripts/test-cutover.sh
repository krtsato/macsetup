#!/usr/bin/env bash
# cutover-lib.sh・cutover-trial.sh・cutover-check.sh の検査。GitHub には一切触れない。
# (a) 今のファイルから作った完了の一覧が 21 単位（予定表 18 ＋ 夜間以外 3）で、その 3 つが想定どおり
# (b) 試し実行の一覧が想定どおり（含む・除く・入力値）。想定を直書きしているのは、定義が動いたときに気づくため
# (c) 判定の論理を、偽の gh が返す固定の JSON で確かめる:
#     完了 / 成功なし / 旧端末だけで成功 / 曜日限定でまだ来ていない / 曜日が合わない / 曜日が合う / 共有ワークフローの数え方
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
# (a) 今のファイルから作った一覧
# ---------------------------------------------------------------------------
log "(a) 完了の一覧の導出（この端末の実際のファイル）"
# shellcheck source=cutover-lib.sh disable=SC1091
. scripts/cutover-lib.sh
cutover_init
real_units="$(cutover_units)"
expect_eq "完了の一覧は 21 単位" 21 "$(jq 'length' <<<"${real_units}")"
expect_eq "予定表の仕事は 18" 18 "$(jq '[.[] | select(.kind == "plan")] | length' <<<"${real_units}")"
expect_eq "予定表に無い 3 本は digest-check・note-check・watchlist-check" \
  "digest-check.yaml note-check.yaml watchlist-check.yaml" \
  "$(jq -r '[.[] | select(.kind == "extra") | .workflow] | sort | join(" ")' <<<"${real_units}")"
expect_eq "turnover-snapshot は 3 単位（共有）" 3 "$(jq '[.[] | select(.workflow == "turnover-snapshot.yaml")] | length' <<<"${real_units}")"
expect_eq "daily-mediable-sync は 2 単位（共有）" 2 "$(jq '[.[] | select(.workflow == "daily-mediable-sync.yaml")] | length' <<<"${real_units}")"
expect_eq "仕事の ID は省略時にワークフロー名" "nikkei-eps-sync.yaml" \
  "$(jq -r '.[] | select(.workflow == "nikkei-eps-sync.yaml") | .id' <<<"${real_units}")"
expect_eq "曜日限定の単位は 8 つ（火〜土が 5・火が 2・土が 1）" 8 "$(jq '[.[] | select(.days | length > 0)] | length' <<<"${real_units}")"

# ---------------------------------------------------------------------------
# (b) 試し実行の一覧
# ---------------------------------------------------------------------------
log "(b) 試し実行の一覧"
bash scripts/cutover-trial.sh >"${tmp}/trial.out"
trial_part="$(sed -n '/^==> 試し実行/,/^==> 夜間/p' "${tmp}/trial.out")"
night_part="$(sed -n '/^==> 夜間/,$p' "${tmp}/trial.out")"
expect_eq "試し実行は 14 本" 14 "$(grep -c '^gh workflow run ' <<<"${trial_part}")"
expect_eq "夜間で確かめるのは 4 本" 4 "$(grep -c '^- ' <<<"${night_part}")"
expected_trial=(
  "nikkei-eps-sync.yaml -R krtsato/mcp-tradingview -f dry_run=true"
  "seido-margin-sync.yaml -R krtsato/mcp-tradingview -f dry_run=true"
  "market-ratio-sync.yaml -R krtsato/mcp-tradingview -f dry_run=true"
  "short-pressure-sync.yaml -R krtsato/mcp-tradingview -f dry_run=true"
  "short-selling-sync.yaml -R krtsato/mcp-tradingview -f dry_run=true"
  "turnover-snapshot.yaml -R krtsato/mcp-tradingview -f dry_run=true"
  "watchlist-sync.yaml -R krtsato/mcp-invest-knowledge -f dry_run=true"
  "note-author.yaml -R krtsato/mcp-invest-knowledge -f dry_run=true"
  "daily-mediable-sync.yaml -R krtsato/mcp-mediable -f dry_run=true -f count=1"
  "daily-magazine-sync.yaml -R krtsato/mcp-note -f dry_run=true -f skip_audio=true -f audio_dry_run=true"
  "daily-alpha-picks-sync.yaml -R krtsato/mcp-seeking-alpha -f dry_run=true -f skip_audio=true -f audio_dry_run=true -f sync_limit=1"
  "digest-check.yaml -R krtsato/mcp-invest-knowledge"
  "note-check.yaml -R krtsato/mcp-invest-knowledge"
  "watchlist-check.yaml -R krtsato/mcp-invest-knowledge"
)
for e in "${expected_trial[@]}"; do
  if grep -Fq -- "gh workflow run ${e}   #" <<<"${trial_part}"; then ok "試し実行に ${e%% *}"; else ng "試し実行に ${e%% *} が無い・入力が違う"; fi
done
for w in digest-author ledger-sync undigested-captions digest-corpus-audit; do
  if grep -Fq -- "/${w}.yaml:" <<<"${night_part}" && ! grep -Fq -- "gh workflow run ${w}.yaml" <<<"${trial_part}"; then
    ok "${w} は夜間の実行で確かめる側（試し実行に無い）"
  else
    ng "${w} の振り分けが想定と違う"
  fi
done
# 副作用の安全側: 試し実行の全行が dry_run=true か、書き込み権限の無い検査のみ
bad="$(grep '^gh workflow run ' <<<"${trial_part}" | grep -v -e 'dry_run=true' -e '-check.yaml' || true)"
expect_eq "dry_run でも検査でもない試し実行は 0" "" "${bad}"

# ---------------------------------------------------------------------------
# (c) 判定の論理（偽の gh と固定の JSON）
# ---------------------------------------------------------------------------
log "(c) 判定の論理"
fx="${tmp}/fx"
mkdir -p "${fx}/root/watcher/cmd/nightly-launcher" "${fx}/root/mcp-a/.github/workflows" "${fx}/bin" "${fx}/data"
cat >"${fx}/root/watcher/cmd/nightly-launcher/plan.json" <<'JSON'
{"slots":[{"name":"A","at":"01:30","deadline":"06:25","jobs":[
  {"repo":"krtsato/mcp-a","workflow":"once.yaml"},
  {"repo":"krtsato/mcp-a","workflow":"tue.yaml","days":["tue"]},
  {"repo":"krtsato/mcp-a","workflow":"shared.yaml","id":"x"},
  {"repo":"krtsato/mcp-a","workflow":"shared.yaml","id":"y"}]}]}
JSON
for w in once tue shared extra; do
  printf 'on:\n  workflow_dispatch:\njobs:\n  j:\n    runs-on: [self-hosted, macOS, label]\n    steps: []\n' >"${fx}/root/mcp-a/.github/workflows/${w}.yaml"
done
# 自前の実行役を使わないワークフローは一覧に入らない
printf 'on:\n  workflow_dispatch:\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps: []\n' >"${fx}/root/mcp-a/.github/workflows/hosted.yaml"

# 偽の gh: 読む（api の GET）だけ。それ以外は失敗にして、書き込みが紛れ込んだら気づく
cat >"${fx}/bin/gh" <<'EOF'
#!/bin/bash
d="${FAKE_GH_DATA:?}"
echo "$*" >>"${d}/calls.log"
[ "$1" = api ] || { echo "fake gh: api 以外は呼べない: $*" >&2; exit 9; }
shift
path="" expr="."
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) ;;
    --jq) expr="$2"; shift ;;
    -X | --method | -f | -F | --input) echo "fake gh: 書き込みの引数: $1" >&2; exit 9 ;;
    *) path="$1" ;;
  esac
  shift
done
case "${path}" in
  repos/krtsato/mcp-a/actions/workflows/*/runs\?*)
    wf="${path#repos/krtsato/mcp-a/actions/workflows/}"; wf="${wf%%/*}"
    f="${d}/runs-${wf}.json"; [ -f "${f}" ] || f="${d}/runs-empty.json" ;;
  repos/krtsato/mcp-a/actions/runs/*/jobs\?*)
    id="${path#repos/krtsato/mcp-a/actions/runs/}"; id="${id%%/*}"
    f="${d}/jobs-${id}.json" ;;
  *) echo "fake gh: 想定外の問い合わせ: ${path}" >&2; exit 9 ;;
esac
jq -c "${expr}" "${f}"
EOF
chmod +x "${fx}/bin/gh"
echo '{"workflow_runs":[]}' >"${fx}/data/runs-empty.json"
# 偽物が本当に先に見つかるかを確かめる。外れたら本物の gh が GitHub へ問い合わせるので、何も流さずに止める
got="$(PATH="${fx}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" command -v gh)"
if [ "${got}" != "${fx}/bin/gh" ]; then
  echo "==> 中止: gh が偽物でなく ${got} に解決される" >&2
  exit 1
fi

# run と job の固定データを作る
mkrun() { # mkrun <wf> <id> <created_at> <runner 名>... 。同じ wf の run は追記する
  local wf="$1" id="$2" at="$3"; shift 3
  local f="${fx}/data/runs-${wf}.json"
  [ -f "${f}" ] || echo '{"workflow_runs":[]}' >"${f}"
  jq --argjson id "${id}" --arg at "${at}" \
    '.workflow_runs += [{id: $id, created_at: $at, html_url: ("https://example.test/run/" + ($id | tostring))}]' "${f}" >"${f}.n" && mv "${f}.n" "${f}"
  jq -n '$ARGS.positional | {jobs: map({runner_name: .})}' --args "$@" >"${fx}/data/jobs-${id}.json"
}
reset_data() { rm -f "${fx}/data/runs-"*.json "${fx}/data/jobs-"*.json "${fx}/data/calls.log"; echo '{"workflow_runs":[]}' >"${fx}/data/runs-empty.json"; }
# 日本時間の月曜 01:30 = 前日 16:30Z。火曜 01:30 = 月曜 16:30Z。2026-10-12 は月曜
MON="2026-10-11T16:30:00Z"
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
expect_eq "一覧は 5 単位（予定表 4 ＋ 夜間以外 1。実行役を使わないものは入らない）" "合計 5" "$(grep -o '合計 [0-9]*' "${tmp}/c0.out")"
expect_eq "何も無ければ終了コード 1" 1 "${rc}"
expect_line "成功なし: pending" "${tmp}/c0.out" '^pending +A mcp-a once.yaml +SINCE 以降の成功なし'

log "(c1) 完了・旧端末だけ・曜日未到来（月曜の夜）"
reset_data
mkrun once.yaml 101 "${MON}" new-1
mkrun extra.yaml 102 "${MON}" old-1
mkrun shared.yaml 103 "${MON}" new-2
run_check "${tmp}/c1.out" "${MON_NOW}" "new-1,new-2"
expect_line "新端末の成功 → done と run の URL" "${tmp}/c1.out" '^done +A mcp-a once.yaml +https://example.test/run/101'
expect_line "旧端末だけの成功 → pending" "${tmp}/c1.out" '^pending +- mcp-a extra.yaml +成功は 1 回あるが、新端末の実行役ではない'
expect_line "曜日限定・まだ来ていない → pending と次の日" "${tmp}/c1.out" '^pending +A mcp-a tue.yaml +対象の曜日（tue）がまだ来ていない（次: 2026-10-13）'
expect_line "共有: 成功 1 回 → 先頭の x だけ done" "${tmp}/c1.out" '^done +A mcp-a shared.yaml #x +共有 1/2 +https://example.test/run/103'
expect_line "共有: 成功 1 回 → y は pending" "${tmp}/c1.out" '^pending +A mcp-a shared.yaml #y +共有 1/2 '
expect_eq "pending があれば終了コード 1" 1 "${rc}"
expect_line "集計" "${tmp}/c1.out" 'done 2 / pending 3 / 合計 5'

log "(c2) 曜日が合わない成功は数えない（水曜の夜）"
reset_data
mkrun tue.yaml 201 "${MON}" new-1
run_check "${tmp}/c2.out" "${WED_NOW}" "new-1,new-2"
expect_line "月曜の成功では火曜限定の単位は pending" "${tmp}/c2.out" '^pending +A mcp-a tue.yaml +新端末の成功は 1 回あるが、対象の曜日（tue）のものが無い'

log "(c3) 曜日が合う成功と、共有の成功が 2 回（水曜の夜）"
reset_data
mkrun once.yaml 301 "${MON}" new-1
mkrun tue.yaml 302 "${TUE}" new-2
mkrun extra.yaml 303 "${TUE}" new-1
mkrun shared.yaml 304 "${MON}" new-1
mkrun shared.yaml 305 "${TUE}" new-2
run_check "${tmp}/c3.out" "${WED_NOW}" "new-1,new-2"
expect_line "火曜の成功 → tue は done" "${tmp}/c3.out" '^done +A mcp-a tue.yaml +https://example.test/run/302'
expect_line "共有: 成功 2 回 → x も done" "${tmp}/c3.out" '^done +A mcp-a shared.yaml #x +共有 2/2'
expect_line "共有: 成功 2 回 → y も done" "${tmp}/c3.out" '^done +A mcp-a shared.yaml #y +共有 2/2'
expect_line "集計は全部 done" "${tmp}/c3.out" 'done 5 / pending 0 / 合計 5'
expect_eq "全部 done なら終了コード 0" 0 "${rc}"

log "(c4) 共有: 新端末 1 回＋旧端末 1 回は 1 回ぶんだけ数える"
reset_data
mkrun shared.yaml 401 "${MON}" new-1
mkrun shared.yaml 402 "${TUE}" old-1
run_check "${tmp}/c4.out" "${WED_NOW}" "new-1,new-2"
expect_line "x は done" "${tmp}/c4.out" '^done +A mcp-a shared.yaml #x +共有 1/2'
expect_line "y は pending" "${tmp}/c4.out" '^pending +A mcp-a shared.yaml #y +共有 1/2'

log "(c5) job が 1 つでも旧端末なら新端末の成功と数えない／名前の末尾で指定できる"
reset_data
mkrun once.yaml 501 "${MON}" new-1 old-1
mkrun extra.yaml 502 "${MON}" some-host-mac
run_check "${tmp}/c5.out" "${WED_NOW}" "mac"
expect_line "新旧が混ざった run は pending" "${tmp}/c5.out" '^pending +A mcp-a once.yaml +成功は 1 回あるが、新端末の実行役ではない'
expect_line "末尾 mac で some-host-mac に一致 → done" "${tmp}/c5.out" '^done +- mcp-a extra.yaml'

# 読むだけであること: 偽の gh はすべて api の GET で呼ばれた（それ以外は偽物が拒否して失敗する）
expect_eq "偽の gh への問い合わせに api 以外は無い" 0 "$(grep -vc '^api ' "${fx}/data/calls.log" || true)"

log "${passed} 件成功 / ${failed} 件失敗"
[ "${failed}" -eq 0 ]
