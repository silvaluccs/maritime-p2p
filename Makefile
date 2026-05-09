# Nome da rede docker para os containers se comunicarem localmente (caso rode no mesmo PC)
NETWORK_NAME=maritime_network

# --- Variáveis Padrão ---
# Configurações do Sector
SECTOR_NAME ?= sector_local
SECTOR_PORT ?= 5050
SECTOR_HOSTS ?= ""

# Configurações do Drone
DRONE_ID ?= drone_$(shell date +%s)
DRONE_PEERS ?= 127.0.0.1:5050

# Configurações do Sensor
SENSOR_HOST ?= 127.0.0.1:5050

.PHONY: setup-network build-all build-sector build-drone build-sensor run-sector run-drone run-sensor

# Cria a rede docker caso ela não exista
setup-network:
	@docker network inspect $(NETWORK_NAME) >/dev/null 2>&1 || docker network create $(NETWORK_NAME)

# --- COMANDOS DE BUILD ---

build-sector:
	docker build -f apps/sector/Dockerfile -t maritime_sector .

build-drone:
	docker build -f apps/drone/Dockerfile -t maritime_drone .

build-sensor:
	docker build -f apps/sensors/Dockerfile -t maritime_sensor .

build-all: build-sector build-drone build-sensor

# --- COMANDOS DE EXECUÇÃO ---

# O Setor possui um nome fixo dinâmico (--name) e
# mapeia a porta TCP para a máquina hospedeira, permitindo descoberta na LAN.
run-sector: setup-network build-sector
	docker run -it --rm \
		--name $(SECTOR_NAME) \
		--network $(NETWORK_NAME) \
		-p $(SECTOR_PORT):$(SECTOR_PORT)/tcp \
		-e NODE_NAME=$(SECTOR_NAME) \
		-e TCP_PORT=$(SECTOR_PORT) \
		-e HOSTS=$(SECTOR_HOSTS) \
		maritime_sector

# Drones NÃO possuem nome fixo (--name).
run-drone: setup-network build-drone
	docker run -it --rm \
		--network $(NETWORK_NAME) \
		-e DRONE_ID=$(DRONE_ID) \
		-e TCP_PEERS=$(DRONE_PEERS) \
		maritime_drone

# Sensores NÃO possuem nome fixo (--name).
run-sensor: setup-network build-sensor
	docker run -it --rm \
		--network $(NETWORK_NAME) \
		-e HOST=$(SENSOR_HOST) \
		maritime_sensor
