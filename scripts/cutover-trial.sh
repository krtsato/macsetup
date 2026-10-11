#!/usr/bin/env bash
# 切り替えの試し実行の一覧を出す（段 6 の手順 13）。**読み取り専用で、出すだけ**。起動はしない
# （起動するかは切り替えの場で人が決める）。GitHub にも触れず、手元の複製のワークフロー定義だけを読む。
#
# 一覧はワークフローの workflow_dispatch の入力と権限から実行時に作る。
#   - dry_run の入力がある  → dry_run=true（＋存在すれば skip_audio・audio_dry_run=true、件数の入力=1）
#   - 入力が無く、書き込み権限も無い（検査のみ） → 入力なしで起動してよい
#   - それ以外 → 夜間の実行で確かめる
# 例外（dry_run を付けても副作用が残るもの）だけは下の cutover_trial_excluded に理由つきで固定する。
# 副作用が無いかは、各ワークフローの dry_run が「どの手順を止めるか」を読んで 1 本ずつ確かめた結果。
set -euo pipefail
# shellcheck source=cutover-lib.sh disable=SC1091
. "$(dirname "$0")/cutover-lib.sh"
cutover_init

# dry_run があっても副作用が残る・重すぎるもの。キーは <ファイル名>
cutover_trial_excluded='{
  "digest-author.yaml": "dry_run でも、保留になった下書きを手元の保管場所（DIGEST_DRAFT_KEEP_DIR）へ書く。LLM の使用量も消費する",
  "ledger-sync.yaml": "dry_run でも走査の本体が最後まで動く（最大 280 分・TradingView へ大量に問い合わせる）。昼に流すと過負荷になる"
}'
# 入力があれば足す安全側の値（存在する入力にだけ付ける）
cutover_trial_extras='{"skip_audio":"true","audio_dry_run":"true","count":"1","sync_limit":"1"}'

facts="$(cutover_workflow_facts)"

# 実行役を使うワークフロー 1 本ずつを分類する（extras は入力に存在するものだけ付ける）
rows="$(jq -r --argjson excl "${cutover_trial_excluded}" --argjson extras "${cutover_trial_extras}" '
  .[] as $w
  | ($w.inputs | keys) as $names
  | (if $excl[$w.file] != null then {mode: "nightly", why: $excl[$w.file]}
     elif ($w.dispatch | not) then {mode: "nightly", why: "workflow_dispatch が無く手で起動できない"}
     elif ($names | index("dry_run")) != null then
       {mode: "trial",
        args: (["dry_run=true"] + [ $extras | to_entries[] | select(.key as $k | $names | index($k)) | "\(.key)=\(.value)" ]),
        note: "dry_run で書き込み・PR・送信を止める"}
     elif ($names | length) == 0 and ($w.writes | length) == 0 then
       {mode: "trial", args: [], note: "検査のみ（書き込み権限なし）"}
     elif ($names | length) == 0 then
       {mode: "nightly", why: "入力が無く dry_run にできない。書き込み権限あり（\($w.writes | join("・"))）"}
     else {mode: "nightly", why: "dry_run の入力が無い"} end) as $c
  | [$w.repo, $w.file, $c.mode, (($c.args // []) | join(" ")), ($c.why // $c.note // "")] | join("\u001f")' <<<"${facts}")"

echo "==> 試し実行（副作用が無いもの。実行するかは人が決める。このスクリプトは出すだけ）"
n=0
while IFS=$'\037' read -r repo file mode args note; do
  [ "${mode}" = trial ] || continue
  cmd="gh workflow run ${file} -R ${CUTOVER_OWNER}/${repo}"
  for kv in ${args}; do cmd="${cmd} -f ${kv}"; done
  printf '%s   # %s\n' "${cmd}" "${note}"
  n=$((n + 1))
done <<<"${rows}"
echo "(${n} 本)"
echo
echo "==> 夜間の実行で確かめる（試し実行にできない）"
m=0
while IFS=$'\037' read -r repo file mode args note; do
  [ "${mode}" = nightly ] || continue
  printf -- '- %s/%s: %s\n' "${repo}" "${file}" "${note}"
  m=$((m + 1))
done <<<"${rows}"
echo "(${m} 本)"
