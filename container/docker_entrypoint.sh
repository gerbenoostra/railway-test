#!/bin/sh
set -e
# Remove, by default, the w permission of group and rwx permissions of others.
umask 0027

exec "$@"
