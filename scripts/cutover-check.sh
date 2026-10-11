#!/usr/bin/env bash
# 完了の一覧（段 6 の手順 14）の判定。**読み取り専用**（GitHub の run と job を読むだけ）。
#   使い方: cutover-check.sh <SINCE> <RUNNERS>
#     SINCE   : 数え始める日時。YYYY-MM-DD は日本時間のその日の 0 時、YYYY-MM-DDTHH:MM:SSZ はそのまま
#     RUNNERS : 新端末の実行役。カンマ区切り。各要素は名前そのもの、または名前の末尾（`mac` なら `*-mac`）
# 完了の一覧 = 起動役の予定表の仕事 ＋ 予定表に無い自前実行のワークフロー（cutover-lib.sh が GitHub の main から作る）。
#
# 「新端末で成功した run」= run が success で、**その全 job** が新端末の実行役で動いたもの。
# job は全ページを読み、runner_name が空（未割り当て・取り消し）・新端末でない job が 1 つでもあれば数えない。
#
# 単位の判定:
#   - 通常の単位: 新端末で成功した run が SINCE 以降に 1 回あれば完了。曜日限定の単位は、その曜日（日本時間）に
#     始まった run だけを数える（該当の曜日が来るまで未完了）
#   - 共有の単位（同じリポジトリ・ワークフローが予定表に N>1 回ある。turnover-snapshot・daily-mediable-sync）:
#     GitHub の run は入力も仕事の ID も持たず、どの run がどの単位かは見分けられない。そこで **1 晩**
#     （日本時間の同じ日付。各枠の at〜deadline の窓）に、枠ごとの単位数ぶん以上の新端末での成功があり、
#     かつ窓の中に新端末での成功以外の run（失敗・取り消し・実行中・待機中・旧端末での成功など）が無いときだけ、全単位を完了とする
#     （起動役は 1 晩に各単位を 1 回ずつ起こすので、1 晩が丸ごと成功なら各単位が成功している。
#      別々の晩の成功を足し合わせたり、失敗を挟んだ晩を数えたりはしない）
# 完了していない単位が 1 つでもあれば終了コード 1。試験用: CUTOVER_NOW（epoch 秒または ISO）で「いま」を差し替える。
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

# 新端末の実行役か（名前そのもの、または名前の末尾が -<指定>）。空の名前は一致しない
is_new_runner() { # is_new_runner <runner 名>
  jq -en --arg n "$1" --argjson rs "${runners_json}" '$n != "" and ($rs | any(. as $r | $n == $r or ($n | endswith("-" + $r))))' >/dev/null
}

# ワークフロー（repo + 名前）ごとに、SINCE 以降の run を集める（成功・失敗とも。共有の判定が失敗を見るため）。
# 成功した run だけ、全ページの job を読んで on_new（全 job が新端末）を付ける
runs_file="$(mktemp)"
trap 'rm -f "${runs_file}"' EXIT
groups="$(jq -r '[.[] | .repo + " " + .workflow] | unique | .[]' <<<"${units}")"
while IFS=' ' read -r repo wf; do
  [ -n "${repo}" ] || continue
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    on_new=false
    if [ "$(jq -r '.conclusion' <<<"${run}")" = success ]; then
      rid="$(jq -r '.id' <<<"${run}")"
      jobs_n=0
      on_new=true
      while IFS= read -r name; do
        jobs_n=$((jobs_n + 1))
        is_new_runner "${name}" || on_new=false
      done < <(gh api --paginate "repos/${repo}/actions/runs/${rid}/jobs?per_page=100" --jq '.jobs[] | (.runner_name // "")')
      [ "${jobs_n}" -gt 0 ] || on_new=false
    fi
    jq -c --arg k "${repo}/${wf}" --argjson on_new "${on_new}" '. + {key: $k, on_new: $on_new}' <<<"${run}" >>"${runs_file}"
  done < <(gh api --paginate "repos/${repo}/actions/workflows/${wf}/runs?created=>=${since_iso}&per_page=100" \
    --jq '.workflow_runs[] | {id, created_at, html_url, conclusion}')
done <<<"${groups}"

