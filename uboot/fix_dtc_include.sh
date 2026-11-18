#!/bin/sh
# Modern CPP no longer eats the backslash in the \#include line this old
# build system appends for board -u-boot.dtsi overlays. Strip it here,
# BEFORE the cpp pass, so cpp itself resolves the include (and recursively
# any further #include lines inside it) properly.
sed -i.bak -E 's@^\\#include@#include@' "$1"
