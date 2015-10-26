#!/Users/packy/perl5/perlbrew/perls/perl-5.22.0/bin/perl -w

use DBI;
use Data::Dumper::Concise;
use DateTime::Format::Mail;
use LWP::Simple;
use XML::RSS;
use strict;

use feature 'say';

use constant {
    TITLE_ADD   => ' (filtered by packy)',
    TITLE_MAX   => 40, # characters
    LOGFILE     => '/tmp/npr-news.txt',
    DATAFILE    => '/Users/packy/data/filter-npr-news.db',
    SLEEP_FOR   => 120, # seconds (2 minutes)
    MAX_RETRIES => 10,
};

# list of times we want
my @keywords = qw( 7AM 8AM 12PM 6PM 7PM );
my $days_to_keep = 7;

my $URL = 'http://www.npr.org/rss/podcast.php?id=500005';


my $mail = DateTime::Format::Mail->new;
my $dbh  = get_dbh();
my $rss;
my $items;

foreach my $retry (1 .. MAX_RETRIES+1) {
    # get the RSS
    write_log("Fetching $URL");
    my $content = get($URL);

    # parse the RSS
    $rss = XML::RSS->new();
    $rss->parse($content);
    write_log("Parsed XML");

    $items = $rss->_get_items;

    my $not_same_show_as_last_time = ! same_show_as_last_time( $items );

    if ($not_same_show_as_last_time) {
        last;
    }
    if ($retry > MAX_RETRIES) {
        write_log("MAX_RETRIES (".MAX_RETRIES.") exceeded");
    }

    if ($ENV{NPR_NOSLEEP}) {
        last;
    }

    write_log("Sleeping for ".SLEEP_FOR." seconds...");
    sleep SLEEP_FOR;
    write_log("Trying RSS feed again (retry #$retry)");
}

get_items( $items );

# make new RSS feed
$rss->{num_items} = 0;
$rss->{items} = [];

foreach my $item ( @$items ) {
    $rss->add_item(%$item);
}

re_title($rss);

write_log("Writing RSS XML to stdout");
say $rss->as_string;


sub re_title {
    my $rss = shift;
    my $existing_title = $rss->channel('title');
    my $add_len        = length(TITLE_ADD);
    if (length($existing_title) + $add_len > TITLE_MAX) {
        $existing_title = substr($existing_title, 0, TITLE_MAX - $add_len - 1);
    }
    $rss->channel('title' => $existing_title . TITLE_ADD);
}

sub get_items {
    my $items = shift;

    # build the regex from keywords
    my $re = join "|", @keywords;
    $re = qr/\b(?:$re)\b/i;

    my $insert = $dbh->prepare("INSERT INTO shows (pubdate, item) ".
                               "           VALUES (?, ?)");

    my $exists_in_db = $dbh->prepare("SELECT COUNT(*) FROM shows ".
                                     " WHERE pubdate = ?");

    foreach my $item (@$items) {
        my ($epoch, $title) = item_info($item);

        if ($title !~ /$re/) {
            write_log("'$title' doesn't match $re; skipping");
            next;
        }

        $exists_in_db->execute($epoch);
        my ($exists) = $exists_in_db->fetchrow;
        if ($exists > 0) {
            write_log("'$title' already in database; skipping");
            next;
        }

        write_log("Adding '$title' to database");
        $insert->execute($epoch, Dumper($item));
    }

    my $now = DateTime->now();
    my $too_old = $now->epoch - ($days_to_keep * 24 * 60 * 60);
    $dbh->do("DELETE FROM shows WHERE pubdate < $too_old");

    my $query = $dbh->prepare("SELECT * FROM shows ORDER BY pubdate");
    $query->execute();

    @$items = ();
    while ( my($pubdate, $item) = $query->fetchrow ) {
        my $evaled = eval $item;
        push @$items, $evaled;
        my ($epoch, $title) = item_info($evaled);
        write_log("Fetched '$title' from database; adding to feed");
    }
}

sub same_show_as_last_time {
    my $items = shift;

    my $get_last_show = $dbh->prepare("SELECT * FROM last_show");

    my ($epoch, $title) = item_info($items->[0]);

    $get_last_show->execute;
    my ($last_time, $last_title) = $get_last_show->fetchrow;

    # save the episode we just fetched for next time
    my $update = $dbh->prepare("UPDATE last_show SET pubdate = ?, title = ? ".
                               " WHERE pubdate = ?");
    $update->execute($epoch, $title, $last_time);

    my $is_same = ($last_time == $epoch);

    if ($is_same) {
        write_log("RSS feed has not updated since '$last_title' was published");
    }

    return $is_same;
}

sub item_info {
    my $item  = shift;
    my $title = fix_whitespace($item->{title});
    my $dt    = $mail->parse_datetime($item->{pubDate});
    my $epoch = $dt->epoch;
    return $epoch, $title;
}

sub fix_whitespace {
    my $string = shift;
    $string =~ s{\s+}{ };  $string =~ s{^\s+}{}; $string =~ s{\s+$}{};
    return $string;
}

sub get_dbh {
    my $file = DATAFILE;
    my $exists = -f $file;

    my $dbh = DBI->connect(          
        "dbi:SQLite:dbname=$file", 
        "",
        "",
        { RaiseError => 1}
    ) or die $DBI::errstr;

    unless ($exists) {
        # first time - set up database
        $dbh->do("CREATE TABLE shows (pubdate INTEGER PRIMARY KEY, item TEXT)");
        $dbh->do("CREATE INDEX shows_idx ON shows (pubdate);");
        $dbh->do("CREATE TABLE last_show (pubdate INTEGER PRIMARY KEY, title TEXT)");
    }
    return $dbh;
}

sub write_log {
    open my $logfile, '>>', LOGFILE;
    my $now = DateTime->now( time_zone => 'America/New_York' );
    my $ts  = $now->ymd . q{ } . $now->hms . q{ };
    foreach my $line ( @_ ) {
        print {$logfile} $ts . $line . "\n";
    }
    close $logfile;
}

BEGIN {
    unlink LOGFILE;
    write_log('Started run');
}

END {
    write_log('Finished run');
}
