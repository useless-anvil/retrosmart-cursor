PKGNAME := xcursor-retrosmart
VERSION := 1.1.1

# Everything actually happens in build.sh — see that file for the pipeline.
# This Makefile is just a familiar `make` / `make clean` front door for it.

.PHONY: all clean xpm png in cursors previews

all:
	./build.sh all

clean:
	./build.sh clean

xpm:
	./build.sh png

png:
	./build.sh png

in:
	./build.sh in

cursors:
	./build.sh cursors
