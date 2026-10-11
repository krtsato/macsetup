#!/usr/bin/env bash
# 切り替え（段 6）の 2 つの道具（cutover-trial.sh・cutover-check.sh）が共有する読み取り専用の部品。
# source して使う。何も書かない。ネットワークは各複製の `git fetch origin main`（読むだけ）だけ。
#
# 入力の正本は **GitHub の main**（手元の作業ツリーではない。作業ツリーが別の branch や未 commit でも読み違えない）:
#   - 起動役の予定表: watcher の複製の origin/main の cmd/nightly-launcher/plan.json
#   - 自前の実行役を使うワークフロー: 実行役を置くリポジトリ（roles/runners/defaults の runners_list）の複製の
#     origin/main の .github/workflows/*.y*ml のうち、runs-on に self-hosted を含むもの
# 必要な複製（実行役 5 本 + watcher）が無い・git の複製でない・fetch できない・origin/main に
# .github/workflows が無い、のどれでも、名指しで失敗する（黙って飛ばさない）。
# 一覧はここに書かず、実行時に読む（書くと予定表やワークフローを変えたとき黙ってずれる）。
#
# 差し替え用の環境変数（テスト用）: REPOS_ROOT・RUNNER_REPOS（空白区切り）・CUTOVER_OWNER

CUTOVER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUTOVER_REPO_DIR="$(cd "${CUTOVER_LIB_DIR}/.." && pwd)"
CUTOVER_PLAN_PATH="cmd/nightly-launcher/plan.json"

cutover_die() { echo "エラー: $*" >&2; return 1; }

cutover_init() {
  REPOS_ROOT="${REPOS_ROOT:-${HOME}/dev/me}"
  CUTOVER_OWNER="${CUTOVER_OWNER:-krtsato}"
  if [ -z "${RUNNER_REPOS:-}" ]; then
    RUNNER_REPOS="$(cutover_runner_repos)"
  fi
  [ -n "${RUNNER_REPOS}" ] || { cutover_die "実行役を置くリポジトリの一覧が読めません"; return 1; }
  local repo dir
  for repo in ${RUNNER_REPOS} watcher; do
    dir="${REPOS_ROOT}/${repo}"
    [ -d "${dir}" ] || { cutover_die "複製がありません: ${repo}（${dir}）。make playbook の repos 役割で複製してください"; return 1; }
    git -C "${dir}" rev-parse --git-dir >/dev/null 2>&1 || { cutover_die "git の複製ではありません: ${repo}（${dir}）"; return 1; }
    git -C "${dir}" fetch --quiet origin main 2>/dev/null || { cutover_die "git fetch origin main に失敗しました: ${repo}"; return 1; }
    git -C "${dir}" rev-parse --verify --quiet 'origin/main^{commit}' >/dev/null || { cutover_die "origin/main がありません: ${repo}"; return 1; }
  done
  CUTOVER_PLAN_JSON="$(git -C "${REPOS_ROOT}/watcher" show "origin/main:${CUTOVER_PLAN_PATH}" 2>/dev/null)" \
    || { cutover_die "watcher の origin/main に ${CUTOVER_PLAN_PATH} がありません"; return 1; }
  jq -e '.slots | length > 0' <<<"${CUTOVER_PLAN_JSON}" >/dev/null 2>&1 \
    || { cutover_die "watcher の予定表が読めません（slots が空か JSON が不正）"; return 1; }
}

# 実行役を置くリポジトリ名（roles/runners/defaults の runners_list。重複なし）
cutover_runner_repos() {
  /usr/bin/ruby -ryaml -e '
    list = YAML.safe_load(File.read(ARGV[0]))["runners_list"] || []
    puts list.map { |r| r["repo"] }.uniq
  ' "${CUTOVER_REPO_DIR}/ansible/roles/runners/defaults/main.yaml"
}

