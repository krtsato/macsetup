#!/usr/bin/env bash
# repos 役割の検査。一時ディレクトリを repos_root にして、
# (a) 無ければ複製する (b) 2 回目は何もしない (c) git の複製でない場所は止める (d) origin が違えば止める
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
play="ansible/_test_repos.yaml"
trap 'rm -rf "${tmp}" "${play}"' EXIT
printf -- '- hosts: default\n  connection: local\n  gather_facts: false\n  roles:\n    - repos\n' >"${play}"
passed=0 failed=0
run() { PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin ansible-playbook -i ansible/hosts "${play}" -e "repos_root=${tmp}" -e '{"repos_list":[{"name":"watcher","vars":[]}]}' </dev/null 2>&1 | cat; }
check() { # check <名前> <期待する文字列> <出力>
  if grep -q -- "$2" <<<"$3"; then echo "==> PASS $1"; passed=$((passed + 1)); else echo "==> FAIL $1"; tail -15 <<<"$3"; failed=$((failed + 1)); fi
}
out="$(run || true)"; check "(a) 無ければ複製" "changed=1" "${out}"
if [ -d "${tmp}/watcher/.git" ]; then
  echo "==> PASS (a) 複製ができた"; passed=$((passed + 1))
else
  echo "==> FAIL (a) 複製が無い"; failed=$((failed + 1))
fi
out="$(run || true)"; check "(b) 2 回目は何もしない" "changed=0" "${out}"
rm -rf "${tmp}/watcher" && mkdir "${tmp}/watcher"
out="$(run || true)"; check "(c) git の複製でない" "git の複製でない" "${out}"
rm -rf "${tmp}/watcher" && git init -q "${tmp}/watcher" && git -C "${tmp}/watcher" remote add origin https://github.com/krtsato/not-watcher.git
out="$(run || true)"; check "(d) origin が違う" "origin が krtsato/watcher でない" "${out}"
# (e) 変数が別の複製の中の下位フォルダを指している
rm -rf "${tmp}/watcher" && git init -q "${tmp}/outer" && git -C "${tmp}/outer" remote add origin https://github.com/krtsato/watcher.git && mkdir "${tmp}/outer/watcher"
out="$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin ansible-playbook -i ansible/hosts "${play}" -e "repos_root=${tmp}/outer" -e '{"repos_list":[{"name":"watcher","vars":[]}]}' </dev/null 2>&1 | cat || true)"
check "(e) 別の複製の中" "別の複製" "${out}"
echo "==> 合格 ${passed} / 不合格 ${failed}"
[ "${failed}" -eq 0 ]