# 判定。units と集めた run を ruby に渡す（出力: 順番・状態・表示名・理由 を \037 区切り）
table="$(jq -n --argjson units "${units}" --slurpfile runs "${runs_file}" --argjson since "${since_epoch}" --argjson now "${now_epoch}" \
  '{units: $units, runs: $runs, since: $since, now: $now}' | /usr/bin/ruby -rjson -rtime -e '
  input = JSON.parse(STDIN.read)
  units = input["units"].each_with_index.map { |u, i| u.merge("ord" => i) }
  runs = input["runs"]
  since = input["since"]
  now = input["now"]
  JST = 32400
  WD = %w[sun mon tue wed thu fri sat]
  wd = ->(t) { WD[Time.at(t + JST).utc.wday] }
  hhmm = ->(s) { h, m = s.split(":").map(&:to_i); h * 3600 + m * 60 }
  ep = ->(s) { Time.iso8601(s).to_i }
  ymd = ->(t) { Time.at(t + JST).utc.strftime("%Y-%m-%d") }
  day0 = ((since + JST) / 86400) * 86400 - JST       # SINCE の日本時間の 0 時
  dates = (0..((now - day0) / 86400)).map { |i| day0 + i * 86400 }
  rows = []

  units.group_by { |u| u["repo"] + "/" + u["workflow"] }.each do |key, us|
    rs = runs.select { |r| r["key"] == key }.sort_by { |r| r["created_at"] }
    good = rs.select { |r| r["conclusion"] == "success" && r["on_new"] }
    other = rs.count { |r| r["conclusion"] == "success" && !r["on_new"] }
    if us.size == 1
      u = us[0]
      days = u["days"]
      run = good.find { |r| days.empty? || days.include?(wd.(ep.(r["created_at"]))) }
      due = days.empty? || dates.any? { |d|
        t = d + hhmm.(u["at"])
        t >= since && t <= now && days.include?(wd.(t))
      }
      detail =
        if run then run["html_url"]
        elsif !due
          nxt = (0..7).map { |i| ((now + JST) / 86400) * 86400 - JST + i * 86400 + hhmm.(u["at"]) }
                      .find { |t| t > now && days.include?(wd.(t)) }
          "対象の曜日（#{days.join("・")}）がまだ来ていない（次: #{nxt ? ymd.(nxt) : "?"}）"
        elsif !good.empty? then "新端末の成功は #{good.size} 回あるが、対象の曜日（#{days.join("・")}）のものが無い"
        elsif other > 0 then "成功は #{other} 回あるが、新端末の実行役ではない"
        else "SINCE 以降の成功なし" end
      rows << [u["ord"], run ? "done" : "pending", u, detail]
      next
    end

    # 共有: 1 晩（日本時間の同じ日付）の窓に、枠ごとの単位数ぶんの新端末での成功があり、それ以外の run が無い
    chosen = nil
    fail_date = nil
    best = [-1, nil]
    dates.each do |d|
      w = wd.(d)
      next unless us.all? { |u| u["days"].empty? || u["days"].include?(w) }
      per_slot = us.group_by { |u| u["slot"] }.map do |_slot, su|
        a = d + hhmm.(su[0]["at"])
        b = d + hhmm.(su[0]["deadline"])
        win = rs.select { |r| t = ep.(r["created_at"]); t >= a && t <= b }
        # 共有の単位は見分けられないので、窓の中に「新端末での成功」以外の run（失敗・実行中・待機中・
        # 旧端末での成功など）が 1 件でもあれば、その晩は採用しない
        [su, win.select { |r| r["conclusion"] == "success" && r["on_new"] }, win.reject { |r| r["conclusion"] == "success" && r["on_new"] }]
      end
      if per_slot.any? { |_, _, f| !f.empty? }
        fail_date ||= d
        next
      end
      k = per_slot.sum { |su, g, _| [g.size, su.size].min }
      if k == us.size
        chosen = [d, per_slot]
        break
      end
      best = [k, d] if k > best[0]
    end
    assign = {}
    if chosen
      chosen[1].each { |su, g, _| su.sort_by { |u| u["ord"] }.each_with_index { |u, i| assign[u["ord"]] = g[i]["html_url"] } }
    end
    why =
      if fail_date then "#{ymd.(fail_date)} の夜の窓に新端末での成功以外の run（失敗・実行中・旧端末など）があるため数えない"
      elsif !good.empty? then "1 晩に必要な成功がそろっていない（最多 #{[best[0], 0].max}/#{us.size}。別々の晩の成功は足さない）"
      elsif other > 0 then "成功は #{other} 回あるが、新端末の実行役ではない"
      else "SINCE 以降の成功なし" end
    us.each do |u|
      url = assign[u["ord"]]
      ok = !url.nil?
      rows << [u["ord"], ok ? "done" : "pending", u, "共有 #{ok ? us.size : [best[0], 0].max}/#{us.size}  #{ok ? url : why}"]
    end
  end

  rows.sort_by { |r| r[0] }.each do |_, st, u, detail|
    label = "#{u["slot"]} #{u["repo"].sub(/^[^\/]*\//, "")} #{u["workflow"]}#{u["id"] != u["workflow"] ? " #" + u["id"] : ""}"
    puts [st, label, detail].join("\x1f")
  end
')"

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
