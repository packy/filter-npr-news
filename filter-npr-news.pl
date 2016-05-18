#!/Users/packy/perl5/perlbrew/perls/perl-5.22.0/bin/perl -w

use DBI;
use Data::Dumper::Concise;
use DateTime;
use DateTime::Format::Mail;
use File::Basename;
use IPC::PerlSSH;
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
    MAX_RETRIES => 20,
    KEEP_DAYS   => 7,

    REMOTE_HOST => 'www.dardan.com',
    REMOTE_USER => 'dardanco',
    REMOTE_DIR  => 'www/packy/',

    MEDIA_URL   => 'http://packy.dardan.com/npr',

    TZ          => 'America/New_York',
    LOG_KEEP    => 48, # number of old log files to keep
    LOGFILE     => 'npr-news.txt',
    LOGDIR      => '/tmp/',
    XMLFILE     => '/tmp/npr-news.xml',
    IN_DIR      => '/tmp/incoming',
    OUT_DIR     => '/tmp/outgoing',
    DATAFILE    => '/Users/packy/data/filter-npr-news.db',

    SOX_BINARY  => '/usr/local/bin/sox',
};

# list of times we want - different times on weekends
my @keywords = is_weekday() ? qw( 7AM 8AM 12PM 6PM 7PM )
             :                qw( 7AM     12PM     7PM );

my $dbh = get_dbh();  # used in a couple places, best to be global

my $rss;   # these two vars are only used in the main code block,
my $items; # but can't be scoped to the foreach loop

# since, for cosmetic reasons, we're starting the count at 1, we need
# to loop up to MAX_RETRIES + 1; otherwise, we'll only have the first
# attempt and then (MAX_RETRIES - 1).  If I'd called the constant
# MAX_ATTEMPTS then it would make sense to start at zero...
foreach my $retry (1 .. MAX_RETRIES + 1) {

    # get the RSS
    write_log("Fetching " . URL);
    my $content = get(URL);

    # parse the RSS using a subclass of XML::RSS
    $rss = XML::RSS::NPR->new();
    $rss->parse($content);
    write_log("Parsed XML");

    $items = $rss->_get_items;

    # if a new show was published in the feed, we don't need to wait
    # in a loop for a new one
    if ( same_show_as_last_time( $items ) ) {

        # we don't want the script to wait forever - if no new episode
        # appears after a maximum number of retries, give up and generate
        # the feed with the episodes we have
        if ($retry > MAX_RETRIES) {
            write_log("MAX_RETRIES (".MAX_RETRIES.") exceeded");
            last;
        }

        sleep_for_a_while($retry);
        next;
    }

    # Ok, try to fetch the audio if it meets our criteria
    last if fetch_new_shows($items);

    write_log("Unable to fetch show!");
    sleep_for_a_while($retry);
}

# fill the item list with items we've cached in our database
get_items_from_database( $items );

# make new RSS feed devoid of the original items... ok, ITEM
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

sub sleep_for_a_while {
    my $retry = shift;

    # for debugging purposes, I want to be able to not have the script
    # sleep, and the choices were add command line switch processing
    # or check an environment variable. This was the simpler option.
    if ($ENV{NPR_NOSLEEP}) {
        write_log("NPR_NOSLEEP=$ENV{NPR_NOSLEEP}; not sleeping");
        return;
    }

    # log the fact that we're sleeping so we can observe what the
    # script is doing while it's running
    write_log("Sleeping for ".SLEEP_FOR." seconds...");

    # since I usually want to listen to these podcasts when I'm away
    # from my desktop computer, copy the log file up to the webserver
    # so I can check on it remotely.  this way, if it's spending an
    # inordinate amount of time waiting for a new episode, I can see
    # that from my phone's browser...
    push_log_to_remotehost();

    # actually sleep
    sleep SLEEP_FOR;

    # and note which number retry this is
    write_log("Trying RSS feed again (retry #$retry)");
}

