ANSIBLE_PLAYBOOK ?= ansible
ANSIBLE_FLAGS ?=
INVENTORY ?= ansible/hosts
PLAYBOOK ?= ansible/exec.yaml
EXTRA_VARS ?=

SSH_KEY_TYPE ?= ed25519
GITHUB_EMAIL ?=

SSH_KEY_ARGS := $(if $(filter ed25519,$(SSH_KEY_TYPE)),,-t $(SSH_KEY_TYPE))
GITHUB_EMAIL_ARG := $(if $(GITHUB_EMAIL), $(GITHUB_EMAIL),)

.PHONY: setup bootstrap playbook github-ssh help

setup: bootstrap playbook

bootstrap:
	./scripts/install-brew-ansible.sh

playbook:
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_FLAGS) -i $(INVENTORY) $(if $(EXTRA_VARS),-e "$(EXTRA_VARS)",) $(PLAYBOOK)

github-ssh:
	./scripts/setup-github-ssh.sh $(SSH_KEY_ARGS) $(GITHUB_EMAIL_ARG)

help:
	@echo "setup       Run bootstrap then playbook"
	@echo "bootstrap   Install Homebrew + Ansible"
	@echo "playbook    Run ansible-playbook ($(PLAYBOOK))"
	@echo "github-ssh  Run setup-github-ssh.sh (override with SSH_KEY_TYPE/GITHUB_EMAIL)"
