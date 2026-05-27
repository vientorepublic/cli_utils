#!/bin/bash

cd /tmp

git clone https://github.com/GrapheneOS/hardened_malloc.git
cd hardened_malloc

make

mv out/libhardened_malloc.so /usr/lib/

chcon -u system_u /usr/lib/libhardened_malloc.so
chcon -r object_r /usr/lib/libhardened_malloc.so
chcon -t lib_t /usr/lib/libhardened_malloc.so

echo "/usr/lib/libhardened_malloc.so" > /etc/ld.so.preload
