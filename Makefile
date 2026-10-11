BREW_PATH := /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
ANSIBLE_PLAYBOOK ?= ansible-playbook
ANSIBLE_FLAGS ?=
INVENTORY ?= ansible/hosts
PLAYBOOK ?= ansible/exec.yaml
EXTRA_VARS ?=
PATH_WITH_BREW := /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

SSH_KEY_TYPE ?= ed25519
GITHUB_EMAIL ?=

SSH_KEY_ARGS := $(if $(filter ed25519,$(SSH_KEY_TYPE)),,-t $(SSH_KEY_TYPE))
GITHUB_EMAIL_ARG := $(if $(GITHUB_EMAIL), $(GITHUB_EMAIL),)

.PHONY: setup bootstrap playbook doctor secrets-list secrets-export secrets-import secrets-restore secrets-recover cutover-trial cutover-check github-ssh help

setup: bootstrap playbook

bootstrap:
	./scripts/install-brew-ansible.sh

playbook:
	PATH=$(BREW_PATH) $(ANSIBLE_PLAYBOOK) $(ANSIBLE_FLAGS) -i $(INVENTORY) $(if $(EXTRA_VARS),-e "$(EXTRA_VARS)",) $(PLAYBOOK)

# 点検（読むだけ）。gh・jq・git・docker・claude・codex・nlm（~/.local/bin）を呼ぶ。
# PHASE は pre-import|cutover|ready（既定 ready）
DOCTOR_PATH := $(HOME)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
PHASE ?= ready

doctor:
	PATH=$(DOCTOR_PATH) $(ANSIBLE_PLAYBOOK) -i $(INVENTORY) ansible/doctor.yaml -e doctor_phase=$(PHASE)

# 秘密と処理済みの記録を暗号化ディスクイメージで運ぶ。**対話の端末から流すこと**（Ansible や CI からは不可）。
# 合言葉は hdiutil が端末で直接尋ねる（引数・環境変数・Ansible の変数には載せない）。
# 2 回に分けて動く: (1) Ansible が入力 JSON を 0600 の一時ファイルへ書くだけ (2) secrets.sh を端末へ繋いだまま直接実行。
# 一時ファイルは成功でも失敗でも trap で消す。イメージはリポジトリの外の絶対パスへ。
SECRETS_SH := ansible/roles/secrets/files/secrets.sh
SECRETS_HOME ?= $(HOME)
SECRETS_PATH_PREFIX ?=
SECRETS_RUN_PATH = $(SECRETS_PATH_PREFIX)$(DOCTOR_PATH)

# secrets_run <action> <イメージの引数（無ければ空）>
define secrets_run
f="$$(mktemp)" && trap 'rm -f "$$f" "$$f.log"' EXIT HUP INT TERM && \
{ PATH=$(SECRETS_RUN_PATH) SECRETS_INPUT_FILE="$$f" $(ANSIBLE_PLAYBOOK) -i $(INVENTORY) ansible/secrets.yaml \
    -e secrets_action=prepare </dev/null >"$$f.log" 2>&1 || { cat "$$f.log"; exit 1; }; } && \
PATH=$(SECRETS_RUN_PATH) SECRETS_HOME="$(SECRETS_HOME)" SECRETS_REPO_ROOT="$(CURDIR)" SECRETS_INPUT_FILE="$$f" \
  /bin/bash $(SECRETS_SH) $(1) $(2)
endef

secrets-list:
	@$(call secrets_run,list,)

secrets-export:
	@test -n "$(OUT)" || { echo "OUT=<出力先の絶対パス.dmg> を指定してください" >&2; exit 2; }
	@$(call secrets_run,export,"$(abspath $(OUT))")

secrets-import:
	@test -n "$(IMAGE)" || { echo "IMAGE=<イメージの絶対パス.dmg> を指定してください" >&2; exit 2; }
	@$(call secrets_run,import,"$(abspath $(IMAGE))")

secrets-restore:
	@test -n "$(IMAGE)" || { echo "IMAGE=<イメージの絶対パス.dmg> を指定してください" >&2; exit 2; }
	@$(call secrets_run,restore,"$(abspath $(IMAGE))")

# 強制終了などで import・restore が途中で止まった跡を、記録と実際の状態から配置前へ戻す（やり直しても同じ結果）
secrets-recover:
	@$(call secrets_run,recover,)

# 切り替えの道具（どちらも読むだけ。手順は docs/cutover.md）
# cutover-trial: 試し実行の gh コマンドを出すだけ（起動しない。手元の複製のワークフロー定義を読む）
# cutover-check: 完了の一覧（確認対象 21 件）が新しい Mac の runner で成功したかを GitHub の run から判定する
#   make cutover-check SINCE=<YYYY-MM-DD> RUNNERS=<新しい Mac の runner の名前をカンマ区切り、または名前の末尾>
cutover-trial:
	@PATH=$(DOCTOR_PATH) ./scripts/cutover-trial.sh

cutover-check:
	@test -n "$(SINCE)" || { echo "SINCE=<YYYY-MM-DD> を指定してください" >&2; exit 2; }
	@test -n "$(RUNNERS)" || { echo "RUNNERS=<名前,名前 または末尾> を指定してください" >&2; exit 2; }
	@PATH=$(DOCTOR_PATH) ./scripts/cutover-check.sh "$(SINCE)" "$(RUNNERS)"

github-ssh:
	./scripts/setup-github-ssh.sh $(SSH_KEY_ARGS) $(GITHUB_EMAIL_ARG)

help:
	@echo "setup       Run bootstrap then playbook"
	@echo "bootstrap   Install Homebrew + Ansible"
	@echo "playbook    Run ansible-playbook ($(PLAYBOOK))"
	@echo "doctor      Run read-only checks (PHASE=pre-import|cutover|ready, default ready)"
	@echo "secrets-list     Show what secrets-export would carry (read-only)"
	@echo "secrets-export   OUT=<abs path.dmg>  Encrypt secrets and state records into a disk image"
	@echo "secrets-import   IMAGE=<abs path.dmg>  Place them on the new Mac (all or nothing), then doctor"
	@echo "secrets-restore  IMAGE=<abs path.dmg>  Back up what exists, then replace with the image"
	@echo "secrets-recover  Undo a half-finished import/restore left by a crash (idempotent)"
	@echo "cutover-trial  Print the dry-run gh commands for the cutover trial (read-only)"
	@echo "cutover-check  SINCE=<YYYY-MM-DD> RUNNERS=<names or suffix>  Judge whether the 21 jobs to confirm succeeded on the new Mac runners (read-only)"
	@echo "github-ssh  Run setup-github-ssh.sh (override with SSH_KEY_TYPE/GITHUB_EMAIL)"
