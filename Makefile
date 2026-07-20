# Thin launcher over the scripts. Examples:
#   make setup NODE=A
#   make setup NODE=B PEER_KEY=<key>
#   make start / stop / status / logs

.PHONY: setup start stop status logs next ssh ssh-setup ssh-teardown check test

next:
	@./scripts/next.sh

setup:
	./scripts/setup.sh $(if $(NODE),--node "$(NODE)") $(if $(PEER_KEY),--peer-key "$(PEER_KEY)") $(if $(IP),--ip "$(IP)") $(if $(PEER_IP),--peer-ip "$(PEER_IP)") $(if $(filter command line,$(origin USER)),--peer-ssh-user "$(USER)")

start:
	./scripts/start.sh

stop:
	./scripts/stop.sh

status:
	@./scripts/status.sh

logs:
	tail -f state/stunmesh.log

# USER comes from the environment for every make run; only honor it when set on the command line
ssh:
	@./scripts/ssh.sh connect $(if $(filter command line,$(origin USER)),--user "$(USER)")

ssh-setup:
	@./scripts/ssh.sh setup $(if $(HOST),--host "$(HOST)") $(if $(filter command line,$(origin USER)),--user "$(USER)")

ssh-teardown:
	@./scripts/ssh.sh teardown

check:
	bash -n scripts/*.sh tests/*.sh
	shellcheck -e SC1090,SC2001 scripts/*.sh tests/*.sh
	docker compose config >/dev/null
	git diff --check

test:
	@./tests/run.sh
