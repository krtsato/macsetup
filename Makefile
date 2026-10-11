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

.PHONY: setup bootstrap playbook doctor github-ssh help

setup: bootstrap playbook

bootstrap:
	./scripts/install-brew-ansible.sh

playbook:
	PATH=$(BREW_PATH) $(ANSIBLE_PLAYBOOK) $(ANSIBLE_FLAGS) -i $(INVENTORY) $(if $(EXTRA_VARS),-e "$(EXTRA_VARS)",) $(PLAYBOOK)

# 点検（読むだけ）。gh・jq・git・docker・claude・codex・nlm（~/.local/bin）を呼ぶ。
# 段階は PHASE=pre-import|cutover|ready（既定 ready）
DOCTOR_PATH := $(HOME)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
PHASE ?= ready

doctor:
	PATH=$(DOCTOR_PATH) $(ANSIBLE_PLAYBOOK) -i $(INVENTORY) ansible/doctor.yaml -e doctor_phase=$(PHASE)

github-ssh:
	./scripts/setup-github-ssh.sh $(SSH_KEY_ARGS) $(GITHUB_EMAIL_ARG)

help:
	@echo "setup       Run bootstrap then playbook"
	@echo "bootstrap   Install Homebrew + Ansible"
	@echo "playbook    Run ansible-playbook ($(PLAYBOOK))"
	@echo "doctor      Run read-only checks (PHASE=pre-import|cutover|ready, default ready)"
	@echo "github-ssh  Run setup-github-ssh.sh (override with SSH_KEY_TYPE/GITHUB_EMAIL)"