sub fetch_new_shows {
    my $items = shift;

    # build the regex for matching desired episodes from keywords
    my $re = join "|", @keywords;
    $re = qr/\b(?:$re)\b/i;

    my $insert = $dbh->prepare("INSERT INTO shows (pubdate, item) ".
                               "           VALUES (?, ?)");

    my $exists_in_db = $dbh->prepare("SELECT COUNT(*) FROM shows ".
                                     " WHERE pubdate = ?");

    # I know the feed only has the one item in it, but it SHOULD have
    # more, so let's go through the motions of checking each item
    my $success = 1;

    foreach my $item (@$items) {

        # pawn off the specifics of how we get the information to a sub
        my ($epoch, $title) = item_info($item);

        # again, for debugging purposes, I wanted to be able to not
        # have the script skip the current item, and the choices were
        # add command line switch processing or check an environment
        # variable. This was the simpler option.

        if ($title !~ /$re/ && ! $ENV{NPR_NOSKIP}) {
            write_log("'$title' doesn't match $re; skipping");
            save_show_for_next_time($item);
            next;
        }
        elsif ($ENV{NPR_NOSKIP}) {
            write_log("NPR_NOSKIP=$ENV{NPR_NOSKIP}; not skipping");
        }

        # check to see if we already have it in the DB
        $exists_in_db->execute($epoch);
        my ($exists) = $exists_in_db->fetchrow;

        if ($exists > 0) {
            write_log("'$title' already in database; skipping");
            next;
        }

        # the NPR news podcast is notoriously bad at normalizing the
        # volume of its broadcasts; some are easy to hear and some are
        # so quiet it's impossible to ehar them when listening on a
        # city street, so, let's normalize them to a maximum volume

        $success &&= normalize_audio($item, $insert);

    }
    return $success;
}

sub get_items_from_database {
    my $items = shift;

    # go through the database and dump episodes that are older than
    # our retention period.  Since we're using epoch time (seconds
    # since some date, usually midnight 1970-01-01) as the key to our
    # episode cache table, it's really easy to determine which
    # episodes are too old

    my $now     = DateTime->now();
    my $too_old = $now->epoch - (KEEP_DAYS * 24 * 60 * 60);
    $dbh->do("DELETE FROM shows WHERE pubdate < $too_old");

    # now let's fetch the episodes from the episode cache table in
    # oldest-first order. Again, since we're keyed on the episode's
    # publish date in epoch time, we can do this with a simple numeric
    # sort.

    my $query = $dbh->prepare("SELECT * FROM shows ORDER BY pubdate");
    $query->execute();

    @$items = ();
    while ( my($pubdate, $item) = $query->fetchrow ) {

        # just blindly evaluating text is a potential security problem,
        # but I know all these entries came from me writing dumper-ed code,
        # so I feel safe in doing so...
        my $evaled = eval $item;

        push @$items, $evaled;

        # log which episodes we're putting into the feed
        my ($epoch, $title) = item_info($evaled);
        write_log("Fetched '$title' from database; adding to feed");
    }
}

sub same_show_as_last_time {
    my $items = shift;

    # so we know when the feed is late in publishing a new item,
    # we have a table that stores the publication date of the last
    # episode we saw.  It also stores the title of the episode so
    # we can log which episode it was.

    my $get_last_show = $dbh->prepare("SELECT * FROM last_show");

    # get the information for the current episode
    my ($epoch, $title) = item_info($items->[0]);

    # fetch the last epsiode from the DB
    $get_last_show->execute;
    my ($last_time, $last_title) = $get_last_show->fetchrow;

    # now compare the current episode with the one we got from the DB
    my $is_same = ($last_time == $epoch);

    if ($is_same) {
        write_log("RSS feed has not updated since '$last_title' was published");
    }

    return $is_same;
}

sub save_show_for_next_time {
    my $item = shift;

    # get the information for the current episode
    my ($epoch, $title) = item_info($item);

    # save the episode we just fetched for next time
    my $update = $dbh->prepare("UPDATE last_show SET pubdate = ?, title = ?");
    $update->execute($epoch, $title);
}

#################################### audio ####################################

sub extension_from_file {
    my $file = shift;
    return( ( fileparse($file, qr/\.[^.]*/) )[-1] );
}

sub filename_from_uri {
    my $uri = shift;

    # abstract out the complexities of fetching the filename from a
    # URI so the code will read easier; in this case, we're
    # instantiating a new URI class object and calling path_segments()
    # to get the segments of the path, and then returning the last
    # element, which is going to be the filename.

    return( ( URI->new($uri)->path_segments )[-1] );
}

