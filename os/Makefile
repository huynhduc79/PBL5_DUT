# Build va kiem thu tren PC (MSYS2 MinGW64 hoac Linux). Board build trong SoftConsole, xem freertos/README.md.
#   make test       : C cipher <-> vector golden, roi kiem thu dau-cuoi sim -> chaosd -> refmodel
#   make sim        : chi build sim_rtos
# REFMODEL = thu muc chua package refmodel/ (va vectors/out)
REFMODEL ?= ..
CC       ?= gcc
CFLAGS   ?= -std=gnu11 -O2 -Wall -Wextra
PYTHON   ?= python
EXE      := $(if $(filter Windows_NT,$(OS)),.exe,)

COMMON := common/chaos_cipher.c common/chau_block.c common/dht22.c common/app_core.c

all: sim build/test_cipher_vectors$(EXE)

build:
	mkdir -p build

sim: build/sim_rtos$(EXE)

build/sim_rtos$(EXE): sim/sim_rtos.c $(COMMON) common/*.h | build
	$(CC) $(CFLAGS) -Icommon -o $@ sim/sim_rtos.c $(COMMON) -pthread

build/test_cipher_vectors$(EXE): tests/test_cipher_vectors.c common/chaos_cipher.c common/chaos_cipher.h | build
	$(CC) $(CFLAGS) -Icommon -o $@ tests/test_cipher_vectors.c common/chaos_cipher.c

test: all
	./build/test_cipher_vectors$(EXE) $(REFMODEL)/vectors/out
	$(PYTHON) tests/e2e_sim.py --refmodel $(REFMODEL) --sim build/sim_rtos$(EXE)

clean:
	rm -rf build

.PHONY: all sim test clean
