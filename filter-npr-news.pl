#!/Users/packy/perl5/perlbrew/perls/perl-5.22.0/bin/perl -w

use DBI;
use Data::Dumper::Concise;
use DateTime;
use DateTime::Format::Mail;
use LWP::Simple;
use Net::OpenSSH;
use URI;
use XML::RSS;
use strict;

use feature qw( say state );

# define all the things!
use constant {
    URL         => 'http://www.npr.org/rss/podcast.php?id=500005',
    TITLE_ADD   => ' (filtered by packy)',
    TITLE_MAX   => 40, # characters
    SLEEP_FOR   => 120, # seconds (2 minutes)
    MAX_RETRIES => 10,
    KEEP_DAYS   => 7,

    REMOTE_HOST => 'www.dardan.com',
    REMOTE_USER => 'dardanco',

    MEDIA_URL   => 'http://packy.dardan.com/npr',

    TZ          => 'America/New_York',
    LOGFILE     => '/tmp/npr-news.txt',
    XMLFILE     => '/tmp/npr-news.xml',
    IN_DIR      => '/tmp/incoming',
    OUT_DIR     => '/tmp/outgoing',
    DATAFILE    => '/Users/packy/data/filter-npr-news.db',

    SOX_BINARY  => '/usr/local/bin/sox',
};

# list of times we want - different times on weekends
my @keywords = is_weekday() ? qw( 7AM 8AM 12PM 6PM 7PM )
             :                qw( 7AM     12PM     7PM );

my $dbh  = get_dbh();
my $rss;
my $items;

foreach my $retry (1 .. MAX_RETRIES+1) {
    # get the RSS
    write_log("Fetching " . URL);
    my $content = get(URL);

    # parse the RSS
    $rss = XML::RSS::Extra->new();

    $rss->parse($content);
    write_log("Parsed XML");

    $items = $rss->_get_items;

    my $not_same_show_as_last_time = ! same_show_as_last_time( $items );

    if ($not_same_show_as_last_time) {
        last;
    }
    if ($retry > MAX_RETRIES) {
        write_log("MAX_RETRIES (".MAX_RETRIES.") exceeded");
        last;
    }

    if ($ENV{NPR_NOSLEEP}) {
        last;
    }

    write_log("Sleeping for ".SLEEP_FOR." seconds...");
    push_log_to_remotehost();
    sleep SLEEP_FOR;
    write_log("Trying RSS feed again (retry #$retry)");
}

get_items( $items );

# make new RSS feed
$rss->clear_items;

foreach my $item ( @$items ) {
    $rss->add_item(%$item);
}

re_title($rss);

write_log("Writing RSS XML to " . XMLFILE);
open my $fh, '>', XMLFILE;
say {$fh} $rss->as_string;
close $fh;
push_xml_to_remotehost();

#################################### subs ####################################

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

        if ($title !~ /$re/ && ! $ENV{NPR_NOSKIP}) {
            write_log("'$title' doesn't match $re; skipping");
            next;
        }

        $exists_in_db->execute($epoch);
        my ($exists) = $exists_in_db->fetchrow;
        if ($exists > 0) {
            write_log("'$title' already in database; skipping");
            next;
        }

        normalize_audio($item);

        write_log("Adding '$title' to database");
        $insert->execute($epoch, Dumper($item));
    }

    my $now = DateTime->now();
    my $too_old = $now->epoch - (KEEP_DAYS * 24 * 60 * 60);
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

#################################### audio ####################################

sub filename_from_uri {
    my $uri = shift;
    return( ( URI->new($uri)->path_segments )[-1] );
}

sub normalize_audio {
    my $item = shift;
    my $uri  = $item->{enclosure}->{url};
    my $file = filename_from_uri($uri);

    -d IN_DIR  or mkdir IN_DIR;
    -d OUT_DIR or mkdir OUT_DIR;

    my $infile  = join '/', IN_DIR,  $file;
    my $outfile = join '/', OUT_DIR, $file;

    my $code = getstore($uri, $infile);
    write_log("Fetched '$uri' to $infile; RESULT $code");
    return unless $code == 200;

    -x SOX_BINARY
        or die "no executable at " . SOX_BINARY;

    write_log("Normalizing $infile to $outfile");
    system join(q{ }, SOX_BINARY, '--norm', $infile, $outfile);

    my $size = -s $outfile || 0;

    $item->{enclosure}->{url}    = join '/', MEDIA_URL, $file;
    $item->{enclosure}->{length} = $size;

    push_media_to_remotehost($outfile);

    unlink $infile;
    unlink $outfile;
}

#################################### db ####################################

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

#################################### time ####################################

sub now {
    return DateTime->now( time_zone => TZ );
}

sub is_weekday {
    return now()->day_of_week < 6;
}

################################### copying ###################################

sub push_to_remotehost {
    my ($from, $to) = @_;

    my $connect = join '@', REMOTE_USER, REMOTE_HOST;

    state $ssh = Net::OpenSSH->new($connect);

    write_log("Copying $from to $connect:$to");

    if ( $ssh->scp_put($from, $to) ) {
        write_log("Copy success");
    }
    else {
        write_log("COPY ERROR: ". $ssh->error);
    }
}

sub push_xml_to_remotehost {
    push_to_remotehost(XMLFILE, 'www/packy/');
}

sub push_log_to_remotehost {
    push_to_remotehost(LOGFILE, 'www/packy/');
}

sub push_media_to_remotehost {
    my $from = shift;
    push_to_remotehost($from, 'www/packy/npr/');
}

################################### logging ###################################

sub write_log {
    open my $logfile, '>>', LOGFILE;
    my $now = now();
    my $ts  = $now->ymd . q{ } . $now->hms . q{ };
    foreach my $line ( @_ ) {
        print {$logfile} $ts . $line . "\n";
    }
    close $logfile;
}

BEGIN {
    unlink LOGFILE;
    write_log('Started run');

    $SIG{__DIE__} = sub {
        my $err = shift;
        write_log('FATAL: '.$err);
    };
}

END {
    write_log('Finished run');
    push_log_to_remotehost();
}

##################################### XML #####################################

sub re_title {
    my $rss = shift;

    my $existing_title = $rss->channel('title');
    my $add_len        = length(TITLE_ADD);

    if (length($existing_title) + $add_len > TITLE_MAX) {
        $existing_title = substr($existing_title, 0, TITLE_MAX - $add_len - 1);
    }

    $rss->channel('title' => $existing_title . TITLE_ADD);
}

sub item_info {
    state $mail = DateTime::Format::Mail->new;
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

package XML::RSS::Extra;
use base qw( XML::RSS );

sub clear_items {
    my $self = shift;
    $self->{num_items} = 0;
    $self->{items} = [];
}

sub _get_default_modules {
    return {
        'http://www.npr.org/rss/'                    => 'npr',
        'http://api.npr.org/nprml'                   => 'nprml',
        'http://www.itunes.com/dtds/podcast-1.0.dtd' => 'itunes',
        'http://purl.org/rss/1.0/modules/content/'   => 'content',
        'http://purl.org/dc/elements/1.1/'           => 'dc',
    };
}

__END__
