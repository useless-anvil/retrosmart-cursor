PKGNAME := xcursor-retrosmart
VERSION := 3.1a

# Everything actually happens in build.sh — see that file for the pipeline.
# This Makefile is just a familiar `make` / `make clean` front door for it.

.PHONY: all clean xpm png in cursors

all:
	./build.sh all

clean:
	./build.sh clean

xpm:
	./build.sh xpm

png:
	./build.sh png

in:
	./build.sh in

cursors:
	./build.sh cursors