sub normalize_audio {
    my $item   = shift;
    my $insert = shift;
    my $uri    = item_url($item);
    my $file   = filename_from_uri($uri);

    my ($epoch, $title) = item_info($item);
    $title = fix_whitespace($title);

    # change the title into a filename; this will guarantee unique filenames
    $title =~ s/\s+/-/g;
    $title =~ s/://g;
    $title .= extension_from_file($file);

    # perl idiom for "if directory doesn't exist, make it"
    -d IN_DIR  or mkdir IN_DIR;
    -d OUT_DIR or mkdir OUT_DIR;

    # construct fill pathnames to the file we're downloading and
    # then normalizing to
    my $infile  = join '/', IN_DIR,  $file;
    my $outfile = join '/', OUT_DIR, $title;

    # fetch the MP3 file using LWP::Simple
    my $code = getstore($uri, $infile);
    write_log("Fetched '$uri' to $infile; RESULT $code");
    return unless $code == 200;

    # if, for some reason, we don't have the program to normalize audio,
    # crash with a message complaining about it being missing
    -x SOX_BINARY
        or die "no executable at " . SOX_BINARY;

    # call SoX to normalize the audio
    write_log("Normalizing $infile to $outfile");
    my $sox_cmd = join q{ }, SOX_BINARY, '--norm', $infile, $outfile;
    system($sox_cmd) == 0 or do {
        write_log("Error running '$sox_cmd': $?");
        return;
    };

    # the feed doesn't publish an item length in bytes, but it really
    # ought to, so let's get the size of the MP3 file.
    my $size = -s $outfile || 0;

    # re-write the bits of the item we're changing
    item_url($item, join '/', MEDIA_URL, $title);
    item_length($item, $size);

    save_show_for_next_time($item);

    # send the normalized MP3 file up to the webserver
    push_media_to_remotehost($outfile);

    # clean up after ourselves
    unlink $infile;
    unlink $outfile;

    # it's easier to store the data in the episode cache table as
    # a perl representation of the parsed data than it is to
    # serialize it back into XML and then re-parse it when we need
    # it again.
    write_log("Adding '$title' to database");
    $insert->execute($epoch, Dumper($item));

    return 1;
}

#################################### db ####################################

sub get_dbh {
    my $file = DATAFILE;

    # check to see if the datafile exists BEFORE we connect to it
    my $exists = -f $file;

    my $dbh = DBI->connect(          
        "dbi:SQLite:dbname=$file", 
        "",
        "",
        { RaiseError => 1}
    ) or die $DBI::errstr;

    # if the datafile didn't exist before we connected to it, let's set up
    # the schema we're using
    unless ($exists) {
        $dbh->do("CREATE TABLE shows (pubdate INTEGER PRIMARY KEY, item TEXT)");
        $dbh->do("CREATE INDEX shows_idx ON shows (pubdate);");
        $dbh->do("CREATE TABLE last_show (pubdate INTEGER PRIMARY KEY, ".
                 "                        title   TEXT)");
        $dbh->do("INSERT INTO last_show VALUES (0, '')");
    }

    return $dbh;
}

#################################### time ####################################

sub now {
    # set the time zone in the DateTime object, so we get non-UTC time
    return DateTime->now( time_zone => TZ );
}

