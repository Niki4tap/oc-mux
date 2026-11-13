mkdir /usr/bin
mkdir /usr/lib
mkdir /usr/man

wget -f https://raw.githubusercontent.com/Niki4tap/oc-mux/master/src/bin/mux.lua /usr/bin/mux
wget -f https://raw.githubusercontent.com/Niki4tap/oc-mux/master/src/lib/muxd.lua /usr/lib/muxd.lua
wget -f https://raw.githubusercontent.com/Niki4tap/oc-mux/master/src/man/mux /usr/man/mux

echo mux installed, run it with: mux
