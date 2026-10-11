#!/usr/bin/env bash
# 完了の一覧（段 6 の手順 14）の判定。**読み取り専用**（GitHub の run と job を読むだけ）。
#   使い方: cutover-check.sh <SINCE> <RUNNERS>
#     SINCE   : 数え始める日時。YYYY-MM-DD は日本時間のその日の 0 時、YYYY-MM-DDTHH:MM:SSZ はそのまま
#     RUNNERS : 新端末の実行役。カンマ区切り。各要素は名前そのもの、または名前の末尾（`mac` なら `*-mac`）
# 完了の一覧 = 起動役の予定表の仕事 ＋ 予定表に無い自前実行のワークフロー（cutover-lib.sh が作る）。
# 単位は SINCE 以降に、新端末の実行役だけで動いて成功した run が 1 回あれば「完了」。
#   - run の job がすべて新端末の実行役で動いていること（runner_name で見る）
#   - 曜日限定の単位は、その曜日（日本時間）に始まった run だけを数える。該当の曜日が来るまで未完了
#   - 同じワークフローを複数の単位が共有する場合（turnover-snapshot が 3 つ・daily-mediable-sync が 2 つ）は、
#     GitHub の run は入力も仕事の ID も持たないので見分けられない。単位の数 N だけ成功が要る
#     （成功した順に、曜日の合う単位から埋める）
# 完了していない単位が 1 つでもあれば終了コード 1。
# 試験用: CUTOVER_NOW（epoch 秒または ISO）で「いま」を差し替える。
set -euo pipefail
# shellcheck source=cutover-lib.sh disable=SC1091
. "$(dirname "$0")/cutover-lib.sh"

since_arg="${1:-${SINCE:-}}"
runners_arg="${2:-${RUNNERS:-}}"
[ -n "${since_arg}" ] || { echo "使い方: cutover-check.sh <SINCE: YYYY-MM-DD> <RUNNERS: 名前,名前 または末尾>" >&2; exit 2; }
[ -n "${runners_arg}" ] || { echo "RUNNERS を指定してください（新端末の実行役の名前、または名前の末尾）" >&2; exit 2; }

