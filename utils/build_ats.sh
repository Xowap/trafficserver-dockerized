#!/usr/bin/bash

set -ex

apt-get source trafficserver

TS_DIR=$(ls -d trafficserver-*)
ln -s $TS_DIR trafficserver

cd trafficserver

sed -i '/configure_flags = \\/a 	--disable-hwloc \\' debian/rules

cat debian/rules

dpkg-buildpackage -us -uc

cd ..

rm -fr $TS_DIR trafficserver

mv trafficserver_*.deb trafficserver.deb
