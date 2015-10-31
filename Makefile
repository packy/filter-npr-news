all:
	cp filter-npr-news.pl $(HOME)/bin/
	chmod +x $(HOME)/bin/filter-npr-news.pl
	scp cleanup-old-npr-episodes.sh dardanco@www.dardan.com:bin/