# 実行役を使うワークフローごとの事実を JSON 配列で出す（origin/main の内容から）。
# 各要素: {repo, file, dispatch, inputs:{名前:{type,default}}, writes:[書き込み権限の名前], readonly}
# readonly は「全 job の権限が明示的に read/none だけ」のときだけ真。permissions の省略は真にしない
# （省略すると既定の権限になり、書き込めることがある）。
cutover_workflow_facts() {
  local repo f tmp list="" out
  tmp="$(mktemp -d)"
  for repo in ${RUNNER_REPOS}; do
    local files
    files="$(git -C "${REPOS_ROOT}/${repo}" ls-tree --name-only origin/main .github/workflows/ 2>/dev/null | grep -E '\.ya?ml$' || true)"
    if [ -z "${files}" ]; then
      rm -rf "${tmp}"
      cutover_die "origin/main に .github/workflows のワークフローがありません: ${repo}"
      return 1
    fi
    while IFS= read -r f; do
      mkdir -p "${tmp}/${repo}"
      git -C "${REPOS_ROOT}/${repo}" show "origin/main:${f}" >"${tmp}/${repo}/$(basename "${f}")" \
        || { rm -rf "${tmp}"; cutover_die "origin/main から ${repo}/${f} を読めません"; return 1; }
      list="${list}${repo}|${tmp}/${repo}/$(basename "${f}")"$'\n'
    done <<<"${files}"
  done
  out="$(printf '%s' "${list}" | /usr/bin/ruby -ryaml -rjson -e '
    def readonly_perm?(p)
      return p.values.all? { |v| %w[read none].include?(v.to_s) } if p.is_a?(Hash)
      p.to_s == "read-all"
    end
    out = []
    STDIN.each_line do |line|
      repo, path = line.chomp.split("|", 2)
      next if repo.nil? || path.nil?
      doc = YAML.safe_load(File.read(path)) || {}
      jobs = doc["jobs"].is_a?(Hash) ? doc["jobs"].values.select { |j| j.is_a?(Hash) } : []
      next unless jobs.any? { |j| j["runs-on"].to_s.include?("self-hosted") }
      on = doc["on"].nil? ? doc[true] : doc["on"]   # YAML 1.1 では on: が true になる
      dispatch = on.is_a?(Hash) && on.key?("workflow_dispatch")
      raw = dispatch && on["workflow_dispatch"].is_a?(Hash) ? (on["workflow_dispatch"]["inputs"] || {}) : {}
      inputs = {}
      raw.each { |k, v| inputs[k] = { "type" => (v || {})["type"], "default" => (v || {})["default"] } }
      effective = jobs.map { |j| j.key?("permissions") ? j["permissions"] : doc["permissions"] }
      readonly = !jobs.empty? && effective.all? { |p| !p.nil? && readonly_perm?(p) }
      writes = []
      ([doc["permissions"]] + jobs.map { |j| j["permissions"] }).compact.each do |p|
        if p.is_a?(Hash)
          p.each { |k, v| writes << k if v.to_s == "write" }
        elsif p.to_s =~ /write/
          writes << p.to_s
        end
      end
      out << { "repo" => repo, "file" => File.basename(path), "dispatch" => dispatch,
               "inputs" => inputs, "writes" => writes.uniq.sort, "readonly" => readonly }
    end
    puts JSON.generate(out.sort_by { |w| [w["repo"], w["file"]] })
  ')"
  rm -rf "${tmp}"
  printf '%s\n' "${out}"
}

# 完了の一覧。起動役の予定表の仕事（slot・枠の時刻と締切・リポジトリ・ワークフロー・仕事の ID・入力・曜日）
# ＋ 予定表に無い自前実行のワークフロー。ID は予定表と同じく省略時にワークフロー名（Job.IDOf）。
# 各要素: {kind, slot, at, deadline, repo, workflow, id, inputs, days}。repo は owner/name。
cutover_units() {
  local facts
  facts="$(cutover_workflow_facts)" || return 1
  jq -n --argjson facts "${facts}" --argjson plan "${CUTOVER_PLAN_JSON}" --arg owner "${CUTOVER_OWNER}" '
    [ $plan.slots[] as $s | $s.jobs[]
      | { kind: "plan", slot: $s.name, at: $s.at, deadline: $s.deadline, repo: .repo, workflow: .workflow,
          id: (.id // .workflow), inputs: (.inputs // {}), days: ((.days // []) | map(ascii_downcase)) } ] as $jobs
    | ($jobs | map(.repo + "/" + .workflow)) as $inplan
    | $jobs + [ $facts[] | ($owner + "/" + .repo) as $r | select(($r + "/" + .file) as $k | $inplan | index($k) | not)
        | { kind: "extra", slot: "-", at: "00:00", deadline: "00:00", repo: $r, workflow: .file, id: .file, inputs: {}, days: [] } ]'
}
