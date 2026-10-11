#!/usr/bin/env bash
# repos 役割の検査。一時ディレクトリを repos_root にして、
# (a) 無ければ複製する (b) 2 回目は何もしない (c) git の複製でない場所は止める
# (d) origin が違えば止める (e) 別の複製の中の下位フォルダなら止める
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
# 役割は playbook と同じ場所から探されるので ansible/ に置く。名前は重ならないように作る
play="$(mktemp ansible/_test_repos.XXXXXX)"
trap 'rm -rf "${tmp}" "${play}"' EXIT
printf -- '- hosts: default\n  connection: local\n  gather_facts: false\n  roles:\n    - repos\n' >"${play}"
passed=0 failed=0
rc=0
run() { # run <repos_root>。出力は out、終了コードは rc に入れる
  rc=0
  out="$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin ansible-playbook -i ansible/hosts "${play}" \
    -e "repos_root=$1" -e '{"repos_list":[{"name":"watcher","vars":[]}]}' </dev/null 2>&1)" || rc=$?
}
check() { # check <名前> <期待する終了 ok|fail> <期待する文字列>
  local want_rc_ok=0
  if [ "$2" = ok ]; then [ "${rc}" -eq 0 ] && want_rc_ok=1; else [ "${rc}" -ne 0 ] && want_rc_ok=1; fi
  if [ "${want_rc_ok}" = 1 ] && grep -q -- "$3" <<<"${out}"; then
    echo "==> PASS $1"; passed=$((passed + 1))
  else
    echo "==> FAIL $1（rc=${rc}）"; tail -15 <<<"${out}"; failed=$((failed + 1))
  fi
}
run "${tmp}"; check "(a) 無ければ複製" ok "changed=1"
if [ -d "${tmp}/watcher/.git" ]; then
  echo "==> PASS (a) 複製ができた"; passed=$((passed + 1))
else
  echo "==> FAIL (a) 複製が無い"; failed=$((failed + 1))
fi
run "${tmp}"; check "(b) 2 回目は何もしない" ok "changed=0"
rm -rf "${tmp}/watcher" && mkdir "${tmp}/watcher"
run "${tmp}"; check "(c) git の複製でない" fail "git の複製でない"
rm -rf "${tmp}/watcher" && git init -q "${tmp}/watcher" && git -C "${tmp}/watcher" remote add origin https://github.com/krtsato/not-watcher.git
run "${tmp}"; check "(d) origin が違う" fail "origin が krtsato/watcher でない"
rm -rf "${tmp}/watcher" && git init -q "${tmp}/outer" && git -C "${tmp}/outer" remote add origin https://github.com/krtsato/watcher.git && mkdir "${tmp}/outer/watcher"
run "${tmp}/outer"; check "(e) 別の複製の中" fail "別の複製"
echo "==> 合格 ${passed} / 不合格 ${failed}"
[ "${failed}" -eq 0 ]
