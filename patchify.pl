#!/usr/bin/perl

use feature qw(say);

use Modern::Perl;
use File::Slurp;
use Getopt::Long;

my $input_file;
my $output_file;
my $output_dir;
my $commit_id;
my $commit_format = 'debian';
my $translateDebian2Git;
my $verbose;
my $help;

# Append the mapping to these .patch-file lookups
my @replacementLookups = (
    '^ create mode \d{6} \K',
    '^\-\-\- a\/\K',
    '^\+\+\+ b\/\K',
    '^diff --git a\/\K',
    '^diff --git a\/.+? b\/\K',
);

GetOptions(
    "i|input=s"  => \$input_file,
    "o|output=s" => \$output_file,
    "d|output_dir=s" => \$output_dir,
    "c|commit=s" => \$commit_id,
    "f|format=s" => \$commit_format,
    "verbose"    => \$verbose,
    "h|help"     => \$help,
) or die("Error in command line arguments\n");

if ($help) {
    print <<HELP;
$0 [OPTIONS]

Convert a git-derived Koha patch into a patch that can be applied to a server 
running a Debian package install of Koha or vice-versa.

Some limitations apply, such as debian-packaged file hierarchy doesn't support 
changes to /etc/koha-conf.xml or test files etc.

OPTIONS:
  -i, --input FILE        Input patch file to process
  -o, --output FILE       Output patch file (if not specified, prints to stdout)
  -d, --output_dir DIR    Directory to write output files to
  -c, --commit ID         Git commit ID to process
  -f  --format FORMAT     deb - Translate from Git to Debian format
                          git - Translate from Debian to Git
                          default - debian
      --verbose           Enable verbose output
  -h, --help              Show this help message

EXAMPLES:
  $0 -i patch.patch -o converted.patch
  $0 --input my.patch --output_dir /tmp --verbose
  $0 --commit abc123def --d2g

HELP
    exit(0);
}

unless ($commit_id) {
    unless ($input_file) {
        say "-i --input <path to patch file> is required";
        exit 1;
    }
    unless ($output_file) {
        say "-o --output <path to patch file> is required";
        exit 1;
    }
}

if ($commit_id) {
    unless ($output_dir) {
        $output_dir = "/tmp";
    }
    my $cmd;
    $cmd = `git format-patch -N -o $output_dir -1 $commit_id`;

    $input_file = $cmd;
    chomp $input_file;
    $output_file = $input_file unless $output_file;
}

print "read_file $input_file\n" if ($verbose);
my @lines = read_file($input_file);

my @mappingGit2Debian = ( # Use arrays, so we preserve the processing order.
    # Specific files first
    ['about.pl' => 'intranet/cgi-bin/about.pl'],
    ['changelanguage.pl' => 'intranet/cgi-bin/changelanguage.pl'],
    ['help.pl' => 'intranet/cgi-bin/help.pl'],
    ['kohaversion.pl' => 'intranet/cgi-bin/kohaversion.pl'],
    ['mainpage.pl' => 'intranet/cgi-bin/mainpage.pl'],

    # Template directories
    ['koha-tmpl/intranet-tmpl/' => 'intranet/htdocs/intranet-tmpl/'],
    ['koha-tmpl/opac-tmpl/' => 'opac/htdocs/opac-tmpl/'],

    # Library directories
    ['C4/' => 'lib/C4/'],
    ['Koha/' => 'lib/Koha/'],

    # CGI directories
    ['admin/' => 'intranet/cgi-bin/admin/'],
    ['errors/' => 'intranet/cgi-bin/errors/'],
    ['suggestion/' => 'intranet/cgi-bin/suggestion/'],
    ['installer/' => 'intranet/cgi-bin/installer/'],
    ['acqui/' => 'intranet/cgi-bin/acqui/'],
    ['tools/' => 'intranet/cgi-bin/tools/'],
    ['members/' => 'intranet/cgi-bin/members/'],
    ['catalogue/' => 'intranet/cgi-bin/catalogue/'],
    ['reserve/' => 'intranet/cgi-bin/reserve/'],
    ['circ/' => 'intranet/cgi-bin/circ/'],
    ['cataloguing/' => 'intranet/cgi-bin/cataloguing/'],
    ['virtualshelves/' => 'intranet/cgi-bin/virtualshelves/'],
    ['pos/' => 'intranet/cgi-bin/pos/'],
    ['svc/' => 'intranet/cgi-bin/svc/'],
    ['bookings/' => 'intranet/cgi-bin/bookings/'],
    ['reports/' => 'intranet/cgi-bin/reports/'],

    # OPAC
    ['opac/' => 'opac/cgi-bin/opac/'],

    # System directories
    ['misc/' => 'bin/'],
    ['t/' => '/tmp/'],
    ['debian/scripts/' => '/usr/sbin/'],
    ['etc/' => '/etc/koha/'],

    # API (no change)
    ['api/' => 'api/'],
);
my @mappingDebian2Git = map { [$_->[1] => $_->[0]] } @mappingGit2Debian;
push(@mappingDebian2Git, ['intranet/cgi-bin/' => '']);

