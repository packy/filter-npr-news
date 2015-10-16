#!/Users/packy/perl5/perlbrew/perls/perl-5.22.0/bin/perl -w

use DBI;
use Data::Dumper::Concise;
use DateTime::Format::Mail;
use LWP::Simple;
use XML::RSS;
use strict;

use feature 'say';

# list of times we want
my @keywords = qw( 7AM 8AM 12PM 7PM );
my $days_to_keep = 7;

# get the RSS
my $URL = 'http://www.npr.org/rss/podcast.php?id=500005';
my $content = get($URL);

# parse the RSS
my $rss = XML::RSS->new();
$rss->parse($content);


my @items = get_items( $rss->_get_items );

# make new RSS feed
$rss->{num_items} = 0;
$rss->{items} = [];

foreach my $item ( @items ) {
    $rss->add_item(%$item);
}

say $rss->as_string;


sub get_items {
    my $items = shift;

    # build the regex from keywords
    my $re = join "|", @keywords;
    $re = qr/\b(?:$re)\b/i;

    my $mail = DateTime::Format::Mail->new;

    my $dbh = get_dbh();

    my $insert = $dbh->prepare("INSERT INTO shows (pubdate, item) ".
                               "           VALUES (?, ?)");

    my $exists_in_db = $dbh->prepare("SELECT COUNT(*) FROM shows ".
                                     " WHERE pubdate = ?");

    foreach my $item (@$items) {
        my $title = $item->{title};
        $title =~ s{\s+}{ };  $title =~ s{^\s+}{}; $title =~ s{\s+$}{};

        if ($title !~ /$re/) {
            next;
        }

        my $dt = $mail->parse_datetime($item->{pubDate});
        my $epoch = $dt->epoch;

        $exists_in_db->execute($epoch);
        my ($exists) = $exists_in_db->fetchrow;
        if ($exists > 0) {
            next;
        }

        $insert->execute($epoch, Dumper($item));
    }

    my $now = DateTime->now();
    my $too_old = $now->epoch - ($days_to_keep * 24 * 60 * 60);
    $dbh->do("DELETE FROM shows WHERE pubdate < $too_old");

    my $query = $dbh->prepare("SELECT * FROM shows ORDER BY pubdate");
    $query->execute();

    my @list;
    while ( my($pubdate, $item) = $query->fetchrow ) {
        push @list, eval $item;
    }

    return @list;
}

sub get_dbh {
    my $file = '/Users/packy/data/filter-npr-news.db';
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
    }
    return $dbh;
}
