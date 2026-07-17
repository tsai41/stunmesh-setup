# Thin launcher over the scripts. Examples:
#   make setup NODE=A
#   make setup NODE=B PEER_KEY=<key>
#   make start / stop / status / logs

.PHONY: setup start stop status logs next

next:
	@./next.sh

setup:
	./setup.sh $(if $(NODE),--node "$(NODE)") $(if $(PEER_KEY),--peer-key "$(PEER_KEY)")

start:
	./start.sh

stop:
	./stop.sh

status:
	@docker ps --filter name=dhtnode --format 'dhtnode:     {{.Status}}' | grep . || echo 'dhtnode:     not running'
	@curl -sS --max-time 2 http://127.0.0.1:8080/node/info 2>/dev/null | jq -r '"dht good:    \(.ipv4.good // 0)"' 2>/dev/null || true
	@pgrep -f stunmesh-go >/dev/null && echo 'stunmesh-go: running' || echo 'stunmesh-go: not running'

logs:
	tail -f stunmesh.log