my @mappingNone;

my $mapping;

for (my $i=0 ; $i<@lines ; $i++) {
    for my $lookup (@replacementLookups) {
        if ( $lines[$i] =~ m/$lookup/ ) {    # match on
            print "FOUND LINE: $lines[$i]" if $verbose;

            detectFormat($lookup, \@lines, $i); #sets $mapping;

            my $mappingFound = 0;
            if ($commit_format =~ /^deb/i) {
                if ($mapping == \@mappingGit2Debian) {
                    $mappingFound = translateLine($lookup,  \@lines, $i)
                }
                else {
                    #print "Format is already debian\n";
                    $mappingFound = 1;
                }
            }
            elsif ($commit_format =~ /^git/i) {
                if ($mapping == \@mappingDebian2Git) {
                    $mappingFound = translateLine($lookup,  \@lines, $i)
                }
                else {
                    #print "Format is already git\n";
                    $mappingFound = 1;
                }
            }
            print "NO MAPPING FOUND FOR $lines[$i]" unless ($mappingFound);
        }
    }
}

print "write_file $output_file\n" if ($verbose);
write_file( $output_file, @lines );

sub detectFormat {
    my ($lookup, $lines, $i) = @_;
    # Detect the mapping, git => debian vs debian => git.
    # Looks like the mappings can be confused, besides the static path portions, so check defensively.
    # Debian-style paths are more unique, so check for debianness first.
    foreach my $debian2Git (@mappingDebian2Git) {
        my ($from, $to) = @$debian2Git;
        if ($lines->[$i] =~ m/$lookup$from/) {
            if ($from eq $to && not($mapping)) { # b/api/ => b/api/
                $mapping = \@mappingNone;
            }
            elsif (not($mapping)) {
                $mapping = \@mappingDebian2Git;
            }
            elsif ($mapping != \@mappingDebian2Git && not($mapping == \@mappingNone)) {
                warn "Previous mapping changed to 'debian2Git' at line '$lines->[$i]' matching rule '$from => $to'";
                $mapping = \@mappingDebian2Git;
            }
        }
    }
    if (not($mapping)) {
        foreach my $git2Debian (@mappingGit2Debian) {
            my ($from, $to) = @$git2Debian;
            if ($lines->[$i] =~ m/$lookup$from/) {
                if ($from eq $to && not($mapping)) { # b/api/ => b/api/
                    $mapping = \@mappingNone;
                }
                if (not($mapping)) {
                    $mapping = \@mappingGit2Debian;
                }
                elsif ($mapping != \@mappingGit2Debian && not($mapping == \@mappingNone)) {
                    warn "Previous mapping changed to 'git2Debian' at line '$lines->[$i]' matching rule '$from => $to'";
                    $mapping = \@mappingGit2Debian;
                }
            }
        }
    }
}

sub translateLine {
    my ($lookup, $lines, $i) = @_;

    foreach my $m (@$mapping) {
        my ($from, $to) = @$m;
        if ($lines[$i] =~ s/$lookup$from/$to/) {
            return 1;
        }
    }
}