sub is_weekday {
    # makes our code easier to read
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

# helper functions to make the code easier to read

sub push_xml_to_remotehost {
    push_to_remotehost(XMLFILE, REMOTE_DIR);
}

sub push_log_to_remotehost {
    push_to_remotehost(LOGDIR . LOGFILE, REMOTE_DIR);
}

sub push_media_to_remotehost {
    my $from = shift;
    push_to_remotehost($from, REMOTE_DIR . 'npr/');
}

################################### logging ###################################

sub write_log {
    # I'm opening and closing the logfile every time I write to it so
    # it's easier for external processes to monitor the progress of
    # this script
    open my $logfile, '>>', LOGDIR . LOGFILE;

    my $now = now();
    my $ts  = $now->ymd . q{ } . $now->hms . q{ };

    # I don't write multiple lines yet, but I might want to!
    foreach my $line ( @_ ) {
        say {$logfile} $ts . $line;
    }

    close $logfile;
}

sub log_rename_and_push {
    my ($old, $new) = @_;
    return unless -e $old;
    rename $old, $new;
    push_to_remotehost($new, REMOTE_DIR);
}

sub log_rotate {
    my ($old, $new);
    return if $ENV{NPR_NOROTATE};

    my $ipc = IPC::PerlSSH->new( Host => REMOTE_HOST, User => REMOTE_USER );

    my $code = <<'CODE';
my $keep = shift;
my $log  = shift;
my $dir  = shift;
my $dir2 = $dir . 'npr/';
my $num_digits = length($keep);
(my $format = $log) =~ s/(\.[^\.]+)$/-%0${num_digits}d$1/;
my @return;
foreach my $i (reverse 1 .. $keep - 1) {
    my $old = sprintf $format, $i;
    my $new = sprintf $format, $i + 1;
    if (rename "$dir2$old", "$dir2$new") {
        push @return, "Renamed $old to $new";
    }
    else {
        push @return, "Unable to rename $old to $new: $!";
    }
}

my $new = sprintf $format, 1;
if (rename "$dir$log", "$dir2$new") {
    push @return, "Renamed $log to $new";
}
else {
    push @return, "Unable to rename $log to $new: $!";
}

return @return;
CODE

    $ipc->store('log_rotate', $code);

    write_log('Rotating logs on webserver...');
    push_log_to_remotehost();

    my @results = $ipc->call('log_rotate', LOG_KEEP, LOGFILE, REMOTE_DIR);

    foreach my $line (@results) {
        write_log($line);
    }
    write_log('Done with log rotation');
    push_log_to_remotehost();
    unlink LOGDIR . LOGFILE;
}

INIT {
    log_rotate(); # rotate out old log files
    write_log('Started run'); # log that the run has started

    # register a DIE handler that will write whatever message I die() with
    # to our logfile so I can see it in the logs
    $SIG{__DIE__} = sub {
        my $err = shift;
        write_log('FATAL: '.$err);
        # if we die(), after this runs, the END block will be executed!
    };
}

END {
    # when the program finishes, log that
    write_log('Finished run');

    # and, so I can see these logs remotely, push them up to the webserver
    push_log_to_remotehost();
}

##################################### XML #####################################

sub re_title {
    my $rss = shift;

    # append some text to the channel's title so I can differentiate
    # this feed from the original feed in my podcast app

    my $existing_title = $rss->channel('title');
    my $add_len        = length(TITLE_ADD);

    if (length($existing_title) + $add_len > TITLE_MAX) {
        $existing_title = substr($existing_title, 0, TITLE_MAX - $add_len - 1);
    }

    $rss->channel('title' => $existing_title . TITLE_ADD);
}

sub item_info {
    state $mail = DateTime::Format::Mail->new; # only initialized once!

    my $item  = shift;
    my $title = fix_whitespace($item->{title});
    my $dt    = $mail->parse_datetime($item->{pubDate});
    my $epoch = $dt->epoch;
    return $epoch, $title;
}

sub fix_whitespace {
    my $string = shift;

    # multiple whitespace compressed to a single space
    $string =~ s{\s+}{ };

    # remove leading and trailing spaces
    $string =~ s{^\s+}{}; $string =~ s{\s+$}{};

    return $string;
}

# let's define some pseudo-accessors (since these are unblessed
# hashes, not objects) that will make our code easier to read

sub enclosure_pseudo_accessor {
    my $hash = shift;
    my $key  = shift;
    if (@_) {
        $hash->{enclosure}->{$key} = shift;
    }
    return $hash->{enclosure}->{$key};
}

sub item_url {
    my $hash = shift;
    enclosure_pseudo_accessor($hash, 'url', @_);
}

sub item_length {
    my $hash = shift;
    enclosure_pseudo_accessor($hash, 'length', @_);
}

# since XML::RSS doesn't provide a method to clear out the items in an
# already-parsed feed, I'm creating a subclass to provide that
# functionality rather than just executing code that manipulates the
# internal data structure of the object in my main program

package XML::RSS::NPR;
use base qw( XML::RSS );

sub clear_items {
    my $self = shift;
    $self->{num_items} = 0;
    $self->{items} = [];
}

# since we're creating a subclass, we can override the default XML
# modules that are used to be the ones we need - no calling
# add_module() from our main program!

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
