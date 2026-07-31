# Thin launcher over the scripts. Examples:
#   make setup NODE=A
#   make setup NODE=B PEER_KEY=<the key node A printed>
#   make start / stop / status / logs

.PHONY: setup start stop restart status logs next ssh proxy ssh-setup ssh-teardown add-peer remove-peer list-peers check test

next:
	@./scripts/next.sh

setup:
	./scripts/setup.sh $(if $(NODE),--node "$(NODE)") $(if $(PEER_KEY),--peer-key "$(PEER_KEY)") $(if $(IP),--ip "$(IP)") $(if $(PEER_IP),--peer-ip "$(PEER_IP)") $(if $(filter command line,$(origin USER)),--peer-ssh-user "$(USER)")

start:
	./scripts/start.sh

stop:
	./scripts/stop.sh

restart:
	./scripts/restart.sh

status:
	@./scripts/status.sh

logs:
	tail -f state/stunmesh.log

# USER comes from the environment for every make run; only honor it when set on the command line
ssh:
	@./scripts/ssh.sh connect $(if $(PEER),--peer "$(PEER)") $(if $(filter command line,$(origin USER)),--user "$(USER)")

proxy:
	@./scripts/ssh.sh proxy $(if $(PEER),--peer "$(PEER)") $(if $(PROXY_PORT),--port "$(PROXY_PORT)") $(if $(filter command line,$(origin USER)),--user "$(USER)")

ssh-setup:
	@./scripts/ssh.sh setup $(if $(HOST),--host "$(HOST)") $(if $(filter command line,$(origin USER)),--user "$(USER)")

ssh-teardown:
	@./scripts/ssh.sh teardown

# hub use-case: connect this machine to more than one other node
add-peer:
	@./scripts/peer.sh add $(if $(NAME),--name "$(NAME)") $(if $(IP),--ip "$(IP)") $(if $(KEY),--key "$(KEY)") $(if $(filter command line,$(origin USER)),--ssh-user "$(USER)")

remove-peer:
	@./scripts/peer.sh remove $(if $(NAME),--name "$(NAME)")

list-peers:
	@./scripts/peer.sh list

check:
	bash -n scripts/*.sh tests/*.sh
	shellcheck -e SC1090,SC2001 scripts/*.sh tests/*.sh
	docker compose config >/dev/null
	git diff --check

test:
	@./tests/run.sh
