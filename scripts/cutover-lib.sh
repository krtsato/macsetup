#!/usr/bin/env bash
# 切り替え（段 6）の 2 つの道具（cutover-trial.sh・cutover-check.sh）が共有する読み取り専用の部品。
# source して使う。何も書かず、GitHub にも触れない（GitHub への問い合わせは cutover-check.sh 側）。
#
# 入力の正本:
#   - 起動役の予定表: $WATCHER_PLAN（既定 $REPOS_ROOT/watcher/cmd/nightly-launcher/plan.json）
#   - 自前の実行役を使うワークフロー: 実行役を置くリポジトリ（roles/runners/defaults の runners_list）の
#     $REPOS_ROOT/<repo>/.github/workflows/*.y*ml のうち、runs-on に self-hosted を含むもの
# 一覧はここに書かず、実行時に読む（書くと予定表やワークフローを変えたとき黙ってずれる）。
#
# 差し替え用の環境変数（テスト用）: REPOS_ROOT・WATCHER_PLAN・RUNNER_REPOS（空白区切り）・CUTOVER_OWNER

CUTOVER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUTOVER_REPO_DIR="$(cd "${CUTOVER_LIB_DIR}/.." && pwd)"

cutover_init() {
  REPOS_ROOT="${REPOS_ROOT:-${HOME}/dev/me}"
  WATCHER_PLAN="${WATCHER_PLAN:-${REPOS_ROOT}/watcher/cmd/nightly-launcher/plan.json}"
  CUTOVER_OWNER="${CUTOVER_OWNER:-krtsato}"
  if [ -z "${RUNNER_REPOS:-}" ]; then
    RUNNER_REPOS="$(cutover_runner_repos)"
  fi
  [ -n "${RUNNER_REPOS}" ] || { echo "実行役を置くリポジトリの一覧が読めません" >&2; return 1; }
  # 定義は複製の作業ツリーから読む。main 以外に居ると、実際に動く定義と違うものを読む
  local repo branch
  for repo in ${RUNNER_REPOS}; do
    branch="$(git -C "${REPOS_ROOT}/${repo}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ -n "${branch}" ] && [ "${branch}" != main ]; then
      echo "警告: ${repo} の複製が main ではなく ${branch} です。ワークフローの定義が実際と違うかもしれません" >&2
    fi
  done
  [ -f "${WATCHER_PLAN}" ] || { echo "起動役の予定表が読めません: ${WATCHER_PLAN}" >&2; return 1; }
}

# 実行役を置くリポジトリ名（roles/runners/defaults の runners_list。重複なし）
cutover_runner_repos() {
  /usr/bin/ruby -ryaml -e '
    list = YAML.safe_load(File.read(ARGV[0]))["runners_list"] || []
    puts list.map { |r| r["repo"] }.uniq
  ' "${CUTOVER_REPO_DIR}/ansible/roles/runners/defaults/main.yaml"
}

# 実行役を使うワークフローごとの事実を JSON 配列で出す。
# 各要素: {repo, file, dispatch, inputs:{名前:{type,default}}, writes:[書き込み権限の名前]}
cutover_workflow_facts() {
  local repo f list=""
  for repo in ${RUNNER_REPOS}; do
    for f in "${REPOS_ROOT}/${repo}/.github/workflows/"*.yaml "${REPOS_ROOT}/${repo}/.github/workflows/"*.yml; do
      [ -f "${f}" ] || continue
      list="${list}${repo}|${f}"$'\n'
    done
  done
  printf '%s' "${list}" | /usr/bin/ruby -ryaml -rjson -e '
    out = []
    STDIN.each_line do |line|
      repo, path = line.chomp.split("|", 2)
      next if repo.nil? || path.nil?
      doc = YAML.safe_load(File.read(path)) || {}
      jobs = doc["jobs"].is_a?(Hash) ? doc["jobs"].values : []
      next unless jobs.any? { |j| j.is_a?(Hash) && j["runs-on"].to_s.include?("self-hosted") }
      on = doc["on"].nil? ? doc[true] : doc["on"]   # YAML 1.1 では on: が true になる
      dispatch = on.is_a?(Hash) && on.key?("workflow_dispatch")
      raw = dispatch && on["workflow_dispatch"].is_a?(Hash) ? (on["workflow_dispatch"]["inputs"] || {}) : {}
      inputs = {}
      raw.each { |k, v| inputs[k] = { "type" => (v || {})["type"], "default" => (v || {})["default"] } }
      perms = [doc["permissions"]] + jobs.map { |j| j.is_a?(Hash) ? j["permissions"] : nil }
      writes = []
      perms.compact.each do |p|
        if p.is_a?(Hash)
          p.each { |k, v| writes << k if v.to_s == "write" }
        elsif p.to_s =~ /write/
          writes << p.to_s
        end
      end
      out << { "repo" => repo, "file" => File.basename(path), "dispatch" => dispatch,
               "inputs" => inputs, "writes" => writes.uniq.sort }
    end
    puts JSON.generate(out.sort_by { |w| [w["repo"], w["file"]] })
  '
}

# 完了の一覧。起動役の予定表の仕事（slot・リポジトリ・ワークフロー・仕事の ID・入力・曜日・枠の時刻）
# ＋ 予定表に無い自前実行のワークフロー。ID は予定表と同じく省略時にワークフロー名（Job.IDOf）。
# 各要素: {kind, slot, at, repo, workflow, id, inputs, days}。repo は owner/name。
cutover_units() {
  local facts plan
  facts="$(cutover_workflow_facts)"
  plan="$(cat "${WATCHER_PLAN}")"
  jq -n --argjson facts "${facts}" --argjson plan "${plan}" --arg owner "${CUTOVER_OWNER}" '
    [ $plan.slots[] as $s | $s.jobs[]
      | { kind: "plan", slot: $s.name, at: $s.at, repo: .repo, workflow: .workflow,
          id: (.id // .workflow), inputs: (.inputs // {}), days: ((.days // []) | map(ascii_downcase)) } ] as $jobs
    | ($jobs | map(.repo + "/" + .workflow)) as $inplan
    | $jobs + [ $facts[] | ($owner + "/" + .repo) as $r | select(($r + "/" + .file) as $k | $inplan | index($k) | not)
        | { kind: "extra", slot: "-", at: "00:00", repo: $r, workflow: .file, id: .file, inputs: {}, days: [] } ]'
}
