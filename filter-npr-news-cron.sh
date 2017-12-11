#!/usr/local/bin/bash

touch /tmp/filter-npr-news-cron.runtime

/Users/packy/bin/filter-npr-news.pl >> /tmp/npr-news.txt 2>&1

date >> /tmp/nina-log.txt
/Users/packy/bin/convert-npr-rss-to-podcast.py >> /tmp/nina-log.txt 2>&1
