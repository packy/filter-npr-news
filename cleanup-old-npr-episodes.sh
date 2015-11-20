#!/ramdisk/bin/bash

HOME=/home2/dardanco
DIRS="$HOME/www/packy/npr"

for DIR in $DIRS; do
  find $DIR -type f -name '*.mp3' -mtime +14 -delete
done
