#!/bin/sh
/Users/packy/bin/filter-npr-news.pl > /tmp/npr-news.xml
scp /tmp/npr-news.xml /tmp/npr-news.txt dardanco@www.dardan.com:www/packy/