if [[ "${since_arg}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  since_iso="$(jq -rn --arg d "${since_arg}" '($d + "T00:00:00Z") | fromdate - 32400 | todate')" # JST の 0 時
elif [[ "${since_arg}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  since_iso="${since_arg}"
else
  echo "SINCE は YYYY-MM-DD か YYYY-MM-DDTHH:MM:SSZ で指定してください: ${since_arg}" >&2
  exit 2
fi
since_epoch="$(jq -rn --arg t "${since_iso}" '$t | fromdate')"
if [ -n "${CUTOVER_NOW:-}" ]; then
  now_epoch="$(jq -rn --arg t "${CUTOVER_NOW}" '$t | if test("^[0-9]+$") then tonumber else fromdate end')"
else
  now_epoch="$(date +%s)"
fi
runners_json="$(jq -cn --arg r "${runners_arg}" '$r | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')"
[ "${runners_json}" != "[]" ] || { echo "RUNNERS が空です" >&2; exit 2; }

cutover_init
units="$(cutover_units)"

# 新端末の実行役か（名前そのもの、または名前の末尾が -<指定>）
is_new_runner() { # is_new_runner <runner 名>
  jq -en --arg n "$1" --argjson rs "${runners_json}" '$rs | any(. as $r | $n == $r or ($n | endswith("-" + $r)))' >/dev/null
}

# ワークフロー（repo + 名前）ごとに、SINCE 以降に成功した run を集める。
# qualifying: すべての job が新端末の実行役で動いた run。other: 成功したが新端末ではない run の数
runs_dir="$(mktemp -d)"
trap 'rm -rf "${runs_dir}"' EXIT
groups="$(jq -r '[.[] | .repo + " " + .workflow] | unique | .[]' <<<"${units}")"
while IFS=' ' read -r repo wf; do
  [ -n "${repo}" ] || continue
  out="${runs_dir}/$(printf '%s' "${repo}/${wf}" | tr '/' '_').jsonl"
  : >"${out}"
  runs="$(gh api --paginate "repos/${repo}/actions/workflows/${wf}/runs?created=>=${since_iso}&status=success&per_page=100" \
    --jq '.workflow_runs[] | {id, created_at, html_url}' | jq -sc '.')"
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    rid="$(jq -r '.id' <<<"${run}")"
    names="$(gh api "repos/${repo}/actions/runs/${rid}/jobs?per_page=100" --jq '[.jobs[] | .runner_name // empty]')"
    ok=0
    if [ "$(jq 'length' <<<"${names}")" -gt 0 ]; then
      ok=1
      while IFS= read -r n; do
        is_new_runner "${n}" || { ok=0; break; }
      done < <(jq -r '.[]' <<<"${names}")
    fi
    jq -c --argjson ok "${ok}" '. + {on_new: ($ok == 1)}' <<<"${run}" >>"${out}"
  done < <(jq -c '.[]' <<<"${runs}")
done <<<"${groups}"

# 判定。units と、集めた run を 1 つの JSON にして jq で割り当てる
all_runs="$(for f in "${runs_dir}"/*.jsonl; do
  [ -f "${f}" ] || continue
  key="$(basename "${f}" .jsonl)"
  jq -c --arg k "${key}" '. + {key: $k}' "${f}"
done | jq -sc '.')"

table="$(jq -r --argjson runs "${all_runs}" --argjson since "${since_epoch}" --argjson now "${now_epoch}" '
  def key: (.repo + "/" + .workflow) | gsub("/"; "_");
  def jst_wd: ((fromdate + 32400) | strftime("%a") | ascii_downcase);
  def hhmm: (split(":") | (.[0] | tonumber) * 3600 + (.[1] | tonumber) * 60);
  # 単位の曜日の合う該当日が、SINCE から いま までに 1 回でも来たか（枠の時刻を過ぎたものだけ）
  def due($u):
    ($u.days) as $d
    | (((($since + 32400) / 86400) | floor) * 86400 - 32400) as $day0
    | [ range(0; ((($now - $day0) / 86400) | floor) + 2) | $day0 + . * 86400 + ($u.at | hhmm) ] as $slots
    | [ $slots[] | select(. >= $since and . <= $now) | select(((. + 32400) | strftime("%a") | ascii_downcase) as $w | $d | index($w)) ] | length > 0;
  def next_day($u):
    ($u.days) as $d
    | (((($now + 32400) / 86400) | floor) * 86400 - 32400) as $day0
    | [ range(0; 8) | $day0 + . * 86400 + ($u.at | hhmm) | select(. > $now) | select(((. + 32400) | strftime("%a") | ascii_downcase) as $w | $d | index($w)) ] | first
    | if . == null then "?" else ((. + 32400) | strftime("%Y-%m-%d")) end;
  (to_entries | map(.value + {ord: .key})) as $units
  | ($units | map(key) | unique) as $keys
  | [ $keys[] as $k
      | ($units | map(select(key == $k))) as $us
      | ($runs | map(select(.key == $k)) | sort_by(.created_at)) as $rs
      | ($rs | map(select(.on_new))) as $good
      | ($rs | map(select(.on_new | not)) | length) as $other
      # 割り当て: 成功した run を古い順に、曜日の合う未割り当ての単位（曜日限定を先に）へ
      | ($us | to_entries | sort_by([(.value.days | length == 0), .key])) as $ordered
      | ( reduce $good[] as $r ({a: {}};
            ($r.created_at | jst_wd) as $w
            | .a as $cur
            | ( [ $ordered[] | select((.value.days | length == 0) or (.value.days | index($w))) | .key | tostring | select($cur[.] | not) ] | first ) as $pick
            | if $pick == null then . else .a[$pick] = $r end) | .a) as $assign
      | $us | to_entries[]
      | . as $e
      | ($e.value) as $u
      | ($assign[($e.key | tostring)]) as $r
      | { ord: $u.ord, slot: $u.slot, repo: $u.repo, workflow: $u.workflow, id: $u.id,
          shared: (($us | length) > 1), n: ($us | length), got: ($good | length),
          status: (if $r != null then "done" else "pending" end),
          detail: (if $r != null then $r.html_url
                   elif ($u.days | length) > 0 and (due($u) | not) then "対象の曜日（\($u.days | join("・"))）がまだ来ていない（次: \(next_day($u))）"
                   elif ($good | length) > 0 then "新端末の成功は \($good | length) 回あるが、対象の曜日（\($u.days | join("・"))）のものが無い"
                   elif $other > 0 then "成功は \($other) 回あるが、新端末の実行役ではない"
                   else "SINCE 以降の成功なし" end) } ]
  | sort_by(.ord) | .[]
  | [ .status, (.slot + " " + (.repo | sub("^[^/]*/"; "")) + " " + .workflow + (if .id != .workflow then " #" + .id else "" end)),
      (if .shared then "共有 \(.got)/\(.n)  " else "" end) + .detail ] | join("\u001f")' <<<"${units}")"

echo "==> 完了の一覧（SINCE=${since_iso}、新端末の実行役=${runners_arg}）"
done_n=0
pend_n=0
printf '%-8s  %-64s  %s\n' "状態" "単位（枠 リポジトリ ワークフロー #仕事の ID）" "run / 理由"
while IFS=$'\037' read -r st label detail; do
  [ -n "${st}" ] || continue
  printf '%-8s  %-64s  %s\n' "${st}" "${label}" "${detail}"
  if [ "${st}" = "done" ]; then done_n=$((done_n + 1)); else pend_n=$((pend_n + 1)); fi
done <<<"${table}"
echo "==> done ${done_n} / pending ${pend_n} / 合計 $((done_n + pend_n))"
[ "${pend_n}" -eq 0 ]
