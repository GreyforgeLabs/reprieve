CC ?= cc
CFLAGS ?= -O2 -pipe

.PHONY: native clean
native: bin/reprieve-journal-native

bin/reprieve-journal-native: bin/reprieve-journal.c
	$(CC) $(CFLAGS) -std=c11 -Wall -Wextra -D_GNU_SOURCE $(shell pkg-config --cflags json-c) -o $@ $< $(shell pkg-config --libs json-c)

clean:
	rm -f bin/reprieve-journal-native
